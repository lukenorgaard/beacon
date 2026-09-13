import CoreGraphics
import SwiftUI

extension Theme.Metrics {
        // MARK: - Sentinel (SPEC §18.3)

        /// One of the four gauges: section label, the number, and the line under it. Fixed, so
        /// the panel's own height math stays exact — the same contract `usageCardHeight` has.
        var sentinelGaugeHeight: CGFloat { rounded(62) }
        var sentinelGaugeGap: CGFloat { max(6, scaled(6)) }
        /// The thermal chip's row, which only exists while the machine is not nominal (§18.3).
        var sentinelChipRowHeight: CGFloat { rounded(26) }
        var sentinelSectionHeaderHeight: CGFloat { rounded(20) }
        /// One line of a warning row's title, and one of its body text. A row is built from these
        /// (SPEC §18.3), so the height the window reserves and the height the row draws at are
        /// the same arithmetic.
        var sentinelTitleLineHeight: CGFloat { rounded(16) }
        var sentinelBodyLineHeight: CGFloat { rounded(14) }
        var sentinelRowLineGap: CGFloat { scaled(2) }
        /// The air above and below a warning row's content.
        var sentinelWarningPadding: CGFloat { scaled(8) }
        /// The one muted line a failed action leaves under its own row (§18.4: never a second
        /// alert).
        var sentinelInlineErrorHeight: CGFloat { rounded(16) }
        /// `lastError` at the top of the list (§18.6: a sampler that fails says so).
        var sentinelErrorLineHeight: CGFloat { rounded(18) }
        /// "Nothing to report" plus the sample time — shorter than `emptyHeight`, because the
        /// gauges above it are already carrying the tab.
        var sentinelEmptyHeight: CGFloat { rounded(64) }
        /// One "Top CPU" row: name · CPU % · memory, all on one line.
        var sentinelAppRowHeight: CGFloat { rounded(20) }
        var sentinelHistoryHeight: CGFloat { rounded(104) }

        /// SPEC §18.3: how much width a warning row's text column really gets — the row inside
        /// the list's padding, minus its own inset, the severity bar, the gaps, and the widest
        /// button in its trailing column. This is what decides whether the title fits on one line
        /// beside its duration, and it is measured rather than assumed because the answer changes
        /// with the button's label and the selected text size.
        func sentinelWarningTextWidth(buttonLabels: [String]) -> CGFloat {
            let widest = buttonLabels
                .map { textWidth($0, font: controlNSFont) + 2 * scaled(9) }
                .max() ?? 0
            var available = width - 2 * padding - 2 * rowInset - accentBarWidth - controlGap
            if widest > 0 { available -= controlGap + widest }
            return max(0, available)
        }

        /// SPEC §18.4: a warning can carry an action button and, when its culprit is a Lookout
        /// session, a Jump beside it. They stack in the row's right-hand column with SPEC §14's
        /// 8 pt between them, so a row is never shorter than its own buttons.
        func sentinelWarningRowHeight(_ layout: SentinelRowLayout) -> CGFloat {
            var content = CGFloat(max(1, layout.titleLines)) * sentinelTitleLineHeight
            if layout.durationBelowTitle {
                content += sentinelRowLineGap + sentinelBodyLineHeight
            }
            if layout.adviceLines > 0 {
                content += sentinelRowLineGap
                    + CGFloat(layout.adviceLines) * sentinelBodyLineHeight
            }
            let stack = layout.buttons > 0
                ? CGFloat(layout.buttons) * buttonHeight
                    + CGFloat(layout.buttons - 1) * controlGap
                : 0
            return max(content, stack) + 2 * sentinelWarningPadding
        }

        /// The Warnings list itself: one entry per signal, plus a line for each row currently
        /// showing an inline action error.
        func sentinelWarningsHeight(
            layouts: [SentinelRowLayout], inlineErrors: Int = 0
        ) -> CGFloat {
            guard !layouts.isEmpty else { return sentinelEmptyHeight }
            return layouts.reduce(0) { $0 + sentinelWarningRowHeight($1) }
                + CGFloat(layouts.count - 1) * rowGap
                + CGFloat(inlineErrors) * sentinelInlineErrorHeight
        }

        /// The fixed block above the scroll view: the gauges, and the thermal chip when there
        /// is one. It never scrolls — the numbers are the reason the tab exists.
        func sentinelGaugesHeight(thermalChip: Bool) -> CGFloat {
            sentinelGaugeHeight + (thermalChip ? sentinelGaugeGap + sentinelChipRowHeight : 0)
        }

        /// Everything under the gauges, before the `listMaxHeight` cap. It counts what the view
        /// actually stacks: an optional `lastError` line, the Warnings header and body, and —
        /// when there are apps — the Top CPU header and one child per app. `SentinelView`'s
        /// `VStack` puts `rowGap` between *every* child, which is why the gaps are counted from
        /// the child count rather than folded into each block.
        private func sentinelListContentHeight(
            layouts: [SentinelRowLayout], apps: Int, showsError: Bool, inlineErrors: Int
        ) -> CGFloat {
            var height: CGFloat = sentinelHistoryHeight
            var children = 1

            if showsError {
                height += sentinelErrorLineHeight
                children += 1
            }
            height += sentinelSectionHeaderHeight
            height += sentinelWarningsHeight(layouts: layouts, inlineErrors: inlineErrors)
            children += 2

            if apps > 0 {
                // The Top CPU header carries a little extra air above it, so the two sections do
                // not read as one list.
                height += sentinelSectionHeaderHeight + (sentinelGaugeGap - rowGap)
                height += CGFloat(apps) * sentinelAppRowHeight
                children += 1 + apps
            }

            return height + CGFloat(max(0, children - 1)) * rowGap
        }

        /// SPEC §18.3: the list scrolls inside `listMaxHeight` exactly like History's does, so a
        /// machine with eleven warnings cannot push the window off the screen.
        func sentinelListOverflows(
            layouts: [SentinelRowLayout], apps: Int, showsError: Bool = false, inlineErrors: Int = 0
        ) -> Bool {
            sentinelListContentHeight(
                layouts: layouts, apps: apps,
                showsError: showsError, inlineErrors: inlineErrors
            ) > listMaxHeight
        }

        func sentinelListHeight(
            layouts: [SentinelRowLayout], apps: Int, showsError: Bool = false, inlineErrors: Int = 0
        ) -> CGFloat {
            min(
                sentinelListContentHeight(
                    layouts: layouts, apps: apps,
                    showsError: showsError, inlineErrors: inlineErrors
                ),
                listMaxHeight
            )
        }

        /// The whole tab: the fixed gauges plus the capped list.
        func sentinelContentHeight(
            layouts: [SentinelRowLayout], apps: Int, thermalChip: Bool = false,
            showsError: Bool = false, inlineErrors: Int = 0
        ) -> CGFloat {
            sentinelGaugesHeight(thermalChip: thermalChip)
                + sentinelGaugeGap
                + sentinelListHeight(
                    layouts: layouts, apps: apps,
                    showsError: showsError, inlineErrors: inlineErrors
                )
        }
}
