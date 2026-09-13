import SwiftUI

/// SPEC §18.3: the fourth tab. Four gauges that never scroll, then the warnings and Top CPU in
/// a list capped at `listMaxHeight` — the same shape the History tab has, for the same reason:
/// the panel's height is computed in `Theme.Metrics`, never inferred from the content.
///
/// It observes `SystemWatchState` directly (not through `AppState`): the engine publishes into
/// that object, and an `@ObservedObject AppState` would not see those changes.
struct SentinelView: View {
    @ObservedObject var watch: SystemWatchState
    var actions: SentinelActions = .inert

    @Environment(\.metrics) private var metrics
    /// SPEC §18.4: a failed action shows under its own row. Keyed by rule id, because that is
    /// what stays stable while the same warning keeps firing.
    @State private var actionErrors: [String: String] = [:]
    /// The rule ids whose Stop is in flight. The engine's stop is asynchronous now (it waits out
    /// SIGTERM), so the row has to say it is working rather than sit there looking ignored for
    /// two seconds.
    @State private var stopping: Set<String> = []
    @State private var sortByMemory = false

    private var signals: [SystemSignal] { Sentinel.sorted(watch.signals) }
    private var apps: [SystemAppLoad] { Sentinel.topApps(watch.snapshot, byMemory: sortByMemory) }
    private var thermalChip: String? { Sentinel.thermalChip(watch.snapshot) }
    /// Rows carrying an extra line under them — a failure message or a "Stopping…" — which is
    /// what the list's height has to leave room for.
    private var inlineErrorCount: Int {
        signals.filter { actionErrors[$0.id] != nil || stopping.contains($0.id) }.count
    }
    /// One per warning, measured at this appearance — the row draws from it and the window is
    /// sized from it (SPEC §18.3).
    private var rowLayouts: [SentinelRowLayout] {
        Sentinel.layouts(signals, metrics: metrics)
    }

    var body: some View {
        VStack(spacing: 0) {
            SentinelGaugesView(snapshot: watch.snapshot, thermalChip: thermalChip)
            list
                .frame(
                    height: metrics.sentinelListHeight(
                        layouts: rowLayouts, apps: apps.count,
                        showsError: watch.lastError != nil, inlineErrors: inlineErrorCount
                    )
                )
        }
        .padding(.top, metrics.sentinelGaugeGap)
    }

    // MARK: - Warnings + Top CPU

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: metrics.rowGap) {
                // SPEC §18.6: a sampler that cannot run says so, at the top, instead of letting
                // the gauges above read as a healthy machine.
                if let lastError = watch.lastError {
                    Text(lastError)
                        .font(metrics.rowSecondary)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: metrics.sentinelErrorLineHeight, alignment: .leading)
                }

                SentinelSectionHeader(title: "WARNINGS")
                if signals.isEmpty {
                    emptyState
                } else {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        VStack(alignment: .leading, spacing: metrics.rowGap) {
                            ForEach(signals) { signal in
                                SentinelWarningRow(
                                    signal: signal,
                                    now: context.date,
                                    inlineError: actionErrors[signal.id],
                                    isStopping: stopping.contains(signal.id),
                                    onAction: { perform($0, for: signal) },
                                    onJump: signal.sessionID.map { id in { actions.jump(id) } }
                                )
                            }
                        }
                    }
                }

                SentinelHistoryView(samples: watch.resourceHistory)

                if !apps.isEmpty {
                    HStack {
                        SentinelSectionHeader(title: sortByMemory ? "TOP MEMORY" : "TOP CPU")
                        Spacer()
                        Button(sortByMemory ? "Sort by CPU" : "Sort by memory") { sortByMemory.toggle() }
                            .buttonStyle(.plain).font(metrics.caption)
                    }
                        .padding(.top, metrics.sentinelGaugeGap - metrics.rowGap)
                    ForEach(apps) { app in
                        SentinelAppRow(app: app)
                    }
                }
            }
            // The gauges above are inset by `padding`, so the list is too — a step between the
            // two blocks would read as a mistake. `padding` is wider than `listInset`, so the
            // right-edge resize grip still has its own strip (SPEC §14).
            .padding(.horizontal, metrics.padding)
        }
        .mask(overflowMask)
    }

    /// SPEC §18.3's empty state: the machine is fine, and the tab says when it last looked.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: metrics.scaled(4)) {
            Text(watch.lastError != nil ? "Monitoring unavailable"
                : watch.snapshot == nil ? "Waiting for first sample" : Sentinel.emptyTitle)
                .font(metrics.rowTitle)
                .foregroundStyle(Theme.textSecondary)
            TimelineView(.periodic(from: .now, by: 5)) { context in
                Text(Sentinel.sampledText(watch.snapshot, now: context.date))
                    .font(metrics.rowSecondary)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(
            maxWidth: .infinity, minHeight: metrics.sentinelEmptyHeight,
            maxHeight: metrics.sentinelEmptyHeight, alignment: .leading
        )
        .padding(.horizontal, metrics.rowInset)
        .background(
            RoundedRectangle(cornerRadius: metrics.rowCorner, style: .continuous)
                .fill(Theme.cardFill)
        )
    }

    /// The same fade History uses when its rows run past the cap.
    @ViewBuilder
    private var overflowMask: some View {
        if metrics.sentinelListOverflows(
            layouts: rowLayouts, apps: apps.count,
            showsError: watch.lastError != nil, inlineErrors: inlineErrorCount
        ) {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.86),
                    .init(color: .black.opacity(0.08), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        } else {
            Color.black
        }
    }

    /// SPEC §18.4: the failure message lands under the row, never in a second alert. A repeat
    /// that succeeds clears it.
    ///
    /// Both steps of a Stop are asynchronous — the confirmation is a sheet on the panel, and the
    /// stop itself waits out SIGTERM on the engine's queue — so this only ever hands over
    /// closures. `onStopConfirmed` is what marks the row busy, and it fires after the sheet is
    /// answered: a row must not say "Stopping…" while the confirmation is still standing open.
    private func perform(_ action: SystemSignalAction, for signal: SystemSignal) {
        // A stale failure from the previous attempt would otherwise sit under the row all the way
        // through the next one.
        actionErrors.removeValue(forKey: signal.id)
        actions.perform(
            action,
            onStopConfirmed: { stopping.insert(signal.id) },
            completion: { message in
                stopping.remove(signal.id)
                if let message {
                    actionErrors[signal.id] = message
                } else {
                    actionErrors.removeValue(forKey: signal.id)
                }
            }
        )
    }
}

/// `WARNINGS` / `TOP CPU` — the Usage tab's own section label, at the Usage tab's own size.
struct SentinelSectionHeader: View {
    let title: String

    @Environment(\.metrics) private var metrics

    var body: some View {
        Text(title)
            .font(metrics.sectionLabel)
            .tracking(0.8)
            .foregroundStyle(Theme.textTertiary)
            .frame(height: metrics.sentinelSectionHeaderHeight, alignment: .leading)
    }
}

/// SPEC §18.3's "Top CPU": name · CPU % · memory, on one line. The tooltip is where the
/// upper-bound wording lives — the number itself has no room for a caveat.
struct SentinelAppRow: View {
    let app: SystemAppLoad

    @Environment(\.metrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.controlGap) {
            Text(app.name)
                .font(metrics.rowSecondary)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: metrics.controlGap)
            Text(Sentinel.percentText(app.cpuPercent))
                .font(metrics.numeral)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(Sentinel.memoryText(app.residentBytes))
                .font(metrics.numeral)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(height: metrics.sentinelAppRowHeight)
        .help(Sentinel.topAppsTooltip)
    }
}

// MARK: - The tab's pure model

/// Everything the Sentinel tab computes from a snapshot, kept out of the views so it can be
/// tested without laying anything out (SPEC §18.7).
enum Sentinel {
    static let emptyTitle = "Nothing to report"
    /// SPEC §18.3: "Sum of the app's processes; an upper bound" — shared pages are counted once
    /// per process, which `SystemAppLoad` says in its own doc comment too.
    static let topAppsTooltip = "Sum of the app's processes; an upper bound"

    /// SPEC §18.3: worst first, and within one severity the one that has been going on longest.
    static func sorted(_ signals: [SystemSignal]) -> [SystemSignal] {
        signals.sorted { left, right in
            if left.severity != right.severity { return left.severity > right.severity }
            if left.since != right.since { return left.since < right.since }
            return left.id < right.id
        }
    }

    /// The buttons a row will carry — the action, plus Jump when the culprit is one of Lookout's
    /// own sessions. Their labels, not just their number: the widest one is what the text column
    /// has to give way to.
    static func buttonLabels(_ signal: SystemSignal) -> [String] {
        var labels: [String] = ["Details"]
        if let action = signal.action { labels.append(action.label) }
        if signal.sessionID != nil { labels.append(jumpLabel) }
        return labels
    }

    static let jumpLabel = "Jump"

    /// SPEC §18.3, after the owner's review: how one warning row lays out at this appearance. The
    /// duration keeps its place beside the title only while the two fit on one line together —
    /// otherwise the title takes the whole column (up to two lines) and the duration drops to a
    /// muted line of its own beneath it, so a title can never break mid-phrase around it.
    ///
    /// Measured, and the same function the row and the window's height both call, so the two can
    /// never disagree.
    static func layout(
        for signal: SystemSignal, metrics: Theme.Metrics, now: Date = Date()
    ) -> SentinelRowLayout {
        let labels = buttonLabels(signal)
        let available = metrics.sentinelWarningTextWidth(buttonLabels: labels)
            - metrics.measurementSlack
        let title = metrics.textWidth(signal.title, font: metrics.rowTitleNSFont)
        let duration = metrics.textWidth(
            durationText(since: signal.since, now: now), font: metrics.numeralNSFont
        )

        let inline = title + metrics.scaled(6) + duration <= available
        let adviceLines: Int
        if let advice = signal.advice.first {
            adviceLines = metrics.textWidth(advice, font: metrics.rowSecondaryNSFont) <= available
                ? 1 : 2
        } else {
            adviceLines = 0
        }

        return SentinelRowLayout(
            titleLines: title <= available ? 1 : 2,
            adviceLines: adviceLines,
            durationBelowTitle: !inline,
            buttons: labels.count
        )
    }

    static func layouts(
        _ signals: [SystemSignal], metrics: Theme.Metrics, now: Date = Date()
    ) -> [SentinelRowLayout] {
        signals.map { layout(for: $0, metrics: metrics, now: now) }
    }

    /// `for 12m` — `Format.duration`, the same spelling every elapsed number in the panel uses.
    static func durationText(since: Date, now: Date = Date()) -> String {
        "for " + Format.duration(now.timeIntervalSince(since))
    }

    /// `sampled 12s ago`, or the honest answer before the first sample lands.
    static func sampledText(_ snapshot: SystemSnapshot?, now: Date = Date()) -> String {
        guard let snapshot else { return "not sampled yet" }
        return "sampled " + Format.duration(now.timeIntervalSince(snapshot.sampledAt)) + " ago"
    }

    /// SPEC §18.3: at most five.
    static func topApps(_ snapshot: SystemSnapshot?, byMemory: Bool = false) -> [SystemAppLoad] {
        guard let snapshot else { return [] }
        let apps = snapshot.processes.isEmpty ? snapshot.topApps : SystemProcessSampler.rollUp(snapshot.processes)
        return Array(apps.sorted {
            let left = byMemory ? Double($0.residentBytes) : $0.cpuPercent
            let right = byMemory ? Double($1.residentBytes) : $1.cpuPercent
            return left == right ? $0.name < $1.name : left > right
        }.prefix(5))
    }

    /// SPEC §18.3: a chip only when the machine is not nominal.
    static func thermalChip(_ snapshot: SystemSnapshot?) -> String? {
        guard let snapshot, snapshot.thermal != .nominal else { return nil }
        return "Thermal · " + snapshot.thermal.label
    }

    // MARK: Gauges

    static func percentText(_ value: Double) -> String {
        "\(Int(max(0, value).rounded()))%"
    }

    /// `1.4 GB` under ten, `24 GB` over it, `512 MB` under one — a column 60 pt wide has room
    /// for one number and one unit, not for three decimals.
    static func memoryText(_ bytes: UInt64) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        if gigabytes < 1 {
            return "\(Int((Double(bytes) / 1_048_576).rounded())) MB"
        }
        if gigabytes < 10 {
            return String(format: "%.1f GB", gigabytes)
        }
        return "\(Int(gigabytes.rounded())) GB"
    }

    /// The four §18.3 gauges, in order, as label/value/detail triples. A nil snapshot still
    /// renders four columns — with em dashes, not with zeros that would read as "all fine".
    static func gauges(_ snapshot: SystemSnapshot?) -> [Gauge] {
        guard let snapshot else {
            return [
                Gauge(label: "CPU", value: "—", detail: "no sample"),
                Gauge(label: "MEMORY", value: "—", detail: "no sample"),
                Gauge(label: "SWAP OUT", value: "—", detail: "no sample"),
                Gauge(label: "DISK", value: "—", detail: "no sample"),
            ]
        }
        return [
            Gauge(
                label: "CPU",
                value: percentText(snapshot.cpuPercent),
                detail: String(format: "load %.1f", snapshot.loadAverage.first ?? 0),
                level: snapshot.cpuPercent >= 85 ? .critical
                    : (snapshot.cpuPercent >= 60 ? .warn : .ok)
            ),
            Gauge(
                label: "MEMORY",
                value: percentText(snapshot.memoryUsedFraction * 100),
                detail: snapshot.memoryPressure.label,
                level: snapshot.memoryPressure == .critical ? .critical
                    : (snapshot.memoryPressure == .warning ? .warn : .ok)
            ),
            Gauge(
                // "SWAP OUT" over "pages/s", not "SWAP" over "pages/s out": at the Large
                // appearance the longer detail was the one string in the row that had to shrink
                // to fit its column, and a row of gauges at two different type sizes looks like
                // a bug. Same meaning, split where the column is wide enough for it.
                label: "SWAP OUT",
                // SPEC §18.3: "0" when idle — not "—", which would read as "unknown".
                value: "\(Int(max(0, snapshot.swapOutPerSecond).rounded()))",
                detail: "pages/s",
                level: snapshot.swapOutPerSecond >= 100 ? .critical
                    : (snapshot.swapOutPerSecond > 0 ? .warn : .ok)
            ),
            Gauge(
                label: "DISK",
                value: memoryText(snapshot.diskFree),
                detail: percentText(snapshot.diskFreeFraction * 100) + " free",
                level: snapshot.diskFreeFraction <= 0.05 ? .critical
                    : (snapshot.diskFreeFraction <= 0.10 ? .warn : .ok)
            ),
        ]
    }

    struct Gauge: Identifiable, Equatable {
        var label: String
        var value: String
        var detail: String
        var level: UsageLevel?

        var id: String { label }
    }
}

/// How one warning row is laid out at a given appearance (SPEC §18.3). A plain value so
/// `Theme.Metrics` can size the window from it without knowing anything about a `SystemSignal`.
struct SentinelRowLayout: Equatable {
    /// 1 or 2. A title never truncates; it wraps.
    var titleLines: Int = 1
    /// 0 when the signal carries no advice, else 1 or 2.
    var adviceLines: Int = 1
    /// True when the title needed the whole column and `for 12m` moved to its own line under it.
    var durationBelowTitle: Bool = false
    /// The action button, plus Jump when the signal names a session (SPEC §18.4).
    var buttons: Int = 0
}
