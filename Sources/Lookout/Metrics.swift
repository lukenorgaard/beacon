import CoreGraphics
import SwiftUI

extension Theme {
    /// SPEC §14: every font and every measurement the panel, the card and the setup window draw
    /// themselves with, as a *value* computed from `Appearance`.
    ///
    /// It is a value and not a set of statics on purpose: two windows can be laid out at two
    /// different scales in the same process (which is exactly what the render tests do), and a
    /// mutable global would make one of them wrong. SwiftUI reads it from the environment
    /// (`@Environment(\.metrics)`); the AppKit controllers read the same value off `Settings`.
    struct Metrics: Equatable {
        var appearance: Appearance

        init(_ appearance: Appearance = .standard) { self.appearance = appearance }

        /// What the app ships with, and the environment's default.
        static let standard = Metrics()

        var scale: CGFloat { appearance.scale }
        var density: PanelDensity { appearance.density }

        // MARK: - Scaling

        /// A measurement in points. Landed on half points, which is where retina pixels are.
        func scaled(_ value: CGFloat) -> CGFloat { (value * appearance.scale * 2).rounded() / 2 }

        /// A measurement a *window* is sized from: whole points, so the height the panel asks
        /// for and the height SwiftUI lays out agree exactly.
        func rounded(_ value: CGFloat) -> CGFloat { (value * appearance.scale).rounded() }

        func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .system(size: size * appearance.scale, weight: weight)
        }

        func monoFont(_ size: CGFloat) -> Font {
            .system(size: size * appearance.scale, design: .monospaced)
        }

        // MARK: - Fonts

        var header: Font { font(13, .semibold) }
        var rowTitle: Font { font(12.5, .semibold) }
        var rowSecondary: Font { font(11) }
        var chip: Font { font(10, .medium) }
        var numeral: Font { font(11, .medium).monospacedDigit() }
        var bigNumeral: Font { font(13, .semibold).monospacedDigit() }
        /// Tabs and buttons — the one control font.
        var control: Font { font(11.5, .medium) }
        var sectionLabel: Font { font(9.5, .semibold) }
        var glyph: Font { font(10) }
        var glyphLetter: Font { font(8.5, .semibold) }
        var mono: Font { monoFont(11) }
        var editorFont: Font { font(12) }
        var setupTitle: Font { font(15, .semibold) }
        var caption: Font { font(10) }

        // MARK: - Paddings and radii

        var padding: CGFloat { scaled(14) }
        var controlGap: CGFloat { max(8, scaled(8)) }
        var corner: CGFloat { scaled(14) }
        var rowCorner: CGFloat { scaled(10) }
        var chipCorner: CGFloat { scaled(6) }
        var rowGap: CGFloat { scaled(4) }
        /// Inside a row, left and right of its content.
        var rowInset: CGFloat { scaled(10) }
        /// Between the panel's edge and a row's. Never narrower than the resize zone, so the
        /// right edge grip cannot sit on top of a row (SPEC §14).
        var listInset: CGFloat { max(resizeEdge, scaled(8)) }
        var chipPaddingH: CGFloat { scaled(6) }
        var chipPaddingV: CGFloat { scaled(2) }
        /// Strokes stay 1 pt at every scale — a hairline is a hairline (SPEC §14).
        var stroke: CGFloat { 1 }

        // MARK: - Panel

        var width: CGFloat { appearance.panelWidth }
        var headerHeight: CGFloat { rounded(60) }
        var tabsHeight: CGFloat { rounded(36) }
        var rowHeight: CGFloat { rounded(appearance.density.rowHeight) }
        /// An Agents row is still two lines (SPEC §15.3), with no accent bar to clear.
        var agentRowHeight: CGFloat { rounded(appearance.density.twoLineRowHeight - 6) }
        var listMaxHeight: CGFloat { appearance.listMaxHeight }
        var emptyHeight: CGFloat { rounded(132) }
        var usageCardHeight: CGFloat { rounded(68) }
        var usageCardGap: CGFloat { scaled(8) }
        var footerHeight: CGFloat { rounded(32) }
        /// The strip of air under the content — and the corner grip's own square, which is why
        /// it never gets smaller than the 12 pt it is at scale 1.
        var bottomPadding: CGFloat { max(12, scaled(12)) }
        var extraUsageLineHeight: CGFloat { rounded(20) }

        /// The accent bar down the left of a row: 3 pt wide at every scale (SPEC §5.2), as tall
        /// as the three lines it marks (SPEC §15.3).
        var accentBarWidth: CGFloat { 3 }
        var accentBarHeight: CGFloat { scaled(44) }
        /// The usage bar (SPEC §5.3).
        var barHeight: CGFloat { scaled(6) }
        var glyphSize: CGFloat { scaled(14) }
        /// SPEC §19.2: the filled dot in front of an over-threshold context chip.
        var contextDotSize: CGFloat { scaled(6) }
        /// Between that dot and the `ctx 62 %` beside it. Type spacing, not a control gap —
        /// nothing here is clickable.
        var contextDotGap: CGFloat { scaled(4) }

        /// SPEC §14: no clickable thing is ever smaller than 24 pt, or than 24 pt × scale. The
        /// tabs and the quiet buttons used to be 22 pt tall; the floor is what raises them.
        var hitTarget: CGFloat { max(24, rounded(24)) }
        var buttonHeight: CGFloat { max(hitTarget, rounded(26)) }
        var tabHeight: CGFloat { max(hitTarget, rounded(22)) }

        // MARK: - Resize zones (SPEC §14)

        /// The right edge's drag zone. Fixed at 8 pt: it is a grab handle, not type.
        var resizeEdge: CGFloat { 8 }
        /// The bottom-right corner's square. Exactly the bottom strip of air, so it sits over
        /// nothing that can be clicked.
        var resizeCorner: CGFloat { bottomPadding }

        // MARK: - Attention card (SPEC §11.4)

        var cardWidth: CGFloat { appearance.cardWidth }
        var cardMaxHeight: CGFloat { rounded(560) }
        var cardMinHeight: CGFloat { rounded(160) }
        var dockGap: CGFloat { scaled(8) }
        var commandMaxLines: Int { 6 }
        var commandLineHeight: CGFloat { scaled(14.5) }
        var commandBoxPadding: CGFloat { scaled(8) }
        var commandBoxMaxHeight: CGFloat {
            commandLineHeight * CGFloat(commandMaxLines) + 2 * commandBoxPadding
        }
        var editorHeight: CGFloat { rounded(76) }
        var optionsMaxHeight: CGFloat { rounded(110) }
        /// Bug fix 2026-09-04: a Codex call can ask several questions at once — capped and
        /// scrollable, the same way the command box and the single-question options list already
        /// are, so a three- or four-question call cannot push the whole card past `cardMaxHeight`.
        var questionsListMaxHeight: CGFloat { rounded(100) }

        // MARK: - Rename panel (SPEC §15.4)

        /// SPEC §15.4 says 320 pt, and at the shipped scale that is exactly what this is. It
        /// still follows the text size, because a panel that did not would be the one window in
        /// Lookout whose field ignored §14.
        var renameWidth: CGFloat { rounded(320) }
        var renameFieldHeight: CGFloat { max(hitTarget, rounded(26)) }

        // MARK: - Setup window (SPEC §10.2)

        /// Wider than the panel: its rows carry a sentence each.
        var setupWidth: CGFloat { rounded(460) }
        /// The six rows fit in 620 pt at scale 1 and the ScrollView is the safety net above
        /// that. Capped, because the screen does not grow with the text: a window taller than
        /// this would hang off a 900 pt laptop screen.
        var setupBodyHeight: CGFloat { min(rounded(620), 700) }
        var setupCardGap: CGFloat { scaled(10) }

        // MARK: - History (SPEC §17.5)

        /// The search field + filter chip row.
        var historyToolbarHeight: CGFloat { rounded(64) }
        /// Two lines: time/dot/name, then `from → to (reason) · detail`.
        var historyRowHeight: CGFloat { rounded(42) }
        var historyGroupHeaderHeight: CGFloat { rounded(20) }

        private func historyContentHeight(rows: Int, groups: Int) -> CGFloat {
            CGFloat(rows) * historyRowHeight + CGFloat(max(0, rows - 1)) * rowGap
                + CGFloat(groups) * (historyGroupHeaderHeight + rowGap)
        }

        func historyListOverflows(rows: Int, groups: Int) -> Bool {
            guard rows > 0 else { return false }
            return historyContentHeight(rows: rows, groups: groups) > listMaxHeight
        }

        /// The scrollable list alone — the toolbar is sized separately (`historyToolbarHeight`)
        /// so the search field never scrolls out of reach with the rows.
        func historyListHeight(rows: Int, groups: Int) -> CGFloat {
            guard rows > 0 else { return emptyHeight }
            return min(historyContentHeight(rows: rows, groups: groups), listMaxHeight)
        }

        // MARK: - Usage: Codex section + Sessions today (SPEC §17.6, §17.7)

        var codexSectionHeaderHeight: CGFloat { rounded(20) }
        var sessionsTodaySectionHeaderHeight: CGFloat { rounded(20) }
        var sessionsTodayRowHeight: CGFloat { rounded(20) }
        /// SPEC's cost-chip wording fix: the section's two 9 pt caption lines ("API-equivalent
        /// estimate…" and "Live sessions only…"), below the priced rows.
        var sessionsTodayCaptionHeight: CGFloat { rounded(28) }

        /// One bar per Codex window (5 h alone, or 5 h + weekly) plus its header line.
        func codexSectionHeight(cards: Int) -> CGFloat {
            guard cards > 0 else { return 0 }
            return codexSectionHeaderHeight
                + CGFloat(cards) * usageCardHeight + CGFloat(max(0, cards - 1)) * usageCardGap
        }

        /// The header line, up to five session rows, and the two caption lines under them.
        func sessionsTodayHeight(rows: Int) -> CGFloat {
            guard rows > 0 else { return 0 }
            return sessionsTodaySectionHeaderHeight + CGFloat(rows) * sessionsTodayRowHeight
                + sessionsTodayCaptionHeight
        }
    }
}
