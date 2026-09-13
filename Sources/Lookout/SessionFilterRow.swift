import SwiftUI

/// SPEC §17.3: wraps its children onto as many lines as the available width needs. The filter
/// chip row must never truncate a label or run past the panel's edge, and a fixed-width panel
/// with a variable number of chips is exactly the case `HStack` cannot handle on its own.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, maxWidth: width)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        let rowWidth = rows.map(\.width).max() ?? 0
        return CGSize(width: width.isFinite ? width : rowWidth, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let rows = arrange(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                item.subview.place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct RowItem {
        let subview: LayoutSubview
        let size: CGSize
    }

    private struct Row {
        let items: [RowItem]
        let width: CGFloat
        let height: CGFloat
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current: [RowItem] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let addedWidth = current.isEmpty ? size.width : currentWidth + spacing + size.width
            if !current.isEmpty, maxWidth.isFinite, addedWidth > maxWidth {
                rows.append(Row(items: current, width: currentWidth, height: currentHeight))
                current = [RowItem(subview: subview, size: size)]
                currentWidth = size.width
                currentHeight = size.height
            } else {
                current.append(RowItem(subview: subview, size: size))
                currentWidth = addedWidth
                currentHeight = max(currentHeight, size.height)
            }
        }
        if !current.isEmpty {
            rows.append(Row(items: current, width: currentWidth, height: currentHeight))
        }
        return rows
    }
}

/// The chip row itself: **All · Needs you · Working · Finished · Idle**, multi-select with
/// counts, plus the host popover (SPEC §17.3). A view of its own — rather than inline in
/// `PanelView` — so `PanelController` can measure its real, wrap-dependent height the same way
/// `AttentionCardController` measures the card.
struct SessionFilterRow: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: Settings

    /// Read from `settings` rather than `@Environment` — `PanelController` measures this view in
    /// a hosting view of its own, outside `PanelView`'s environment chain, so it needs a metrics
    /// source that does not depend on being embedded anywhere in particular.
    private var metrics: Theme.Metrics { settings.metrics }
    @State private var hostPopoverShown = false

    var body: some View {
        FlowLayout(spacing: metrics.controlGap, lineSpacing: metrics.scaled(6)) {
            FilterChip(title: "All", count: nil, selected: settings.filterStates.isEmpty) {
                settings.filterStates = []
            }
            ForEach(StateFilter.allCases) { filter in
                FilterChip(
                    title: filter.label, count: count(for: filter),
                    selected: settings.filterStates.contains(filter)
                ) {
                    toggle(filter)
                }
            }
            hostFilterButton
        }
    }

    /// Counted against every session the idle toggle would show, so "Idle" still reads a real
    /// number even while "Show idle sessions" is off.
    private func count(for filter: StateFilter) -> Int {
        state.allSessions.filter { StateFilter.of($0) == filter }.count
    }

    private func toggle(_ filter: StateFilter) {
        var next = settings.filterStates
        if next.contains(filter) {
            next.remove(filter)
        } else {
            next.insert(filter)
        }
        // Every chip selected reads exactly like none of them being selected — canonicalise to
        // the empty set so "All" lights back up instead of showing four checked chips.
        if next.isEmpty || next == Set(StateFilter.allCases) { next = [] }
        settings.filterStates = next
    }

    /// Only the hosts actually present, so the popover is never a wall of hosts nobody has.
    private var presentHosts: [SessionHost] {
        var seen: [SessionHost] = []
        for session in state.allSessions where !seen.contains(session.host) {
            seen.append(session.host)
        }
        return seen.sorted { $0.chip < $1.chip }
    }

    private var hostFilterButton: some View {
        Button {
            hostPopoverShown = true
        } label: {
            HStack(spacing: metrics.scaled(3)) {
                Text(hostButtonLabel)
                Image(systemName: "chevron.down")
                    .font(metrics.font(7, .semibold))
            }
            .font(metrics.chip)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(settings.filterHosts.isEmpty ? Theme.textSecondary : Theme.textPrimary)
            .padding(.horizontal, metrics.chipPaddingH + metrics.scaled(2))
            .padding(.vertical, metrics.chipPaddingV + metrics.scaled(2))
            .background(
                RoundedRectangle(cornerRadius: metrics.chipCorner, style: .continuous)
                    .fill(settings.filterHosts.isEmpty ? Theme.chipFill : Theme.working.opacity(0.28))
            )
            .contentShape(RoundedRectangle(cornerRadius: metrics.chipCorner, style: .continuous))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $hostPopoverShown, arrowEdge: .bottom) {
            HostFilterPopover(settings: settings, hosts: presentHosts)
        }
        .accessibilityLabel("Filter by host")
    }

    private var hostButtonLabel: String {
        settings.filterHosts.isEmpty ? "Host" : "Host · \(settings.filterHosts.count)"
    }
}

/// One chip: a plain toggle button, never truncated (SPEC §17.3) — its label is one of five
/// fixed, short English words, so `fixedSize` costs nothing here.
struct FilterChip: View {
    let title: String
    let count: Int?
    let selected: Bool
    let action: () -> Void

    @Environment(\.metrics) private var metrics
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: metrics.scaled(3)) {
                Text(title)
                if let count {
                    Text("\(count)")
                        .monospacedDigit()
                        .foregroundStyle(selected ? Theme.textPrimary.opacity(0.8) : Theme.textTertiary)
                }
            }
            .font(metrics.chip)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, metrics.chipPaddingH + metrics.scaled(2))
            .padding(.vertical, metrics.chipPaddingV + metrics.scaled(2))
            .background(
                RoundedRectangle(cornerRadius: metrics.chipCorner, style: .continuous)
                    .fill(selected ? Theme.working.opacity(hovering ? 0.36 : 0.28)
                          : Theme.chipFill.opacity(hovering ? 1.3 : 1))
            )
            .contentShape(RoundedRectangle(cornerRadius: metrics.chipCorner, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
    }
}

/// SPEC §17.3's host filter: a checkbox per host actually present, and a Clear.
struct HostFilterPopover: View {
    @ObservedObject var settings: Settings
    let hosts: [SessionHost]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hosts.isEmpty {
                Text("No sessions yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(hosts, id: \.self) { host in
                    Toggle(host.chip, isOn: binding(for: host))
                }
            }
            Divider()
            Button("Clear") { settings.filterHosts = [] }
                .disabled(settings.filterHosts.isEmpty)
        }
        .padding(10)
        .frame(minWidth: 160, alignment: .leading)
    }

    private func binding(for host: SessionHost) -> Binding<Bool> {
        Binding(
            get: { settings.filterHosts.isEmpty || settings.filterHosts.contains(host) },
            set: { checked in
                // An empty set means "every host" — narrowing it for the first time starts from
                // every host actually present, not from nothing.
                var next = settings.filterHosts.isEmpty ? Set(hosts) : settings.filterHosts
                if checked {
                    next.insert(host)
                } else {
                    next.remove(host)
                }
                if next.isEmpty || next.count == hosts.count { next = [] }
                settings.filterHosts = next
            }
        )
    }
}
