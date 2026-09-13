import SwiftUI

struct UsageView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: Settings

    @Environment(\.metrics) private var metrics

    private var limits: [UsageLimit] {
        state.usage.snapshot?.visibleLimits(hidden: settings.hiddenUsageModels) ?? []
    }

    private var extraLine: String? {
        guard let snapshot = state.usage.snapshot, snapshot.extraUsageEnabled else { return nil }
        guard let percent = snapshot.extraUsagePercent else { return "Extra usage enabled" }
        return "Extra usage · \(Int(percent.rounded()))%"
    }

    // MARK: - Codex (SPEC §17.7)

    private var codexUsage: CodexUsageSnapshot? { state.codexUsage }

    private var codexCardCount: Int { UsageView.codexCardCount(codexUsage) }

    /// One bar per non-nil window — SPEC §17.7: "render the 5-hour bar alone" when `secondary`
    /// is null, never crash either way.
    static func codexCardCount(_ snapshot: CodexUsageSnapshot?) -> Int {
        guard let snapshot else { return 0 }
        var count = 0
        if snapshot.primary != nil { count += 1 }
        if snapshot.secondary != nil { count += 1 }
        return count
    }

    // MARK: - Sessions today (SPEC §17.6)

    /// Live sessions only — the reporter's `history.jsonl` line does not carry `tokens` (checked
    /// against `hooks/lookout-report.py`'s `append_history`), so an ended session's cost cannot
    /// be recovered once it leaves `allSessions`. The section says as much in its footer.
    private var pricedSessionsToday: [(session: Session, cost: Double)] {
        UsageView.pricedSessionsToday(state: state, settings: settings)
    }

    static func pricedSessionsToday(
        state: AppState, settings: Settings, now: Date = Date(), calendar: Calendar = .current
    ) -> [(session: Session, cost: Double)] {
        state.allSessions
            .compactMap { session -> (Session, Double)? in
                guard let cost = session.cost(pricing: settings.pricing), cost > 0 else {
                    return nil
                }
                guard let activity = session.updatedAt ?? session.stateSince ?? session.startedAt,
                      calendar.isDate(activity, inSameDayAs: now)
                else { return nil }
                return (session, cost)
            }
            .sorted { $0.1 > $1.1 }
    }

    private var totalCostToday: Double {
        pricedSessionsToday.reduce(0) { $0 + $1.cost }
    }

    private var hasAnyContent: Bool {
        !limits.isEmpty || codexUsage != nil || !pricedSessionsToday.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            cards
                .frame(
                    height: metrics.usageHeight(
                        cards: limits.count, extraLine: extraLine != nil,
                        codexCards: codexCardCount,
                        sessionsToday: min(pricedSessionsToday.count, 5)
                    )
                )
            footer
        }
    }

    @ViewBuilder
    private var cards: some View {
        if !hasAnyContent {
            EmptyState(
                symbol: emptySymbol,
                title: emptyTitle,
                message: emptyMessage
            )
        } else {
            // Indicators on: with four Claude cards, Codex and Sessions today the content is
            // taller than the list, and a hidden Codex section reads as "not shown" (the owner).
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: metrics.usageCardGap) {
                    // SPEC §17.7: Codex sits right after the two Claude headline cards, before
                    // the per-model ones, so both subscriptions are visible without scrolling.
                    ForEach(limits.filter { !$0.isScoped }) { limit in
                        UsageCard(limit: limit)
                    }
                    if let codexUsage {
                        CodexUsageSection(snapshot: codexUsage)
                    }
                    ForEach(limits.filter(\.isScoped)) { limit in
                        UsageCard(limit: limit)
                    }
                    if let extraLine {
                        Text(extraLine)
                            .font(metrics.rowSecondary)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.leading, 2)
                    }
                    // SPEC §17.6.
                    if !pricedSessionsToday.isEmpty {
                        SessionsTodaySection(
                            sessions: Array(pricedSessionsToday.prefix(5)), total: totalCostToday
                        )
                    }
                }
                .padding(.horizontal, metrics.padding)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: metrics.controlGap) {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                Text(state.usage.statusText(now: context.date))
                    .font(metrics.rowSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: metrics.controlGap)
            Button("Refresh") { state.usage.refreshByUser() }
                .buttonStyle(QuietButtonStyle(metrics: metrics))
        }
        .padding(.horizontal, metrics.padding)
        .frame(height: metrics.footerHeight)
    }

    private var emptySymbol: String {
        switch state.usage.error {
        case .notSignedIn, .expired: return "person.crop.circle.badge.exclamationmark"
        case .none: return "chart.bar"
        default: return "wifi.slash"
        }
    }

    private var emptyTitle: String {
        state.usage.error?.message ?? "No usage data yet"
    }

    private var emptyMessage: String {
        switch state.usage.error {
        case .notSignedIn:
            return "Beacon reads the token Claude Code stores in your keychain."
        case .expired:
            return "Run any Claude Code command to refresh the sign-in, then hit Refresh."
        case .none:
            return "Fetching your limits from the usage API."
        default:
            return "Beacon keeps the last numbers and retries on the next tick."
        }
    }
}

/// One limit: label, percent, bar, reset time. Fixed height so the panel's own height is exact.
struct UsageCard: View {
    let limit: UsageLimit

    @Environment(\.metrics) private var metrics

    private var color: Color { Theme.color(for: limit.level) }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.scaled(6)) {
            HStack(spacing: metrics.controlGap) {
                Text(limit.label)
                    .font(metrics.rowTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: metrics.controlGap)
                Text("\(Int(limit.percent.rounded()))%")
                    .font(metrics.bigNumeral)
                    .foregroundStyle(color)
            }

            UsageBar(fraction: limit.fraction, color: color)

            Text(limit.resetsText() ?? " ")
                .font(metrics.rowSecondary)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(metrics.rowInset)
        .frame(height: metrics.usageCardHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                let shape = RoundedRectangle(cornerRadius: metrics.rowCorner, style: .continuous)
                shape.fill(Theme.cardBase)
                shape.fill(Theme.cardFill)
            }
        )
    }
}

/// 6 pt rounded bar, gradient from the state colour into a lighter tint of itself.
struct UsageBar: View {
    let fraction: Double
    let color: Color

    @Environment(\.metrics) private var metrics

    var body: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width)
            HStack(spacing: 0) {
                Capsule(style: .continuous)
                    .fill(Theme.gradient(color))
                    .frame(width: max(fraction > 0 ? metrics.barHeight : 0, width * fraction))
                Spacer(minLength: 0)
            }
            .frame(width: width, height: metrics.barHeight)
            .background(Capsule(style: .continuous).fill(Theme.trackFill))
        }
        .frame(height: metrics.barHeight)
    }
}

/// SPEC §17.7: the Codex rate limits, next to the Claude cards — a 5-hour bar always, a weekly
/// one only when the reporter has seen a `secondary` window, and the caption's two halves each
/// hidden on their own when the reporter sent `null` for them.
struct CodexUsageSection: View {
    let snapshot: CodexUsageSnapshot

    @Environment(\.metrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.scaled(6)) {
            Text("CODEX")
                .font(metrics.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(Theme.familyCodex)
            if let primary = snapshot.primary {
                CodexUsageBar(title: primary.title, window: primary)
            }
            if let secondary = snapshot.secondary {
                CodexUsageBar(title: secondary.title, window: secondary)
            }
            if let caption = snapshot.caption {
                Text(caption)
                    .font(metrics.rowSecondary)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(metrics.rowInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Codex on its own dark card, told apart from the Claude cards by the
        // Codex family blue on the label and the outline. The bars keep their band colours —
        // blue says whose limit this is, green/amber/red says how close it is.
        .background(
            ZStack {
                let shape = RoundedRectangle(cornerRadius: metrics.rowCorner, style: .continuous)
                shape.fill(Theme.cardBase)
                shape.fill(Theme.familyCodex.opacity(Theme.familyFill))
                shape.strokeBorder(
                    Theme.familyCodex.opacity(Theme.familyStroke), lineWidth: Theme.familyStrokeWidth
                )
            }
        )
    }
}

/// One Codex rate-limit window, laid out like `UsageCard` but without the fixed card height —
/// the Codex section is not a grid of equal cards, it is a couple of bars under one header.
struct CodexUsageBar: View {
    let title: String
    let window: CodexUsageWindow

    @Environment(\.metrics) private var metrics

    private var color: Color { Theme.color(for: window.level) }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.scaled(4)) {
            HStack(spacing: metrics.controlGap) {
                Text(title)
                    .font(metrics.rowTitle)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: metrics.controlGap)
                if let percent = window.usedPercent {
                    Text("\(Int(percent.rounded()))%")
                        .font(metrics.numeral)
                        .foregroundStyle(color)
                }
            }
            UsageBar(fraction: window.fraction, color: color)
            if let resets = window.resetsText() {
                Text(resets)
                    .font(metrics.rowSecondary)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

/// SPEC §17.6: total cost + the top five sessions by cost, live sessions only — an ended
/// session's tokens are not in `history.jsonl`, which the footer line says plainly.
struct SessionsTodaySection: View {
    let sessions: [(session: Session, cost: Double)]
    let total: Double

    @Environment(\.metrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.scaled(6)) {
            HStack(spacing: metrics.controlGap) {
                Text("SESSIONS TODAY")
                    .font(metrics.sectionLabel)
                    .tracking(0.8)
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: metrics.controlGap)
                Text(PricingTable.formatEstimate(total))
                    .font(metrics.chip)
                    .foregroundStyle(Theme.textSecondary)
            }
            ForEach(sessions, id: \.session.id) { entry in
                HStack(spacing: metrics.controlGap) {
                    Text(entry.session.displayLabel)
                        .font(metrics.rowSecondary)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: metrics.controlGap)
                    Text(PricingTable.formatEstimate(entry.cost))
                        .font(metrics.rowSecondary)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            // the owner is on a subscription, not API pricing — both lines say so, one about the
            // number itself, one about what it does not cover.
            Text("API-equivalent estimate, not what your subscription charges.")
                .font(.system(size: 9))
                .foregroundStyle(Theme.textTertiary)
            Text("Live sessions only — history does not keep token totals yet.")
                .font(.system(size: 9))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

/// A text button that does not look like a system push button. A `ButtonStyle` has no
/// environment of its own, so it is handed the metrics the way it is handed its colours.
struct QuietButtonStyle: ButtonStyle {
    var metrics: Theme.Metrics = .standard

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(metrics.control)
            .foregroundStyle(configuration.isPressed ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, metrics.scaled(9))
            .frame(height: metrics.tabHeight)
            .background(
                RoundedRectangle(cornerRadius: metrics.chipCorner, style: .continuous)
                    .fill(configuration.isPressed ? Theme.chipFill : Color.white.opacity(0.07))
            )
            .contentShape(RoundedRectangle(cornerRadius: metrics.chipCorner, style: .continuous))
    }
}
