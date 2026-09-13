import AppKit
import SwiftUI
import XCTest
@testable import Lookout

/// Render the actual app views with fictional fixtures. Never start AppState or read live sessions.
final class ReadmeScreenshotTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    /// `docs/screenshots/`, resolved from this file's own path — the same
    /// `deletingLastPathComponent()` walk `Fixtures.root` uses from `Fixtures.swift`.
    static var screenshotsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // tests/LookoutTests
            .deletingLastPathComponent() // tests
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("docs/screenshots")
    }

    /// Bug fix, 2026-09-06: regenerating the six tracked PNGs used to happen on every
    /// `swift test`, dirtying a contributor's or CI's tree on a plain run. Opt in with
    /// `LOOKOUT_REGENERATE_SCREENSHOTS=1` (documented in CONTRIBUTING.md) to actually update
    /// `docs/screenshots/`; unset, every render below still runs and is still measured, it just
    /// lands in `scratchDirectory` instead.
    private static var regenerateScreenshots: Bool {
        ProcessInfo.processInfo.environment["LOOKOUT_REGENERATE_SCREENSHOTS"] == "1"
    }

    /// Where a render lands when `regenerateScreenshots` is off — a throwaway directory under
    /// `NSTemporaryDirectory()`, never committed and never `docs/screenshots`.
    private static let scratchDirectory: URL = {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lookout-readme-screenshot-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    override class func tearDown() {
        try? FileManager.default.removeItem(at: scratchDirectory)
        super.tearDown()
    }

    // MARK: - Rendering (PanelRenderTests' `render(_:named:)`, writing to a fixed path instead)

    /// Lays a view out at its fitting size and writes a PNG of it — into `docs/screenshots/` only
    /// with `LOOKOUT_REGENERATE_SCREENSHOTS=1` set, otherwise into a scratch directory that is
    /// never tracked, so a plain `swift test` never touches the repository's checked-in images.
    @discardableResult
    func render<V: View>(_ view: V, named name: String) -> NSSize {
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        let directory = ReadmeScreenshotTests.regenerateScreenshots
            ? ReadmeScreenshotTests.screenshotsDirectory
            : ReadmeScreenshotTests.scratchDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
        else { return size }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        let url = directory.appendingPathComponent("\(name).png")
        try? representation.representation(using: .png, properties: [:])?.write(to: url)
        return size
    }

    // MARK: - A literal session list, decoded straight from the checked-in fixtures

    /// The one fixture with tokens on it (SPEC §17.6 has no checked-in example) — the Sessions
    /// tab's cost chip and the Usage tab's "Sessions today" section both need it.
    private static let tokensSessionID = "1d9e4b77-0c52-4a36-8f21-77a5c3b9d401"
    /// A second parent for the Agents tab, so it shows sub-agents from two different sessions
    /// rather than just the one fixture (`claude-3b6a2c19…`) that already has two. `9a0c5d34`
    /// (Beacon) carries no model and no worktree, so its Sessions-tab row has the least chip
    /// pressure on line 1 — the project name never has to give way to fit the new one.
    private static let secondAgentParentSessionID = "9a0c5d34-2e17-4f9b-bd66-4c8a1f0e7d55"

    /// Every checked-in session fixture, decoded — verbatim except the two lightly mutated in
    /// memory above — and put through `Session.sorted`, exactly what `SessionStore.refresh()`
    /// does to the same files before publishing them.
    func fixtureSessions() throws -> [Session] {
        let decoder = JSONDecoder()
        let names = try FileManager.default
            .contentsOfDirectory(atPath: Fixtures.sessionsDirectory.path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
        let sessions = try names.map { name -> Session in
            let source = Fixtures.sessionsDirectory.appendingPathComponent(name)
            let text = try String(contentsOf: source).replacingOccurrences(of: "Lookout", with: "Beacon")
            var session = try decoder.decode(Session.self, from: Data(text.utf8))
            session.startedAt = Date().addingTimeInterval(-900)
            session.stateSince = Date().addingTimeInterval(-180)
            session.updatedAt = Date()
            for index in session.subagents.indices {
                session.subagents[index].startedAt = Date().addingTimeInterval(-190)
            }
            if session.sessionID == ReadmeScreenshotTests.tokensSessionID {
                session.tokens = [
                    "claude-fable-5-1": TokenBucket(
                        inTokens: 640_000, outTokens: 128_000, cacheRead: 30_000, cacheWrite: 9_000
                    ),
                ]
                // SPEC §17.6: "Sessions today" only ever looks at today's activity.
                session.updatedAt = Date()
            }
            if session.sessionID == ReadmeScreenshotTests.secondAgentParentSessionID {
                session.subagents.append(Subagent(
                    id: "agent_h4ku", type: "general-purpose",
                    description: "Scan the deploy log for failed retries",
                    model: "haiku", startedAt: Date().addingTimeInterval(-190)
                ))
            }
            return session
        }
        return Session.sorted(sessions)
    }

    func freshSettings() -> Lookout.Settings {
        let suiteName = "io.github.lukenorgaard.beacon.readme.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return Lookout.Settings(defaults: defaults)
    }

    func fixtureState(settings: Lookout.Settings, tab: PanelTab) throws -> AppState {
        settings.suggestionSource = .heuristic
        let home = LookoutHome(root: Fixtures.home)
        let usage = UsageClient(snapshot: try UsageSnapshot.parse(Data(contentsOf: Fixtures.usageJSON)))
        let state = AppState(settings: settings, store: SessionStore(home: Fixtures.home),
                             usage: usage, home: home, names: SessionNames(home: home, loadsNow: false))
        state.allSessions = try fixtureSessions()
        state.visibleSessions = SessionFilter.apply(state.allSessions, states: settings.filterStates,
            hosts: settings.filterHosts, order: settings.sessionOrder, pinned: settings.pinnedSessions)
        state.idleFilteredCount = state.allSessions.count
        state.subagents = Session.liveSubagents(state.allSessions)
        state.codexUsage = CodexUsageSnapshot.parse(try Data(contentsOf: Fixtures.codexUsageJSON))
        state.tab = tab
        return state
    }

    func panel(_ state: AppState) -> some View {
        PanelView(state: state, settings: state.settings, onTogglePin: {}, onOpenSettings: {})
    }
}
