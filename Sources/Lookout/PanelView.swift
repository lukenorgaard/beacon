import SwiftUI

/// The floating panel: header, three tabs, content. Pure stacks — nothing is layered over a
/// control, and every interactive element keeps at least 8 pt of air around it.
struct PanelView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: Settings
    var onTogglePin: () -> Void
    var onOpenSettings: () -> Void

    /// SPEC §14: the panel is the root, so it is where the measurements enter the environment.
    private var metrics: Theme.Metrics { settings.metrics }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabs
            filterRow
            content
            Spacer(minLength: 0)
        }
        .frame(width: metrics.width)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: metrics.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: metrics.corner, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: metrics.stroke)
                .allowsHitTesting(false)
        )
        // SPEC §14's drag zones. They live in the margins the rows already leave free — the
        // right strip is the list's own inset, the corner square is the air under the content —
        // so a row never loses a click to them.
        .overlay(alignment: .trailing) {
            PanelResizeGrip(zone: .edge, settings: settings)
                .frame(width: metrics.resizeEdge)
                .frame(maxHeight: .infinity)
                .accessibilityLabel("Drag to change the panel width")
        }
        .overlay(alignment: .bottomTrailing) {
            PanelResizeGrip(zone: .corner, settings: settings)
                .frame(width: metrics.resizeCorner, height: metrics.resizeCorner)
                .accessibilityLabel("Drag to change the panel width and list height")
        }
        .environment(\.metrics, metrics)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Header

    /// SPEC §12.3: two full-width rows. Row 1 carries the count and the controls; row 2 gets the
    /// whole width to itself, which is what lets the breakdown say `27 sub-agents` in words
    /// instead of the symbol shorthand it used when it was fighting the pill for room.
    private var header: some View {
        VStack(alignment: .leading, spacing: metrics.scaled(3)) {
            HStack(spacing: metrics.controlGap) {
                Circle()
                    .fill(Color(nsColor: state.statusColor))
                    .frame(width: metrics.scaled(7), height: metrics.scaled(7))

                Text(state.summaryHeadline)
                    .font(metrics.header)
                    .tracking(0.4)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: metrics.controlGap)

                if state.needsYouCount > 0 {
                    NeedsYouPill(count: state.needsYouCount)
                }

                IconButton(
                    symbol: settings.mode == .pinned ? "pin.fill" : "pin.slash",
                    help: settings.mode == .pinned
                        ? "Unpin — keep Beacon in the menu bar" : "Pin on every Space",
                    action: onTogglePin
                )
                IconButton(symbol: "gearshape", help: "Settings", action: onOpenSettings)
            }

            // SPEC §18.3, after the owner's review: the usage summary is never simply dropped. When
            // the four-tab strip cannot hold it, it lands here instead — right-aligned on the
            // same line as the counts, which give way first (they shorten, then truncate; the
            // summary has the layout priority and never does either).
            if !state.summaryDetail.isEmpty || headerSummary != nil {
                HStack(alignment: .firstTextBaseline, spacing: metrics.controlGap) {
                    Text(headerDetail)
                        .font(metrics.rowSecondary)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: metrics.controlGap)
                    if headerSummary != nil {
                        UsageChips(claude: state.usage.snapshot, codex: state.codexUsage)
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Under the headline text, not under the dot.
                .padding(.leading, metrics.scaled(7) + metrics.controlGap)
            }
        }
        .padding(.horizontal, metrics.padding)
        .frame(height: metrics.headerHeight)
        // Behind the rows, so the two buttons above them still get every click.
        .background(WindowDragHandle())
    }

    // MARK: Tabs

    private var tabs: some View {
        HStack(spacing: metrics.controlGap) {
            tabStrip
            Spacer(minLength: metrics.controlGap)
            if usageSummary != nil {
                UsageChips(claude: state.usage.snapshot, codex: state.codexUsage)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, metrics.padding)
        .frame(height: metrics.tabsHeight(rows: tabRows))
    }

    /// SPEC §18.3: a tab label is never truncated. Four tabs fit 360 pt at every appearance;
    /// five (History *and* Sentinel both on) do not at the largest text size — so the strip wraps
    /// onto a second line, exactly as SPEC §17.3's filter chips already do, and the window grows
    /// by one segment's height to hold it.
    private var tabStrip: some View {
        SegmentedTabs(
            selection: $state.tab,
            tabs: visibleTabs,
            label: PanelView.tabLabel(state),
            wraps: tabRows > 1
        )
    }

    private var tabRows: Int { PanelView.tabRows(state: state, settings: settings) }

    private var visibleTabs: [PanelTab] { PanelView.visibleTabs(settings) }

    /// The strip the panel is currently showing. Static so `PanelController` can size the window
    /// from exactly the same list the view builds itself from.
    static func visibleTabs(_ settings: Settings) -> [PanelTab] {
        PanelTab.visibleCases(
            showHistory: settings.showHistoryTab, showSentinel: settings.sentinelEnabled
        )
    }

    static func tabRows(state: AppState, settings: Settings) -> Int {
        settings.metrics.tabStripRows(
            labels: visibleTabs(settings).map(PanelView.tabLabel(state))
        )
    }

    /// The two percentages the owner glances at constantly. They are always on screen while the
    /// Sessions tab is selected — the only question is *where*.
    /// One entry per chip, Claude first, then Codex when the reporter has written its limits.
    private var summaryTexts: [String] {
        guard state.tab == .sessions else { return [] }
        var texts: [String] = []
        if let snapshot = state.usage.snapshot, let text = UsageChips.claudeText(snapshot) {
            texts.append(text)
        }
        if let codex = state.codexUsage, let text = UsageChips.codexText(codex) {
            texts.append(text)
        }
        return texts
    }

    private var summaryChipsWidth: CGFloat { metrics.usageChipsWidth(texts: summaryTexts) }

    private var percentSummary: String? {
        let texts = summaryTexts
        return texts.isEmpty ? nil : texts.joined(separator: "  ")
    }

    /// SPEC §18.3: beside the strip while it has room. With a fourth tab the segments tighten
    /// first (`tabSegmentPadding(tabCount:)`), which is enough at 360 pt and scale 1; when even
    /// that is not enough — a sub-agent count on the Agents label, or the Large text size — the
    /// summary moves to the header instead of disappearing. Never both places at once.
    private var usageSummary: String? {
        guard let summary = percentSummary else { return nil }
        let labels = visibleTabs.map(PanelView.tabLabel(state))
        return metrics.tabStripFitsSummary(labels: labels, summaryWidth: summaryChipsWidth)
            ? summary : nil
    }

    private var headerSummary: String? {
        guard let summary = percentSummary, usageSummary == nil else { return nil }
        return summary
    }

    /// The counts on header line 2. They are what yields to the summary beside them: the full
    /// wording first, then `AppState.compactDetail`'s shorter one, then the tail truncation
    /// `Text` does on its own. The summary itself never gives up a character.
    private var headerDetail: String {
        let detail = state.summaryDetail
        guard headerSummary != nil else { return detail }
        let available = metrics.headerDetailWidth(summaryWidth: headerSummary == nil ? 0 : summaryChipsWidth)
        guard metrics.textWidth(detail, font: metrics.rowSecondaryNSFont) > available
        else { return detail }
        return AppState.compactDetail(detail)
    }

    /// `Agents · 27` while sub-agents are running, plain `Agents` otherwise (SPEC §12.3).
    static func tabLabel(_ state: AppState) -> (PanelTab) -> String {
        { tab in
            guard tab == .agents else { return tab.label }
            let count = state.subagentCount
            return count > 0 ? "\(tab.label) · \(count)" : tab.label
        }
    }

    private func percentSummary(_ snapshot: UsageSnapshot) -> String {
        UsageChips.claudeText(snapshot) ?? ""
    }

    // MARK: Filter row (SPEC §17.3)

    /// Sessions-tab only: the state chips and the host popover. A `FlowLayout` wraps them onto a
    /// second line rather than truncating a label or spilling past the panel's edge.
    @ViewBuilder
    private var filterRow: some View {
        if state.tab == .sessions {
            SessionFilterRow(state: state, settings: settings)
                .padding(.horizontal, metrics.padding)
                .padding(.top, metrics.scaled(2))
                .padding(.bottom, metrics.scaled(6))
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch state.tab {
        case .sessions:
            SessionsListView(state: state)
                .frame(height: {
                    let sections = SessionSections(state.visibleSessions)
                    return metrics.listHeight(rows: sections.rowCount, headers: sections.headerCount)
                }())
        case .agents:
            AgentsListView(state: state)
                .frame(height: metrics.agentListHeight(rows: state.subagents.count))
        case .history:
            HistoryView(state: state)
                .frame(
                    height: metrics.historyToolbarHeight
                        + metrics.historyListHeight(
                            rows: state.historyRowCount, groups: state.historyGroups.count
                        )
                )
        case .usage:
            UsageView(state: state, settings: settings)
        // SPEC §18.3: the gauges are fixed and the list below them is capped, so the height is
        // exactly what `Theme.Metrics` said it would be.
        case .sentinel:
            SentinelView(watch: state.systemWatch, actions: SentinelActions.live(state: state))
                .frame(
                    height: metrics.sentinelContentHeight(
                        layouts: Sentinel.layouts(
                            Sentinel.sorted(state.systemWatch.signals), metrics: metrics
                        ),
                        apps: Sentinel.topApps(state.systemWatch.snapshot).count,
                        thermalChip: Sentinel.thermalChip(state.systemWatch.snapshot) != nil,
                        showsError: state.systemWatch.lastError != nil
                    )
                )
        }
    }
}

/// `2 need you` — the header's one alarm. It never wraps: line 2 beside it counts sub-agents
/// now (SPEC §9.3) and is long enough to win the width fight, which stacked this pill into three
/// lines and overflowed the fixed header height. Line 2 truncates instead; the pill does not.
struct NeedsYouPill: View {
    let count: Int

    @Environment(\.metrics) private var metrics

    var body: some View {
        Text("\(count) need you")
            .font(metrics.chip)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(Theme.needsYou)
            .padding(.horizontal, metrics.scaled(7))
            .padding(.vertical, metrics.scaled(3))
            .background(
                RoundedRectangle(cornerRadius: metrics.chipCorner, style: .continuous)
                    .fill(Theme.needsYou.opacity(0.16))
            )
    }
}

/// Three flat segments in a track — a real segmented control, without the system chrome.
struct SegmentedTabs: View {
    @Binding var selection: PanelTab
    /// Settings → General → Panel's "Show History tab": the strip only ever shows what this
    /// list carries, in `PanelTab.allCases`' own order.
    var tabs: [PanelTab] = PanelTab.allCases
    /// The Agents tab carries a live count in its own label (SPEC §12.3).
    var label: (PanelTab) -> String = { $0.label }
    /// SPEC §18.3: five tabs at the Large appearance do not fit a 360 pt panel on one line, and
    /// a label is never truncated — so the strip flows onto a second line instead. Off by
    /// default: `FlowLayout` claims the whole proposed width, which would push the usage summary
    /// off the row even when everything already fits on one line.
    var wraps = false

    @Environment(\.metrics) private var metrics

    var body: some View {
        Group {
            if wraps {
                FlowLayout(
                    spacing: metrics.tabSegmentSpacing, lineSpacing: metrics.tabSegmentSpacing
                ) {
                    segments
                }
            } else {
                HStack(spacing: metrics.tabSegmentSpacing) { segments }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: metrics.scaled(8), style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    @ViewBuilder
    private var segments: some View {
        ForEach(tabs, id: \.self) { tab in
            Button {
                selection = tab
            } label: {
                Text(label(tab))
                    .font(metrics.control)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(selection == tab ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, metrics.tabSegmentPadding(tabCount: tabs.count))
                    .frame(height: metrics.tabHeight)
                    .background(
                        RoundedRectangle(cornerRadius: metrics.chipCorner, style: .continuous)
                            .fill(selection == tab ? Theme.chipFill : Color.clear)
                    )
                    .contentShape(
                        RoundedRectangle(cornerRadius: metrics.chipCorner, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label(tab))
        }
    }
}

/// A 24 pt hit target (24 × scale once the text grows), 8 pt from its neighbour — never smaller,
/// never overlapping (SPEC §14).
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @Environment(\.metrics) private var metrics
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .accessibilityLabel(help)
                .font(metrics.control)
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: metrics.hitTarget, height: metrics.hitTarget)
                .background(
                    RoundedRectangle(cornerRadius: metrics.chipCorner, style: .continuous)
                        .fill(hovering ? Theme.hoverFill : Color.clear)
                )
                .contentShape(
                    RoundedRectangle(cornerRadius: metrics.chipCorner, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Drags the whole panel when the user grabs the header. Lives *behind* the header content.
struct WindowDragHandle: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}
}
