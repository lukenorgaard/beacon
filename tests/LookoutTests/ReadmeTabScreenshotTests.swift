import AppKit
import SwiftUI
import XCTest
@testable import Lookout

extension ReadmeScreenshotTests {
    // MARK: - Sessions tab / live panel (SPEC §17.3)

    /// `live.png`: the panel exactly as `sessions-tab.png` shows it — README's hero image is the
    /// same tab, just captioned differently.
    func testLiveScreenshot() throws {
        try renderSessionsPanel(named: "live")
    }

    func testSessionsTabScreenshot() throws {
        try renderSessionsPanel(named: "sessions-tab")
    }

    private func renderSessionsPanel(named name: String) throws {
        let state = try fixtureState(settings: freshSettings(), tab: .sessions)
        XCTAssertEqual(state.visibleSessions.count, 6)
        let size = render(panel(state), named: name)
        XCTAssertEqual(size.width, state.settings.metrics.width, accuracy: 0.5)
        XCTAssertGreaterThan(size.height, 200)
    }

    func testAgentsTabScreenshot() throws {
        let state = try fixtureState(settings: freshSettings(), tab: .agents)
        XCTAssertEqual(state.subagents.count, 3)
        let size = render(panel(state), named: "agents-tab")
        XCTAssertEqual(size.width, state.settings.metrics.width, accuracy: 0.5)
    }

    func testUsageTabScreenshot() throws {
        let state = try fixtureState(settings: freshSettings(), tab: .usage)
        XCTAssertNotNil(state.usage.snapshot)
        XCTAssertNotNil(state.codexUsage)
        let size = render(panel(state), named: "usage-tab")
        XCTAssertEqual(size.width, state.settings.metrics.width, accuracy: 0.5)
    }

    func testSentinelTabScreenshot() throws {
        let state = try fixtureState(settings: freshSettings(), tab: .sentinel)
        let end = Date()
        for step in 0...120 {
            var snapshot = Self.sentinelSnapshot()
            snapshot.sampledAt = end.addingTimeInterval(Double(step - 120) * 5)
            snapshot.cpuPercent = 30 + Double(step) / 3 + sin(Double(step) / 7) * 8
            snapshot.memoryUsed = UInt64(Double(snapshot.memoryTotal) * (0.55 + Double(step) / 480))
            state.systemWatch.record(snapshot)
        }
        state.systemWatch.signals = Self.sentinelSignals()
        let size = render(panel(state), named: "sentinel-tab")
        XCTAssertEqual(size.width, state.settings.metrics.width, accuracy: 0.5)
        XCTAssertGreaterThan(size.height, 200)
    }

    /// A machine under some load, invented outright: no real app names, no real capacities.
    private static func sentinelSnapshot() -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        snapshot.sampledAt = Date().addingTimeInterval(-4)
        snapshot.cpuPercent = 74
        snapshot.cpuPerCore = [92, 88, 79, 71, 64, 58, 51, 44]
        snapshot.memoryTotal = 34_359_738_368
        snapshot.memoryUsed = 27_487_790_694
        snapshot.memoryPressure = .warning
        snapshot.swapOutPerSecond = 0
        snapshot.diskTotal = 500_107_862_016
        snapshot.diskFree = 38_654_705_664
        snapshot.thermal = .nominal
        snapshot.loadAverage = [4.2, 3.6, 3.1]
        snapshot.processCount = 741
        snapshot.topApps = [
            SystemAppLoad(name: "acme-web", cpuPercent: 48.0, residentBytes: 2_147_483_648, processCount: 3),
            SystemAppLoad(name: "Editor", cpuPercent: 19.5, residentBytes: 1_610_612_736, processCount: 2),
            SystemAppLoad(name: "Browser", cpuPercent: 11.0, residentBytes: 6_442_450_944, processCount: 8),
            SystemAppLoad(name: "Indexer", cpuPercent: 6.0, residentBytes: 805_306_368, processCount: 1),
            SystemAppLoad(name: "Sync", cpuPercent: 2.0, residentBytes: 268_435_456, processCount: 1),
        ]
        return snapshot
    }

    private static func sentinelSignals() -> [SystemSignal] {
        [SystemSignal(
            id: "cpu.runaway.Google Chrome", severity: .warning,
            title: "Chrome helper has sustained high CPU",
            detail: "A fictional Chrome helper used one core across recent samples. It may be busy or stuck.",
            advice: ["Check Chrome's More tools → Task manager before stopping it",
                     "One helper can serve multiple tabs; stopping it may lose unsaved work"],
            culprit: "Google Chrome", since: Date().addingTimeInterval(-180),
            action: .stopProcess(pid: 4242, name: "Google Chrome Helper (Renderer)")
        )]
    }

    // MARK: - Attention card (SPEC §11.4, §17.4)

    /// Mirrors `PanelRenderTests.testAttentionCardRenders` exactly — a fresh coordinator/model
    /// pair against the read-only checked-in fixtures, never `start()`, never a write.
    func testAttentionCardScreenshot() throws {
        let settings = freshSettings()
        // Deterministic, offline suggestion text — never a live Claude/Ollama call.
        settings.suggestionSource = .heuristic
        XCTAssertEqual(settings.answerPresets.count, 4, "SPEC §17.4's defaults render the row")

        let coordinator = AttentionCoordinator(settings: settings)
        let model = AttentionCardModel(
            settings: settings, coordinator: coordinator, suggester: Suggester(),
            home: LookoutHome(root: Fixtures.home)
        )

        var session = try JSONDecoder().decode(
            Session.self,
            from: Data(contentsOf: Fixtures.sessionsDirectory.appendingPathComponent(
                "claude-ab813983-4f21-4c0e-9a17-2f5b6c8d1e00.json"
            ))
        )
        session.stateSince = Date().addingTimeInterval(-180)
        coordinator.present(session)

        var request = try XCTUnwrap(AttentionRequest.decode(
            try Data(contentsOf: Fixtures.requestsDirectory.appendingPathComponent(
                "claude-ab813983-4f21-4c0e-9a17-2f5b6c8d1e00-3f9c1a7e.json"
            )),
            name: "claude-ab813983-4f21-4c0e-9a17-2f5b6c8d1e00-3f9c1a7e"
        ))
        // The checked-in fixture already waits until 2036, but a screenshot must never depend on
        // that staying true — make it fresh in memory whenever it is not.
        if request.isExpired() {
            request.waitsUntil = Date().addingTimeInterval(15 * 60)
        }
        XCTAssertFalse(request.isExpired())

        model.present(coordinator.current, request: request)
        XCTAssertTrue(model.canAnswerWithFile, "Allow/Deny must be on screen for this screenshot")
        XCTAssertNotNil(model.suggestion, "the heuristic suggestion must have rendered")

        let size = render(AttentionCardView(model: model), named: "attention-card")
        XCTAssertEqual(size.width, settings.metrics.cardWidth, accuracy: 0.5)
        XCTAssertEqual(size.width, 380, accuracy: 0.5)
        XCTAssertGreaterThan(size.height, 200)
    }

    // MARK: - Regeneration gating (CONTRIBUTING.md: LOOKOUT_REGENERATE_SCREENSHOTS=1)

    /// The environment is process-wide, not per-test: a test that flips this variable must put it
    /// back exactly as it found it when it's done, or a sibling test (or a real
    /// `LOOKOUT_REGENERATE_SCREENSHOTS=1 swift test` run driving the whole suite) inherits the
    /// wrong value. `setenv`/`unsetenv` are process state, and XCTest runs every test method in
    /// this class in the same process.
    private func withRegenerateVariable(_ value: String?, _ body: () -> Void) {
        let original = ProcessInfo.processInfo.environment["LOOKOUT_REGENERATE_SCREENSHOTS"]
        defer {
            if let original { setenv("LOOKOUT_REGENERATE_SCREENSHOTS", original, 1) }
            else { unsetenv("LOOKOUT_REGENERATE_SCREENSHOTS") }
        }
        if let value { setenv("LOOKOUT_REGENERATE_SCREENSHOTS", value, 1) }
        else { unsetenv("LOOKOUT_REGENERATE_SCREENSHOTS") }
        body()
    }

    /// A plain `swift test` must never touch `docs/screenshots/` — the render itself still runs
    /// and is still measured either way, it just lands in the scratch directory unless the
    /// variable is set to exactly "1".
    func testARenderWithoutTheVariableNeverTouchesDocsScreenshots() {
        let marker = ReadmeScreenshotTests.screenshotsDirectory
            .appendingPathComponent("readme-screenshot-tests-marker.png")
        try? FileManager.default.removeItem(at: marker)

        withRegenerateVariable(nil) {
            let size = render(Text("marker"), named: "readme-screenshot-tests-marker")
            XCTAssertGreaterThan(size.width, 0, "the render itself still runs and is measured")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "unset — docs/screenshots must stay exactly as it was"
        )

        withRegenerateVariable("0") {
            _ = render(Text("marker"), named: "readme-screenshot-tests-marker")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path), "\"0\" is not \"1\" — still off"
        )
    }

    /// The opt-in path: with the variable set to "1", the render does land in
    /// `docs/screenshots/` — this is the only way `docs/screenshots/*.png` may change.
    func testSettingTheVariableToOneWritesIntoDocsScreenshots() {
        let marker = ReadmeScreenshotTests.screenshotsDirectory
            .appendingPathComponent("readme-screenshot-tests-marker.png")
        defer { try? FileManager.default.removeItem(at: marker) }

        withRegenerateVariable("1") {
            _ = render(Text("marker"), named: "readme-screenshot-tests-marker")
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "LOOKOUT_REGENERATE_SCREENSHOTS=1 must write straight into docs/screenshots"
        )
    }
}
