import CoreGraphics
import SwiftUI

extension Theme.Metrics {
        // MARK: - Context chip fit (SPEC §19.2)

        /// The AppKit twin of `chip`, for measuring `ctx 62 %` before it is built.
        var chipNSFont: NSFont { .systemFont(ofSize: 10 * appearance.scale, weight: .medium) }

        /// SPEC §19.2/§19.4: "the chip yields before the title does". Twelve characters is the
        /// floor: enough of a session name to recognise it, and what the render test holds the
        /// row to at 360 pt.
        static let contextNameFloor = 12

        /// The widest the duration label on the right of a row ever gets (`1h 59m`). Reserved
        /// rather than measured per row, so the chip cannot appear and disappear as a session's
        /// own clock rolls from `59s` to `1m`.
        var durationReserve: CGFloat { textWidth("1h 59m", font: numeralNSFont) }

        /// The `TimelineView` the duration ticks inside asks a row for more width than the text
        /// it draws — measured at ~24 pt × scale off a real row render, with the text sitting at
        /// its trailing edge — so line 2 has that much less room than the arithmetic above
        /// suggests. Reserved with a couple of points to spare: being wrong in this direction
        /// costs a chip, being wrong in the other costs the session name.
        var durationSlack: CGFloat { scaled(28) }

        /// What line 2 of a row has to lay out in: the panel, minus the list's insets, the row's
        /// own padding, the accent bar and the gap after it, then the duration label (and the
        /// pin glyph when there is one) on the right with its `controlGap`.
        func rowTextWidth(pinned: Bool = false) -> CGFloat {
            var available = width - 2 * listInset - 2 * rowInset - accentBarWidth - rowInset
            available -= controlGap + durationReserve + durationSlack
            if pinned { available -= controlGap + glyphSize }
            return max(0, available)
        }

        /// The chip's own width: its text, plus the dot and its gap when it is over threshold.
        func contextChipWidth(_ text: String, dot: Bool) -> CGFloat {
            textWidth(text, font: chipNSFont) + (dot ? contextDotSize + contextDotGap : 0)
        }

        /// SPEC §19.2: whether line 2 can hold the chip *and* keep the first
        /// `contextNameFloor` characters of the session name. False means the row draws no chip
        /// at all — the percentage is a glance, and half a glyph of it is worse than none.
        func contextChipFits(name: String?, chip: String, dot: Bool, pinned: Bool = false) -> Bool {
            let floor = Self.contextNameFloor
            let kept = (name?.count ?? 0) > floor
                ? String((name ?? "").prefix(floor)) + "…"
                : (name ?? "")
            let needed = textWidth(kept, font: rowSecondaryNSFont)
                + (kept.isEmpty ? 0 : controlGap)
                + contextChipWidth(chip, dot: dot)
            return needed <= rowTextWidth(pinned: pinned)
        }

        // MARK: - Tab strip fit (SPEC §18.3)

        /// The AppKit twin of `control` — `Text` measures itself, but the *strip* has to be
        /// measured before it is built, to decide whether the usage summary still has room.
        /// Same size and weight as `control`, or the answer would be about a different font.
        var controlNSFont: NSFont {
            .systemFont(ofSize: 11.5 * appearance.scale, weight: .medium)
        }

        /// The AppKit twin of `numeral` (the trailing "64 % · 77 %").
        var numeralNSFont: NSFont {
            .monospacedDigitSystemFont(ofSize: 11 * appearance.scale, weight: .medium)
        }

        /// The AppKit twins of `rowTitle` and `rowSecondary` — a warning row has to know how many
        /// lines its title and its advice will take *before* the window is sized (SPEC §18.3),
        /// and SPEC §19.2's context chip measures line 2 against the same body font.
        var rowTitleNSFont: NSFont {
            .systemFont(ofSize: 12.5 * appearance.scale, weight: .semibold)
        }

        var rowSecondaryNSFont: NSFont { .systemFont(ofSize: 11 * appearance.scale) }

        /// How wide a string draws. Rounded up, so a measurement never claims something fits by
        /// a fraction of a point.
        func textWidth(_ string: String, font: NSFont) -> CGFloat {
            (string as NSString)
                .size(withAttributes: [.font: font])
                .width
                .rounded(.up)
        }

        /// A measurement's safety margin against SwiftUI's own line breaking: `textWidth` and
        /// `Text` agree to well under this, and a point of disagreement must never be what
        /// decides whether a line wraps.
        var measurementSlack: CGFloat { 2 }

        /// SPEC §18.3: the segments tighten before anything else on the row gives. 9 pt a side up
        /// to three tabs; 7 from the fourth on, which is what buys the usage summary its place
        /// beside a four-tab strip at 360 pt. It follows the tab *count* and not whether a
        /// summary happens to be showing, so the segments never resize when the tab changes.
        func tabSegmentPadding(tabCount: Int) -> CGFloat {
            max(4, scaled(tabCount >= 4 ? 7 : 9))
        }

        /// One `SegmentedTabs` segment: its label at its natural width (the label is
        /// `fixedSize`, so it never gives any of it back) plus the segment's own padding.
        func tabSegmentWidth(_ label: String, tabCount: Int) -> CGFloat {
            textWidth(label, font: controlNSFont) + 2 * tabSegmentPadding(tabCount: tabCount)
        }

        /// The whole strip: every segment, the 2 pt between them, and the track's 2 pt padding.
        func tabStripWidth(labels: [String]) -> CGFloat {
            guard !labels.isEmpty else { return 0 }
            return labels.reduce(0) { $0 + tabSegmentWidth($1, tabCount: labels.count) }
                + CGFloat(labels.count - 1) * tabSegmentSpacing
                + 4
        }

        /// Whether the whole strip fits the panel's width on one line, with the tab row's own
        /// padding. False only in the corner Settings can build (History *and* Sentinel on, at
        /// the largest text size in a narrow panel).
        func tabStripFitsPanel(labels: [String]) -> Bool {
            tabStripRows(labels: labels) == 1
        }

        /// SPEC §18.3: a tab label is never truncated, so when five of them do not fit 360 pt the
        /// strip wraps onto a second line — the same answer SPEC §17.3's filter chips already
        /// give. Greedy packing, matching `FlowLayout`'s own, over the same segment widths the
        /// strip is built from.
        func tabStripRows(labels: [String]) -> Int {
            let available = width - 2 * padding - 4
            guard available > 0, !labels.isEmpty else { return 1 }
            var rows = 1
            var line: CGFloat = 0
            for label in labels {
                let segment = tabSegmentWidth(label, tabCount: labels.count)
                let added = line == 0 ? segment : line + tabSegmentSpacing + segment
                if line > 0, added > available {
                    rows += 1
                    line = segment
                } else {
                    line = added
                }
            }
            return rows
        }

        /// Between two segments, and between two wrapped lines of them. Not scaled: it is the
        /// seam inside one control, not type.
        var tabSegmentSpacing: CGFloat { 2 }

        /// The tab row's height: `tabsHeight` for one line, plus a segment's height for each
        /// extra line the labels wrapped onto. The window is sized from this, so it has to be
        /// the number and not a guess.
        func tabsHeight(rows: Int) -> CGFloat {
            tabsHeight + CGFloat(max(0, rows - 1)) * (tabHeight + tabSegmentSpacing)
        }

        /// SPEC §18.3: with a fourth tab on the strip the trailing usage summary is what yields —
        /// never a tab label, which is `fixedSize` and would simply run off the panel's edge.
        /// The row is `HStack(spacing: controlGap) { strip; Spacer(minLength: controlGap); text }`,
        /// so the gap between the two is three `controlGap`s at its narrowest.
        ///
        /// Yielding here does not mean disappearing: when this is false the summary moves to the
        /// header's second line instead (`headerDetailWidth`). the owner reads those two percentages
        /// constantly — they are never simply dropped.
        func tabStripFitsSummary(labels: [String], summary: String) -> Bool {
            let needed = 2 * padding
                + tabStripWidth(labels: labels)
                + 3 * controlGap
                + textWidth(summary, font: numeralNSFont)
            return needed <= width
        }

        /// What the header's second line has for its counts once the usage summary has taken its
        /// place at the right of the same row. The line is indented under the headline text, past
        /// the status dot and its gap.
        func headerDetailWidth(summary: String?) -> CGFloat {
            var available = width - 2 * padding - (scaled(7) + controlGap)
            if let summary, !summary.isEmpty {
                available -= controlGap + textWidth(summary, font: numeralNSFont)
            }
            return max(0, available)
        }

        // MARK: - Panel height (the window is sized from these, never from SwiftUI)

        func listOverflows(rows: Int) -> Bool {
            guard rows > 0 else { return false }
            return CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowGap > listMaxHeight
        }

        func listHeight(rows: Int) -> CGFloat {
            guard rows > 0 else { return emptyHeight }
            let content = CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowGap
            return min(content, listMaxHeight)
        }

        func agentListOverflows(rows: Int) -> Bool {
            guard rows > 0 else { return false }
            return CGFloat(rows) * agentRowHeight + CGFloat(rows - 1) * rowGap > listMaxHeight
        }

        /// SPEC §12.3's Agents tab, capped exactly like the sessions list.
        func agentListHeight(rows: Int) -> CGFloat {
            guard rows > 0 else { return emptyHeight }
            let content = CGFloat(rows) * agentRowHeight + CGFloat(rows - 1) * rowGap
            return min(content, listMaxHeight)
        }

        /// SPEC §17.6/§17.7: the Codex section and the Sessions Today section are optional extras
        /// stacked after the Claude limit cards — `codexCards`/`sessionsToday` default to 0 so
        /// every existing caller keeps working unchanged.
        func usageHeight(
            cards: Int, extraLine: Bool, codexCards: Int = 0, sessionsToday: Int = 0
        ) -> CGFloat {
            let cardCount = max(cards, 0)
            let hasExtras = codexCards > 0 || sessionsToday > 0
            let content = (cardCount == 0 && !hasExtras)
                ? emptyHeight
                : CGFloat(cardCount) * usageCardHeight
                    + CGFloat(max(0, cardCount - 1)) * usageCardGap
            let extra: CGFloat = extraLine ? extraUsageLineHeight : 0
            let codex = codexSectionHeight(cards: codexCards)
            let sessions = sessionsTodayHeight(rows: sessionsToday)
            return min(content + extra + codex + sessions, listMaxHeight)
        }

        func totalHeight(
            tab: PanelTab, rows: Int, cards: Int, extraLine: Bool, agents: Int = 0,
            historyRows: Int = 0, historyGroups: Int = 0,
            codexCards: Int = 0, sessionsToday: Int = 0, sessionHeaders: Int = 0,
            sentinelRows: [SentinelRowLayout] = [], sentinelApps: Int = 0,
            sentinelThermalChip: Bool = false, sentinelError: Bool = false,
            tabRows: Int = 1
        ) -> CGFloat {
            let content: CGFloat
            switch tab {
            case .sessions: content = listHeight(rows: rows, headers: sessionHeaders)
            case .agents: content = agentListHeight(rows: agents)
            case .history:
                content = historyToolbarHeight + historyListHeight(rows: historyRows, groups: historyGroups)
            case .usage:
                content = usageHeight(
                    cards: cards, extraLine: extraLine,
                    codexCards: codexCards, sessionsToday: sessionsToday
                ) + footerHeight
            // SPEC §18.3: the gauges are fixed, the warnings and Top CPU below them scroll
            // inside `listMaxHeight` the way History's rows do.
            case .sentinel:
                content = sentinelContentHeight(
                    layouts: sentinelRows, apps: sentinelApps,
                    thermalChip: sentinelThermalChip, showsError: sentinelError
                )
            }
            return headerHeight + tabsHeight(rows: tabRows) + content + bottomPadding
        }
}
