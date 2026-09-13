import AppKit
import SwiftUI
import XCTest
@testable import Lookout

// MARK: - Sentinel tab (SPEC §18.3)

extension PanelRenderTests {
    /// SPEC §18.7: the tab at 0.85 / 1 / 1.25 with nothing to report, with one warning, and with
    /// four warnings plus five Top CPU rows — a PNG each under `LOOKOUT_RENDER_DIR`, and nothing
    /// taller than the window `Theme.Metrics` asks for.
    func testTheSentinelTabRendersAtEveryAppearanceWithZeroOneAndFourWarnings() throws {
        let cases: [(name: String, appearance: Appearance)] = [
            ("085", Appearance(scale: 0.85, panelWidth: 320, listMaxHeight: 320, density: .compact)),
            ("100", Appearance.standard),
            ("125", Appearance(scale: 1.25, panelWidth: 460, listMaxHeight: 480, density: .comfortable)),
        ]
        for (name, appearance) in cases {
            for warnings in [0, 1, 4] {
                settings.appearance = appearance
                state.tab = .sentinel
                state.systemWatch.snapshot = PanelRenderTests.sentinelSnapshot()
                state.systemWatch.signals = PanelRenderTests.sentinelSignals(count: warnings)

                let usedMetrics = settings.metrics
                let signals = Sentinel.sorted(state.systemWatch.signals)
                let expected = usedMetrics.totalHeight(
                    tab: .sentinel, rows: 0, cards: 0, extraLine: false,
                    sentinelRows: Sentinel.layouts(signals, metrics: usedMetrics),
                    sentinelApps: Sentinel.topApps(state.systemWatch.snapshot).count,
                    sentinelThermalChip: Sentinel.thermalChip(state.systemWatch.snapshot) != nil,
                    sentinelError: state.systemWatch.lastError != nil
                )

                let size = render(
                    PanelView(state: state, settings: settings, onTogglePin: {}, onOpenSettings: {}),
                    named: "panel-sentinel-\(warnings)w-\(name)"
                )
                XCTAssertEqual(size.width, usedMetrics.width, accuracy: 0.5)
                // `PanelView` draws header + tabs + content; the window adds `bottomPadding`
                // under it (that strip of air is also the corner resize grip). Equal, not merely
                // "no taller": a tab that under-fills its own window is as wrong as one that
                // overflows it.
                XCTAssertEqual(
                    size.height + usedMetrics.bottomPadding, expected, accuracy: 1,
                    "\(name)/\(warnings) warnings: the tab did not lay out at the height its " +
                        "own metrics ask the window for"
                )
            }
        }
    }

    /// Every warning row draws at exactly the height its own measured layout asks for — and its
    /// content fits inside that height rather than being clipped by the frame. Four shapes:
    /// duration inline, duration below a one-line title, a wrapped two-line title, and the
    /// action-plus-Jump row that has two buttons stacked in its trailing column.
    func testEveryWarningRowShapeDrawsAtTheHeightItsLayoutAsksFor() {
        let orphan = SystemSignal(
            id: "process.orphaned", severity: .critical,
            title: "An orphaned agent is still running",
            detail: "pid 4242 has no parent and is using 96 % CPU",
            advice: ["Stop it, or jump to the session that started it."],
            culprit: "node", since: Date().addingTimeInterval(-900),
            action: .stopProcess(pid: 4242, name: "node"), sessionID: "s-1"
        )
        let signals = PanelRenderTests.sentinelSignals(count: 4) + [orphan]

        for appearance in [
            Appearance(scale: 0.85, panelWidth: 320, listMaxHeight: 320, density: .compact),
            Appearance.standard,
            Appearance(scale: 1.25, panelWidth: 360, listMaxHeight: 360, density: .standard),
            Appearance(scale: 1.25, panelWidth: 460, listMaxHeight: 480, density: .comfortable),
        ] {
            settings.appearance = appearance
            let usedMetrics = settings.metrics
            let width = usedMetrics.width - 2 * usedMetrics.padding
            let now = Date()

            for signal in signals {
                let rowLayout = Sentinel.layout(for: signal, metrics: usedMetrics, now: now)
                let row = layout(
                    SentinelWarningRow(
                        signal: signal, now: now,
                        onJump: signal.sessionID == nil ? nil : {}
                    )
                    .frame(width: width)
                    .environment(\.metrics, usedMetrics)
                )
                XCTAssertEqual(
                    row.height, usedMetrics.sentinelWarningRowHeight(rowLayout), accuracy: 0.5,
                    "\(signal.id) at \(appearance.scale)×/\(appearance.panelWidth)"
                )

                // The text really fits: measured on its own, the title/duration/advice stack is
                // no taller than the row minus its padding. A frame hides overflow silently, so
                // the frame alone proves nothing.
                let textWidth = usedMetrics.sentinelWarningTextWidth(
                    buttonLabels: Sentinel.buttonLabels(signal)
                )
                let duration = Sentinel.durationText(since: signal.since, now: now)
                // Inline, the title only gets what the duration beside it leaves — measuring it
                // at the full column width is how a wrapped title slipped through once already.
                let titleWidth = rowLayout.durationBelowTitle
                    ? textWidth
                    : textWidth - usedMetrics.scaled(6)
                        - usedMetrics.textWidth(duration, font: usedMetrics.numeralNSFont)
                let text = layout(
                    VStack(alignment: .leading, spacing: usedMetrics.sentinelRowLineGap) {
                        Text(signal.title).font(usedMetrics.rowTitle).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: titleWidth, alignment: .leading)
                        if rowLayout.durationBelowTitle {
                            Text(duration).font(usedMetrics.numeral)
                        }
                        if let advice = signal.advice.first {
                            Text(advice).font(usedMetrics.rowSecondary).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: textWidth, alignment: .leading)
                        }
                    }
                    .environment(\.metrics, usedMetrics)
                )
                XCTAssertLessThanOrEqual(
                    text.height,
                    usedMetrics.sentinelWarningRowHeight(rowLayout)
                        - 2 * usedMetrics.sentinelWarningPadding,
                    "\(signal.id) at \(appearance.scale)×/\(appearance.panelWidth): its lines " +
                        "do not fit the row the metrics reserve for it"
                )
            }
        }
    }

    /// SPEC §18.3's strip rule, rendered so it can be looked at: four tabs at 360 pt at scale 1
    /// and 1.25, and the five-tab case with History switched on. A tab label is `fixedSize`, so
    /// "fits" means the whole row is no wider than the panel — nothing is truncated or clipped.
    func testTheTabStripFitsAtThreeSixtyWithSentinelOn() {
        let summary = "64% · 77%"
        let cases: [(name: String, scale: CGFloat, history: Bool)] = [
            ("100", 1.0, false),
            ("125", 1.25, false),
            ("100-history", 1.0, true),
            ("125-history", 1.25, true),
        ]
        for entry in cases {
            settings.appearance = Appearance(
                scale: entry.scale, panelWidth: 360, listMaxHeight: 360, density: .standard
            )
            settings.showHistoryTab = entry.history
            let usedMetrics = settings.metrics
            let labels = PanelTab
                .visibleCases(showHistory: entry.history, showSentinel: true)
                .map(\.label)

            let rows = usedMetrics.tabStripRows(labels: labels)
            let strip = render(
                HStack(spacing: usedMetrics.controlGap) {
                    SegmentedTabs(
                        selection: .constant(.sentinel),
                        tabs: PanelTab.visibleCases(showHistory: entry.history, showSentinel: true),
                        wraps: rows > 1
                    )
                    Spacer(minLength: usedMetrics.controlGap)
                    if usedMetrics.tabStripFitsSummary(labels: labels, summary: summary) {
                        Text(summary).font(usedMetrics.numeral)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, usedMetrics.padding)
                .frame(width: usedMetrics.width)
                .frame(height: usedMetrics.tabsHeight(rows: rows))
                .background(Theme.windowBackground)
                .environment(\.metrics, usedMetrics)
                .environment(\.colorScheme, .dark),
                named: "tabstrip-360-\(entry.name)"
            )

            XCTAssertEqual(strip.width, usedMetrics.width, accuracy: 0.5)
            XCTAssertLessThanOrEqual(strip.height, usedMetrics.tabsHeight(rows: rows))
            if entry.history, entry.scale > 1 {
                // Five tabs at 1.25× do not fit 360 pt on one line, so the strip flows onto a
                // second — no label is truncated and the window grows to hold it.
                XCTAssertEqual(rows, 2, "\(entry.name)")
                XCTAssertGreaterThan(
                    usedMetrics.tabsHeight(rows: rows), usedMetrics.tabsHeight,
                    "a wrapped strip needs a taller tab row, and the window has to know"
                )
            } else {
                XCTAssertEqual(
                    rows, 1,
                    "\(entry.name): this strip has to fit 360 pt on one line (SPEC §18.3)"
                )
                XCTAssertTrue(usedMetrics.tabStripFitsPanel(labels: labels))
            }
            // the owner's review: the summary is not dropped. At 360/1× the tighter four-tab
            // segments hold it beside the strip; anywhere it cannot fit, `PanelView` puts it on
            // the header's second line instead — never nowhere, never both.
            XCTAssertEqual(
                usedMetrics.tabStripFitsSummary(labels: labels, summary: summary),
                !entry.history && entry.scale == 1.0,
                "\(entry.name)"
            )
        }
    }

    /// The four gauges at 360 pt: four equal columns, no column narrower than its neighbours,
    /// and the whole row inside the height the metrics reserve for it.
    func testTheGaugesFitFourEqualColumnsAtEveryAppearance() {
        for appearance in [
            Appearance(scale: 0.85, panelWidth: 320, listMaxHeight: 320, density: .compact),
            Appearance.standard,
            Appearance(scale: 1.25, panelWidth: 360, listMaxHeight: 360, density: .standard),
        ] {
            settings.appearance = appearance
            let usedMetrics = settings.metrics
            let gauges = render(
                SentinelGaugesView(
                    snapshot: PanelRenderTests.sentinelSnapshot(), thermalChip: "Thermal · Serious"
                )
                .frame(width: usedMetrics.width)
                .background(Theme.windowBackground)
                .environment(\.metrics, usedMetrics)
                .environment(\.colorScheme, .dark),
                named: "sentinel-gauges-\(Int(appearance.scale * 100))-w\(Int(appearance.panelWidth))"
            )
            XCTAssertEqual(gauges.width, usedMetrics.width, accuracy: 0.5)
            XCTAssertEqual(
                gauges.height, usedMetrics.sentinelGaugesHeight(thermalChip: true), accuracy: 0.5,
                "the gauges plus the thermal chip's own row"
            )

            // One column's three lines, inside the card's fixed height with room to spare.
            let card = layout(
                SentinelGaugeCard(gauge: Sentinel.gauges(PanelRenderTests.sentinelSnapshot())[1])
                    .frame(width: (usedMetrics.width - 2 * usedMetrics.padding
                        - 3 * usedMetrics.sentinelGaugeGap) / 4)
                    .environment(\.metrics, usedMetrics)
            )
            XCTAssertEqual(card.height, usedMetrics.sentinelGaugeHeight, accuracy: 0.5)
        }
    }

    /// the owner's review: "the usage summary must not disappear". Where the strip cannot hold it,
    /// header line 2 does — right-aligned beside the counts, which shorten and then truncate
    /// while the summary keeps every character. Rendered at the three appearances the review
    /// named, and asserted against the fixed header height it has to live inside.
    func testTheHeaderRowCarriesTheUsageSummaryWithoutCramping() {
        let detail = "10 claude · 1 codex · 24 sub-agents"
        let summary = "64% · 77%"
        let cases: [(name: String, appearance: Appearance)] = [
            ("360-100", Appearance(scale: 1.0, panelWidth: 360, listMaxHeight: 384, density: .standard)),
            ("360-125", Appearance(scale: 1.25, panelWidth: 360, listMaxHeight: 384, density: .standard)),
            ("460-100", Appearance(scale: 1.0, panelWidth: 460, listMaxHeight: 384, density: .standard)),
        ]

        for entry in cases {
            settings.appearance = entry.appearance
            let usedMetrics = settings.metrics
            let available = usedMetrics.headerDetailWidth(summary: summary)
            let full = usedMetrics.textWidth(detail, font: usedMetrics.rowSecondaryNSFont)
            let shown = full > available ? AppState.compactDetail(detail) : detail

            // Where the rule actually puts it at this appearance (SPEC §18.3): beside the strip
            // while it fits, on the header line when it does not — never nowhere. The Agents tab
            // carries the live sub-agent count in its own label (SPEC §12.3), and this fixture
            // has 24 of them, so the strip is under exactly the pressure the review described.
            let tabLabel: (PanelTab) -> String = { $0 == .agents ? "Agents · 24" : $0.label }
            let labels = PanelTab.visibleCases(showHistory: false).map(tabLabel)
            let onStrip = usedMetrics.tabStripFitsSummary(labels: labels, summary: summary)

            let header = render(
                VStack(spacing: 0) {
                    PanelRenderTests.headerRow(
                        headline: "12 agents", detail: shown,
                        summary: onStrip ? nil : summary,
                        needsYou: 2, metrics: usedMetrics
                    )
                    HStack(spacing: usedMetrics.controlGap) {
                        SegmentedTabs(
                            selection: .constant(.sessions),
                            tabs: PanelTab.visibleCases(showHistory: false), label: tabLabel
                        )
                        Spacer(minLength: usedMetrics.controlGap)
                        if onStrip {
                            Text(summary).font(usedMetrics.numeral)
                                .foregroundStyle(Theme.textTertiary)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .padding(.horizontal, usedMetrics.padding)
                    .frame(height: usedMetrics.tabsHeight)
                }
                .frame(width: usedMetrics.width)
                .background(Theme.windowBackground)
                .environment(\.metrics, usedMetrics)
                .environment(\.colorScheme, .dark),
                named: "sessions-top-\(entry.name)"
            )
            XCTAssertEqual(
                onStrip, entry.appearance.panelWidth == 460,
                "\(entry.name): with a sub-agent count on the strip, 360 pt puts the summary on " +
                    "the header row and 460 pt keeps it beside the tabs"
            )
            XCTAssertEqual(header.width, usedMetrics.width, accuracy: 0.5, entry.name)
            XCTAssertLessThanOrEqual(
                header.height, usedMetrics.headerHeight + usedMetrics.tabsHeight,
                "\(entry.name): the header's two rows and the strip must fit the heights the " +
                    "window reserves for them"
            )

            // The summary never gives up a character: whatever the counts do, it keeps its own
            // full width inside the line.
            XCTAssertGreaterThan(available, 0, entry.name)
            XCTAssertLessThanOrEqual(
                usedMetrics.textWidth(shown, font: usedMetrics.rowSecondaryNSFont),
                available + usedMetrics.measurementSlack,
                "\(entry.name): the counts shorten to fit beside the summary rather than " +
                    "pushing it off the line"
            )
        }
    }

    /// `PanelView.header`, reproduced: the same two rows, the same fonts, the same layout
    /// priority on the summary. (`state.usage.snapshot` is `private(set)`, so a live `PanelView`
    /// cannot be given a summary headlessly — `ReadmeScreenshotTests` reproduces the chrome the
    /// same way and for the same reason.)
    static func headerRow(
        headline: String, detail: String, summary: String?, needsYou: Int, metrics: Theme.Metrics
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.scaled(3)) {
            HStack(spacing: metrics.controlGap) {
                Circle().fill(Color(nsColor: .systemRed))
                    .frame(width: metrics.scaled(7), height: metrics.scaled(7))
                Text(headline).font(metrics.header).tracking(0.4)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: metrics.controlGap)
                if needsYou > 0 { NeedsYouPill(count: needsYou) }
                IconButton(symbol: "pin.slash", help: "Pin", action: {})
                IconButton(symbol: "gearshape", help: "Settings", action: {})
            }
            HStack(alignment: .firstTextBaseline, spacing: metrics.controlGap) {
                Text(detail).font(metrics.rowSecondary).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: metrics.controlGap)
                if let summary {
                    Text(summary).font(metrics.numeral).foregroundStyle(Theme.textTertiary)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, metrics.scaled(7) + metrics.controlGap)
        }
        .padding(.horizontal, metrics.padding)
        .frame(width: metrics.width, height: metrics.headerHeight)
        .background(Theme.windowBackground)
        .environment(\.metrics, metrics)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Neutral fixtures (SPEC §18: never this machine's real numbers or app names)

    static func sentinelSnapshot() -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        snapshot.sampledAt = Date().addingTimeInterval(-12)
        snapshot.cpuPercent = 88
        snapshot.cpuPerCore = [96, 91, 84, 80, 76, 72, 68, 61]
        snapshot.memoryTotal = 68_719_476_736
        snapshot.memoryUsed = 55_834_574_848
        snapshot.memoryPressure = .warning
        snapshot.swapOutPerSecond = 412
        snapshot.diskTotal = 994_662_584_320
        snapshot.diskFree = 51_539_607_552
        snapshot.thermal = .fair
        snapshot.loadAverage = [7.4, 6.1, 5.2]
        snapshot.processCount = 964
        snapshot.topApps = [
            SystemAppLoad(name: "acme-web", cpuPercent: 61.2, residentBytes: 2_147_483_648, processCount: 4),
            SystemAppLoad(name: "Editor", cpuPercent: 22.5, residentBytes: 1_073_741_824, processCount: 2),
            SystemAppLoad(name: "Browser", cpuPercent: 14.0, residentBytes: 8_589_934_592, processCount: 9),
            SystemAppLoad(name: "Indexer", cpuPercent: 7.5, residentBytes: 536_870_912, processCount: 1),
            SystemAppLoad(name: "Sync", cpuPercent: 3.2, residentBytes: 268_435_456, processCount: 1),
        ]
        return snapshot
    }

    /// Up to four warnings, one of every severity, covering all three actions and a Jump.
    static func sentinelSignals(count: Int) -> [SystemSignal] {
        let all: [SystemSignal] = [
            SystemSignal(
                id: "memory.critical", severity: .critical,
                title: "Memory pressure is critical",
                detail: "81 % used, and the machine has been swapping for 6 minutes",
                advice: ["Quit an app you are not using."],
                culprit: "Browser", since: Date().addingTimeInterval(-360),
                action: .openActivityMonitor, sessionID: nil
            ),
            SystemSignal(
                id: "cpu.saturated", severity: .warning,
                title: "CPU has been pinned",
                detail: "88 % for 2 minutes — acme-web is the biggest share",
                advice: ["acme-web is using 61 %."],
                culprit: "acme-web", since: Date().addingTimeInterval(-140),
                action: .openActivityMonitor, sessionID: "s-1"
            ),
            SystemSignal(
                id: "disk.low", severity: .warning,
                title: "The disk is nearly full",
                detail: "48 GB free of 926 GB",
                advice: ["Review disk usage in System Settings → General → Storage."],
                culprit: nil, since: Date().addingTimeInterval(-5_400),
                action: .openSystemSettings, sessionID: nil
            ),
            SystemSignal(
                id: "process.sprawl", severity: .info,
                title: "A lot of processes are running",
                detail: "964 processes",
                advice: ["Nothing to do — a restart clears it if it keeps climbing."],
                culprit: nil, since: Date().addingTimeInterval(-21_600),
                action: nil, sessionID: nil
            ),
        ]
        return Array(all.prefix(count))
    }
}
