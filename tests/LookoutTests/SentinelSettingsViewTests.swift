import AppKit
import XCTest
@testable import Lookout

extension SentinelViewTests {
    // MARK: - SPEC §18.5: Settings

    func testTheSentinelDefaultsAreTheOnesTheSpecNames() {
        let fresh = Lookout.Settings(defaults: defaults)
        XCTAssertTrue(fresh.sentinelEnabled)
        XCTAssertEqual(fresh.sentinelSensitivity, .balanced)
        XCTAssertTrue(fresh.sentinelNotifications)
        XCTAssertTrue(fresh.sentinelMenuBarDot)
    }

    func testTheSentinelSettingsRoundTripThroughDefaults() {
        settings.sentinelEnabled = false
        settings.sentinelSensitivity = .early
        settings.sentinelNotifications = false
        settings.sentinelMenuBarDot = false

        let reopened = Lookout.Settings(defaults: defaults)
        XCTAssertFalse(reopened.sentinelEnabled)
        XCTAssertEqual(reopened.sentinelSensitivity, .early)
        XCTAssertFalse(reopened.sentinelNotifications)
        XCTAssertFalse(reopened.sentinelMenuBarDot)

        // Persisted as the raw value the contract defines, so the engine reads back what it wrote.
        XCTAssertEqual(defaults.string(forKey: "sentinelSensitivity"), "early")
    }

    func testTheSentinelSettingsPageIsTheFifthTab() {
        XCTAssertEqual(
            SettingsTab.allCases.map(\.rawValue),
            ["general", "appearance", "agents", "cards", "sentinel"]
        )
        XCTAssertEqual(SettingsTab.sentinel.label, "Sentinel")
    }

    // MARK: - The tab strip

    func testVisibleCasesKeepsSentinelRightOfUsageAndDropsItWhenTheSwitchIsOff() {
        XCTAssertEqual(
            PanelTab.allCases.map(\.rawValue),
            ["sessions", "agents", "history", "usage", "sentinel"]
        )
        XCTAssertEqual(PanelTab.sentinel.label, "Sentinel")
        XCTAssertEqual(
            PanelTab.visibleCases(showHistory: false, showSentinel: true),
            [.sessions, .agents, .usage, .sentinel]
        )
        XCTAssertEqual(
            PanelTab.visibleCases(showHistory: true, showSentinel: true),
            [.sessions, .agents, .history, .usage, .sentinel]
        )
        XCTAssertEqual(
            PanelTab.visibleCases(showHistory: false, showSentinel: false),
            [.sessions, .agents, .usage]
        )
        XCTAssertEqual(
            PanelTab.visibleCases(showHistory: true, showSentinel: false),
            [.sessions, .agents, .history, .usage]
        )
    }

    func testTheSentinelTabFallsBackToSessionsWhenTheSwitchGoesOff() {
        state.tab = .sentinel
        settings.sentinelEnabled = false
        state.resolveTabIfNeeded()
        XCTAssertEqual(state.tab, .sessions)

        state.tab = .sentinel
        settings.sentinelEnabled = true
        state.resolveTabIfNeeded()
        XCTAssertEqual(state.tab, .sentinel)
    }

    /// the owner's review: the usage summary must never disappear. Step one is that the segments
    /// tighten from the fourth tab on, which is what makes "64% · 77%" fit beside a four-tab
    /// strip at 360 pt in the first place.
    func testTheSegmentsTightenFromTheFourthTabSoTheSummaryStaysOnTheStrip() {
        let metrics = Theme.Metrics.standard
        let four = PanelTab.visibleCases(showHistory: false).map(\.label)
        XCTAssertEqual(four, ["Sessions", "Agents", "Usage", "Sentinel"])
        XCTAssertEqual(metrics.width, 360)

        XCTAssertLessThan(
            metrics.tabSegmentPadding(tabCount: 4), metrics.tabSegmentPadding(tabCount: 3),
            "the fourth tab is what tightens the segments"
        )
        XCTAssertGreaterThanOrEqual(
            metrics.tabSegmentPadding(tabCount: 4), 4,
            "there is a floor: below it a label runs into its own segment fill"
        )
        XCTAssertTrue(
            metrics.tabStripFitsSummary(labels: four, summary: "64% · 77%"),
            "with the tighter segments the summary keeps its place beside the strip at 360 pt"
        )
    }

    /// Step two: when even the tighter segments cannot make room — a sub-agent count on the
    /// Agents label, or the Large text size — the summary moves to the header. It is never
    /// dropped, and never in both places at once.
    func testWhenTheStripCannotHoldTheSummaryTheHeaderRowCan() {
        let metrics = Theme.Metrics.standard
        let withCount = ["Sessions", "Agents · 27", "Usage", "Sentinel"]
        XCTAssertFalse(
            metrics.tabStripFitsSummary(labels: withCount, summary: "64% · 77%"),
            "a live sub-agent count is 23 pt the strip does not have"
        )

        let large = Theme.Metrics(
            Appearance(scale: 1.25, panelWidth: 360, listMaxHeight: 360, density: .standard)
        )
        XCTAssertFalse(
            large.tabStripFitsSummary(
                labels: PanelTab.visibleCases(showHistory: false).map(\.label),
                summary: "64% · 77%"
            ),
            "at the Large text size 360 pt cannot hold both, at any segment padding"
        )

        // And in both cases the header's second line has room for the counts beside it.
        for used in [metrics, large] {
            XCTAssertGreaterThan(used.headerDetailWidth(summary: "64% · 77%"), 0)
            XCTAssertLessThan(
                used.headerDetailWidth(summary: "64% · 77%"),
                used.headerDetailWidth(summary: nil),
                "the summary takes its width from the counts, not from the panel's edge"
            )
        }
    }

    func testTheCountsShortenBeforeTheSummaryGivesUpAnything() {
        let detail = "10 claude · 1 codex · 24 sub-agents"
        XCTAssertEqual(
            AppState.compactDetail(detail), "10 claude · 1 codex · 24 subs"
        )
        XCTAssertEqual(
            AppState.compactDetail("2 claude · 1 sub-agent"), "2 claude · 1 sub"
        )
        XCTAssertEqual(
            AppState.compactDetail("8 claude · 2 codex"), "8 claude · 2 codex",
            "a line with nothing to shorten is left exactly as it was"
        )

        // At the Large text size the full wording is 1 pt too wide beside the summary, and the
        // short one fits — which is the whole reason it exists.
        let large = Theme.Metrics(
            Appearance(scale: 1.25, panelWidth: 360, listMaxHeight: 360, density: .standard)
        )
        let available = large.headerDetailWidth(summary: "64% · 77%")
        XCTAssertGreaterThan(large.textWidth(detail, font: large.rowSecondaryNSFont), available)
        XCTAssertLessThanOrEqual(
            large.textWidth(AppState.compactDetail(detail), font: large.rowSecondaryNSFont),
            available
        )
    }

    func testAWiderPanelKeepsTheSummaryBesideTheStrip() {
        let wide = Theme.Metrics(
            Appearance(scale: 1.0, panelWidth: 460, listMaxHeight: 480, density: .standard)
        )
        XCTAssertTrue(
            wide.tabStripFitsSummary(
                labels: ["Sessions", "Agents · 27", "Usage", "Sentinel"], summary: "64% · 77%"
            ),
            "the rule is about room, not about the tab count"
        )
    }

    func testTheStripItselfNeverNeedsMoreThanThePanelIsWide() {
        for appearance in [
            Appearance.standard,
            Appearance(scale: 1.25, panelWidth: 460, listMaxHeight: 480, density: .comfortable),
            Appearance(scale: 0.85, panelWidth: 320, listMaxHeight: 320, density: .compact),
        ] {
            let metrics = Theme.Metrics(appearance)
            let labels = PanelTab.visibleCases(showHistory: false).map(\.label)
            XCTAssertLessThanOrEqual(
                metrics.tabStripWidth(labels: labels) + 2 * metrics.padding, metrics.width,
                "the four labels must fit at \(appearance.scale)×/\(appearance.panelWidth) pt — " +
                    "a tab label is never truncated (SPEC §18.3)"
            )
        }
    }

    // MARK: - SPEC §18.5: the menu-bar dot

    private func session(_ id: String, _ value: SessionState) -> Session {
        var session = Session()
        session.sessionID = id
        session.state = value
        session.project = id
        session.stateSince = Date().addingTimeInterval(-600)
        return session
    }

    func testACriticalSignalColoursTheDotButNeverAheadOfASessionThatNeedsYou() {
        state.systemWatch.signals = [
            SentinelViewTests.signal("memory.critical", .critical, minutesAgo: 4)
        ]
        state.apply([session("idle", .idle)])
        XCTAssertEqual(
            state.statusColor, Theme.signalCriticalNSColor,
            "critical beats idle (SPEC §18.5)"
        )

        state.apply([session("waiting", .needsYou)])
        XCTAssertEqual(
            state.statusColor, .systemRed,
            "needs-you keeps priority — the machine's trouble waits its turn"
        )
    }

    func testACriticalSignalAlsoOutranksAFinishedOrAWorkingSession() {
        state.systemWatch.signals = [
            SentinelViewTests.signal("disk.low", .critical, minutesAgo: 30)
        ]
        state.apply([session("done", .done), session("busy", .working)])
        XCTAssertEqual(state.statusColor, Theme.signalCriticalNSColor)
    }

    func testAWarningNeverTouchesTheDot() {
        state.systemWatch.signals = [
            SentinelViewTests.signal("cpu.saturated", .warning, minutesAgo: 3)
        ]
        state.apply([session("idle", .idle)])
        XCTAssertEqual(state.statusColor, .systemGray, "only critical may take the dot")
    }

    func testTurningTheDotSettingOffLeavesTheStatusExactlyAsItWas() {
        state.systemWatch.signals = [
            SentinelViewTests.signal("memory.critical", .critical, minutesAgo: 4)
        ]
        state.apply([session("idle", .idle)])

        settings.sentinelMenuBarDot = false
        XCTAssertEqual(state.statusColor, .systemGray)
        XCTAssertNil(state.sentinelCriticalSignal)

        settings.sentinelMenuBarDot = true
        settings.sentinelEnabled = false
        XCTAssertEqual(
            state.statusColor, .systemGray,
            "Sentinel off means the watcher has nothing to say about the dot at all"
        )
    }

    func testTheTooltipNamesTheSignalSoTheColourIsNotARiddle() {
        state.systemWatch.signals = [
            SentinelViewTests.signal(
                "memory.critical", .critical, minutesAgo: 4, title: "Memory is critical"
            )
        ]
        state.apply([session("idle", .idle)])
        XCTAssertTrue(
            state.statusTooltip.contains("Memory is critical"),
            "got \(state.statusTooltip)"
        )
    }

    func testTheDotFollowsTheLongestRunningCriticalSignal() {
        state.systemWatch.signals = [
            SentinelViewTests.signal("newer", .critical, minutesAgo: 2, title: "Newer"),
            SentinelViewTests.signal("older", .critical, minutesAgo: 40, title: "Older"),
        ]
        XCTAssertEqual(state.sentinelCriticalSignal?.title, "Older")
    }

    // MARK: - SPEC §18.6: visibility

    func testTheTabIsOnlyVisibleWhenItIsSelectedAndThePanelIsOnScreen() {
        state.tab = .sentinel
        state.updateSystemWatchVisibility()
        XCTAssertFalse(
            state.systemWatch.isVisible,
            "selected in a panel that is collapsed to the menu bar is not visible"
        )

        state.setPanelOnScreen(true)
        XCTAssertTrue(state.systemWatch.isVisible)

        state.tab = .usage
        state.updateSystemWatchVisibility()
        XCTAssertFalse(state.systemWatch.isVisible)

        state.tab = .sentinel
        state.updateSystemWatchVisibility()
        XCTAssertTrue(state.systemWatch.isVisible)

        state.setPanelOnScreen(false)
        XCTAssertFalse(state.systemWatch.isVisible)
    }

    func testTurningSentinelOffClearsWhatTheTabAndTheDotWouldOtherwiseKeepShowing() {
        state.tab = .sentinel
        state.setPanelOnScreen(true)
        state.systemWatch.signals = [
            SentinelViewTests.signal("memory.critical", .critical, minutesAgo: 4)
        ]
        state.systemWatch.snapshot = SentinelViewTests.snapshot()
        state.systemWatch.lastError = "sysctl failed"

        settings.sentinelEnabled = false
        state.applySentinel(enabled: false)

        XCTAssertTrue(state.systemWatch.signals.isEmpty)
        XCTAssertNil(state.systemWatch.snapshot)
        XCTAssertNil(state.systemWatch.lastError)
        XCTAssertFalse(state.systemWatch.isVisible)
        XCTAssertEqual(state.tab, .sessions, "the tab is gone, so it cannot stay selected")
    }
}
