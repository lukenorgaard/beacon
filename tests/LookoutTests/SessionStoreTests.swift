import XCTest
@testable import Lookout

final class SessionStoreTests: XCTestCase {
    private var temporary: URL?

    override func tearDown() {
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        temporary = nil
        unsetenv("LOOKOUT_PRUNE")
        super.tearDown()
    }

    /// Spins the run loop until the store has published — it publishes on the main queue.
    private func waitUntil(
        _ description: String, timeout: TimeInterval = 5, condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(description)")
    }

    private func makeHome(_ files: [String: String]) throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-home-\(UUID().uuidString)")
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        for (name, contents) in files {
            try Data(contents.utf8).write(to: sessions.appendingPathComponent(name))
        }
        temporary = home
        return home
    }

    func testReadsTheCheckedInFixturesInDisplayOrder() {
        let store = SessionStore(home: Fixtures.root.appendingPathComponent("tests/fixtures"))
        store.apply(discovery: false, agentCommands: [])
        store.start()

        waitUntil("the six fixtures to load") { store.sessions.count == 6 }
        XCTAssertEqual(
            store.sessions.map(\.project),
            [
                "daily-notes", "billing-api", "Lookout",
                "docs-site", "Voyager", "Beacon",
            ]
        )
        XCTAssertTrue(store.isOverridden)

        // Nothing in a fixtures folder may ever be deleted by a test run.
        let remaining = try? FileManager.default.contentsOfDirectory(
            atPath: Fixtures.sessionsDirectory.path
        )
        XCTAssertEqual(remaining?.filter { $0.hasSuffix(".json") }.count, 6)
    }

    func testLivenessAndStalenessPruneFilesWhenPruningIsOn() throws {
        setenv("LOOKOUT_PRUNE", "1", 1)
        let home = try makeHome([
            "claude-alive.json": #"{"session_id":"alive","state":"working","pid":1,"updated_at":"\#(ISO8601.string(Date()))"}"#,
            "claude-dead.json": #"{"session_id":"dead","state":"working","pid":2147483ignore}"#
                .replacingOccurrences(of: "2147483ignore", with: "2147483647"),
            "claude-stale.json": #"{"session_id":"stale","state":"done","pid":1,"updated_at":"2020-01-01T00:00:00Z"}"#,
        ])

        let store = SessionStore(home: home)
        store.apply(discovery: false, agentCommands: [])
        store.start()

        waitUntil("only the live session to survive") { store.sessions.count == 1 }
        XCTAssertEqual(store.sessions.first?.sessionID, "alive")

        let left = try FileManager.default.contentsOfDirectory(
            atPath: home.appendingPathComponent("sessions").path
        )
        XCTAssertEqual(left.sorted(), ["claude-alive.json"])
    }

    func testUnreadableFilesAreSkippedWithoutTakingTheRestDown() throws {
        let home = try makeHome([
            "claude-good.json": #"{"session_id":"good","state":"working","pid":1}"#,
            "claude-broken.json": "{ this is not json",
            "notes.txt": "ignored",
        ])

        let store = SessionStore(home: home)
        store.apply(discovery: false, agentCommands: [])
        store.start()

        waitUntil("the readable file to load") { store.sessions.count == 1 }
        XCTAssertEqual(store.sessions.first?.sessionID, "good")
    }

    func testANewFileIsPickedUpByTheDirectoryWatcher() throws {
        let home = try makeHome([
            "claude-first.json": #"{"session_id":"first","state":"working","pid":1}"#
        ])
        let store = SessionStore(home: home)
        store.apply(discovery: false, agentCommands: [])
        store.start()
        waitUntil("the first session") { store.sessions.count == 1 }

        try Data(#"{"session_id":"second","state":"needs_you","pid":1}"#.utf8)
            .write(to: home.appendingPathComponent("sessions/claude-second.json"))

        waitUntil("the watcher to notice the new file", timeout: 8) { store.sessions.count == 2 }
        XCTAssertEqual(store.sessions.first?.sessionID, "second", "needs_you sorts first")
    }

    func testMissingDirectoryIsNotAnError() {
        let store = SessionStore(
            home: URL(fileURLWithPath: "/tmp/lookout-does-not-exist-\(UUID().uuidString)")
        )
        store.apply(discovery: false, agentCommands: [])
        store.start()
        waitUntil("a quiet empty list", timeout: 1) { store.sessions.isEmpty }
    }

    func testLivenessCheck() {
        XCTAssertTrue(SessionStore.isAlive(1), "launchd is always alive")
        XCTAssertTrue(SessionStore.isAlive(ProcessInfo.processInfo.processIdentifier))
        XCTAssertFalse(SessionStore.isAlive(2_147_483_647))
    }
}

/// `ScanCadence.interval` — a pure decision, tested without a real timer (task: adaptive cadence).
final class ScanCadenceTests: XCTestCase {
    func testActiveWhileCandidatesAreStillChurning() {
        XCTAssertEqual(
            ScanCadence.interval(candidatesChanged: true, secondsSinceFileChange: nil),
            ScanCadence.active
        )
        // Candidate churn wins even long after any file activity.
        XCTAssertEqual(
            ScanCadence.interval(candidatesChanged: true, secondsSinceFileChange: 999),
            ScanCadence.active
        )
    }

    func testActiveWithinTheQuietWindowOfAFileChange() {
        XCTAssertEqual(
            ScanCadence.interval(candidatesChanged: false, secondsSinceFileChange: 0),
            ScanCadence.active
        )
        XCTAssertEqual(
            ScanCadence.interval(candidatesChanged: false, secondsSinceFileChange: 29.9),
            ScanCadence.active
        )
    }

    func testTheQuietWindowBoundaryIsInclusive() {
        XCTAssertEqual(
            ScanCadence.interval(
                candidatesChanged: false, secondsSinceFileChange: ScanCadence.quietWindow
            ),
            ScanCadence.active
        )
    }

    func testBacksOffOnceNothingHasMovedForAWhile() {
        XCTAssertEqual(
            ScanCadence.interval(candidatesChanged: false, secondsSinceFileChange: nil),
            ScanCadence.idle
        )
        XCTAssertEqual(
            ScanCadence.interval(
                candidatesChanged: false, secondsSinceFileChange: ScanCadence.quietWindow + 0.1
            ),
            ScanCadence.idle
        )
    }
}
