import AppKit
import XCTest
@testable import Lookout

/// SPEC §18.3–§18.5: the tab's own logic, without laying anything out — the ordering, the
/// strings, the buttons' payloads, the settings and the menu-bar dot's priority. The render side
/// lives in `PanelRenderTests`.
final class SentinelViewTests: XCTestCase {
    private var suiteName = ""
    var defaults: UserDefaults!
    var settings: Lookout.Settings!
    var state: AppState!
    private var temporary: URL?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        suiteName = "io.github.lukenorgaard.beacon.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = Lookout.Settings(defaults: defaults)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-sentinel-\(UUID().uuidString)")
        temporary = root
        state = AppState(
            settings: settings,
            store: SessionStore(home: root),
            usage: UsageClient(),
            home: LookoutHome(root: root)
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        temporary = nil
        state = nil
        settings = nil
        defaults = nil
        super.tearDown()
    }

    // MARK: - Fixtures (neutral: no real machine, no real paths)

    static func signal(
        _ id: String, _ severity: SignalSeverity, minutesAgo: Double,
        action: SystemSignalAction? = nil, sessionID: String? = nil,
        title: String? = nil, advice: [String] = ["Quit an app you are not using."]
    ) -> SystemSignal {
        SystemSignal(
            id: id,
            severity: severity,
            title: title ?? id,
            detail: "\(id) detail",
            advice: advice,
            culprit: nil,
            since: Date().addingTimeInterval(-minutesAgo * 60),
            action: action,
            sessionID: sessionID
        )
    }

    static func snapshot(now: Date = Date()) -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        snapshot.sampledAt = now
        snapshot.cpuPercent = 42
        snapshot.cpuPerCore = [40, 44, 41, 43]
        snapshot.memoryTotal = 68_719_476_736
        snapshot.memoryUsed = 46_170_898_432
        snapshot.memoryPressure = .warning
        snapshot.swapOutPerSecond = 0
        snapshot.diskTotal = 994_662_584_320
        snapshot.diskFree = 94_489_280_512
        snapshot.loadAverage = [3.1, 2.8, 2.4]
        snapshot.processCount = 812
        snapshot.topApps = [
            SystemAppLoad(name: "acme-web", cpuPercent: 61.2, residentBytes: 2_147_483_648, processCount: 4),
            SystemAppLoad(name: "Editor", cpuPercent: 22.5, residentBytes: 1_073_741_824, processCount: 2),
            SystemAppLoad(name: "Browser", cpuPercent: 14.0, residentBytes: 8_589_934_592, processCount: 9),
            SystemAppLoad(name: "Indexer", cpuPercent: 7.5, residentBytes: 536_870_912, processCount: 1),
            SystemAppLoad(name: "Sync", cpuPercent: 3.25, residentBytes: 268_435_456, processCount: 1),
            SystemAppLoad(name: "Overflow", cpuPercent: 1.0, residentBytes: 134_217_728, processCount: 1),
        ]
        return snapshot
    }

    // MARK: - SPEC §18.3: ordering

    func testSignalsSortBySeverityThenByHowLongTheyHaveBeenGoingOn() {
        let sorted = Sentinel.sorted([
            SentinelViewTests.signal("info.new", .info, minutesAgo: 1),
            SentinelViewTests.signal("warning.old", .warning, minutesAgo: 40),
            SentinelViewTests.signal("critical.new", .critical, minutesAgo: 2),
            SentinelViewTests.signal("warning.new", .warning, minutesAgo: 5),
            SentinelViewTests.signal("critical.old", .critical, minutesAgo: 90),
        ])
        XCTAssertEqual(
            sorted.map(\.id),
            ["critical.old", "critical.new", "warning.old", "warning.new", "info.new"],
            "worst first, and inside one severity the one that has lasted longest"
        )
    }

    func testTheSortIsStableForTwoSignalsThatStartedAtTheSameInstant() {
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        var first = SentinelViewTests.signal("b.rule", .warning, minutesAgo: 0)
        var second = SentinelViewTests.signal("a.rule", .warning, minutesAgo: 0)
        first.since = since
        second.since = since
        XCTAssertEqual(Sentinel.sorted([first, second]).map(\.id), ["a.rule", "b.rule"])
    }

    // MARK: - SPEC §18.3: the strings

    func testTheDurationReadsLikeEveryOtherElapsedNumberInThePanel() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(
            Sentinel.durationText(since: now.addingTimeInterval(-720), now: now), "for 12m"
        )
        XCTAssertEqual(
            Sentinel.durationText(since: now.addingTimeInterval(-45), now: now), "for 45s"
        )
        XCTAssertEqual(
            Sentinel.durationText(since: now.addingTimeInterval(-4_320), now: now), "for 1h 12m"
        )
    }

    func testTheEmptyStateSaysNothingToReportAndWhenItLastLooked() {
        XCTAssertEqual(Sentinel.emptyTitle, "Nothing to report")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var snapshot = SentinelViewTests.snapshot()
        snapshot.sampledAt = now.addingTimeInterval(-12)
        XCTAssertEqual(Sentinel.sampledText(snapshot, now: now), "sampled 12s ago")
        XCTAssertEqual(
            Sentinel.sampledText(nil, now: now), "not sampled yet",
            "before the first sample the tab must not claim a time it does not have"
        )
    }

    func testTheGaugesReadTheSnapshotAndSayZeroSwapRatherThanUnknown() {
        let gauges = Sentinel.gauges(SentinelViewTests.snapshot())
        XCTAssertEqual(gauges.map(\.label), ["CPU", "MEMORY", "SWAP OUT", "DISK"])
        XCTAssertEqual(gauges[0].value, "42%")
        XCTAssertEqual(gauges[1].value, "67%")
        XCTAssertEqual(gauges[1].detail, "Warning", "the pressure label, not a second percentage")
        XCTAssertEqual(gauges[2].value, "0", "SPEC §18.3: idle swap is 0, never an em dash")
        XCTAssertEqual(gauges[2].detail, "pages/s")
        XCTAssertEqual(gauges[3].value, "88 GB")
        XCTAssertEqual(gauges[3].detail, "9% free")
    }

    func testWithoutASnapshotTheGaugesShowEmDashesRatherThanZeros() {
        let gauges = Sentinel.gauges(nil)
        XCTAssertEqual(gauges.count, 4)
        XCTAssertTrue(gauges.allSatisfy { $0.value == "—" }, "zeros would read as a healthy machine")
    }

    func testTheThermalChipOnlyExistsWhenTheMachineIsNotNominal() {
        var snapshot = SentinelViewTests.snapshot()
        XCTAssertNil(Sentinel.thermalChip(snapshot))
        snapshot.thermal = .serious
        XCTAssertEqual(Sentinel.thermalChip(snapshot), "Thermal · Serious")
    }

    func testTopCPUShowsAtMostFiveAppsAndSaysTheMemoryIsAnUpperBound() {
        let apps = Sentinel.topApps(SentinelViewTests.snapshot())
        XCTAssertEqual(apps.count, 5, "SPEC §18.3: up to five")
        XCTAssertEqual(apps.first?.name, "acme-web")
        XCTAssertEqual(Sentinel.percentText(61.2), "61%")
        XCTAssertEqual(Sentinel.memoryText(2_147_483_648), "2.0 GB")
        XCTAssertEqual(Sentinel.memoryText(8_589_934_592), "8.0 GB")
        XCTAssertEqual(Sentinel.memoryText(268_435_456), "256 MB")
        XCTAssertEqual(Sentinel.memoryText(53_687_091_200), "50 GB")
        XCTAssertEqual(Sentinel.topAppsTooltip, "Sum of the app's processes; an upper bound")
    }

    func testARowsButtonCountIsWhatTheMetricsSizeItFrom() {
        let metricsForCounts = Theme.Metrics.standard
        let signals = [
            SentinelViewTests.signal("plain", .info, minutesAgo: 1),
            SentinelViewTests.signal("action", .warning, minutesAgo: 1, action: .openSystemSettings),
            SentinelViewTests.signal("jump", .warning, minutesAgo: 1, sessionID: "s1"),
            SentinelViewTests.signal(
                "both", .critical, minutesAgo: 1,
                action: .stopProcess(pid: 4242, name: "runaway"), sessionID: "s1"
            ),
        ]
        XCTAssertEqual(
            Sentinel.layouts(signals, metrics: metricsForCounts).map(\.buttons), [1, 2, 2, 3]
        )
        XCTAssertEqual(Sentinel.buttonLabels(signals[3]), ["Details", "Stop…", "Jump"])

        // Two stacked buttons never get less room than they need, at any appearance.
        for appearance in [
            Appearance.standard,
            Appearance(scale: 0.85, panelWidth: 320, listMaxHeight: 320, density: .compact),
            Appearance(scale: 1.25, panelWidth: 460, listMaxHeight: 480, density: .comfortable),
        ] {
            let scaled = Theme.Metrics(appearance)
            let two = SentinelRowLayout(
                titleLines: 1, adviceLines: 1, durationBelowTitle: false, buttons: 2
            )
            XCTAssertGreaterThanOrEqual(
                scaled.sentinelWarningRowHeight(two),
                2 * scaled.buttonHeight + scaled.controlGap + 2 * scaled.sentinelWarningPadding,
                "two buttons at \(appearance.scale)× must stack with 8 pt between them"
            )
            XCTAssertGreaterThan(
                scaled.sentinelWarningRowHeight(two),
                scaled.sentinelWarningRowHeight(
                    SentinelRowLayout(
                        titleLines: 1, adviceLines: 1, durationBelowTitle: false, buttons: 0
                    )
                )
            )
        }
    }

    /// the owner's review: `Memory pressure  for 6m / is critical` — the title broke mid-phrase
    /// around a duration that had taken the end of its line. The duration now only keeps that
    /// place while both fit on one line together.
    func testTheDurationSitsBesideATitleThatFitsAndDropsBelowOneThatDoesNot() {
        let metrics = Theme.Metrics.standard

        let short = SentinelViewTests.signal(
            "cpu.saturated", .warning, minutesAgo: 2, action: .openActivityMonitor,
            title: "CPU has been pinned", advice: ["acme-web is using 61 %."]
        )
        let shortLayout = Sentinel.layout(for: short, metrics: metrics, now: Date())
        XCTAssertFalse(shortLayout.durationBelowTitle, "it fits beside the title, so it stays")
        XCTAssertEqual(shortLayout.titleLines, 1)

        let long = SentinelViewTests.signal(
            "memory.critical", .critical, minutesAgo: 6, action: .openActivityMonitor,
            title: "Memory pressure is critical", advice: ["Quit an app you are not using."]
        )
        let longLayout = Sentinel.layout(for: long, metrics: metrics, now: Date())
        XCTAssertTrue(
            longLayout.durationBelowTitle,
            "title 165 pt + duration in a 186 pt column: the duration moves under it"
        )
        XCTAssertEqual(
            longLayout.titleLines, 1,
            "given the whole column the title still only needs one line — it never wraps just " +
                "because the duration was there"
        )
        XCTAssertGreaterThanOrEqual(
            metrics.sentinelWarningRowHeight(longLayout),
            metrics.sentinelWarningRowHeight(shortLayout),
            "the extra line is part of the height the window reserves"
        )
    }

    func testATitleTooLongForOneLineWrapsAndTakesTheWholeColumn() {
        let metrics = Theme.Metrics.standard
        let signal = SentinelViewTests.signal(
            "helper.networkextension", .warning, minutesAgo: 9, action: .openActivityMonitor,
            title: "A network extension has been burning CPU for a while now",
            advice: ["It is usually a VPN or a security agent."]
        )
        let layout = Sentinel.layout(for: signal, metrics: metrics, now: Date())
        XCTAssertEqual(layout.titleLines, 2)
        XCTAssertTrue(layout.durationBelowTitle)
    }

    func testARowWithoutAButtonGetsAWiderColumnThanOneWithOne() {
        let metrics = Theme.Metrics.standard
        XCTAssertGreaterThan(
            metrics.sentinelWarningTextWidth(buttonLabels: []),
            metrics.sentinelWarningTextWidth(buttonLabels: ["Activity Monitor"])
        )
        XCTAssertGreaterThan(
            metrics.sentinelWarningTextWidth(buttonLabels: ["Stop…"]),
            metrics.sentinelWarningTextWidth(buttonLabels: ["System Settings"]),
            "the widest button in the row is what the text column gives way to"
        )
    }

    func testTheListIsCappedAtTheListHeightAndSaysSoWhenItOverflows() {
        let metrics = Theme.Metrics.standard
        let many = Array(repeating: SentinelRowLayout(), count: 12)
        XCTAssertTrue(metrics.sentinelListOverflows(layouts: many, apps: 5))
        XCTAssertEqual(
            metrics.sentinelListHeight(layouts: many, apps: 5), metrics.listMaxHeight,
            accuracy: 0.5
        )
        XCTAssertFalse(metrics.sentinelListOverflows(layouts: [], apps: 0))
    }
}
