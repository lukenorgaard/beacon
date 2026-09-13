import XCTest
@testable import Lookout

/// SPEC §9.1: a hook-reported file always beats a discovered row for the same session. Now that
/// a discovered row carries the real `session_id` out of the process environment, "the same
/// session" means the same id *or* the same pid — a session reported from the desktop app has no
/// tty and can easily be the same session under a different pid view of the world.
final class SessionMergeTests: XCTestCase {
    private let decoder = JSONDecoder()

    private func file(_ json: String) throws -> Session {
        try decoder.decode(Session.self, from: Data(json.utf8))
    }

    private func discovered(
        id: String, pid: Int32, agent: String = "claude", host: SessionHost = .claudeDesktop
    ) -> Session {
        var session = Session()
        session.sessionID = id
        session.agent = SessionAgent(raw: agent)
        session.state = .running
        session.reason = "discovered"
        session.pid = pid
        session.host = host
        session.isDiscovered = true
        return session
    }

    func testTheFileWinsOnASharedSessionID() throws {
        let reported = try file(#"{"session_id":"abc-123","state":"working","pid":4242}"#)
        // Same session, seen by the scanner under a different pid — matched by id.
        let scanned = discovered(id: "abc-123", pid: 9999)

        let merged = Session.merge(files: [reported], discovered: [scanned])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].state, .working)
        XCTAssertFalse(merged[0].isDiscovered)
        XCTAssertEqual(merged[0].pid, 4242)
    }

    func testTheFileWinsOnASharedPID() throws {
        let reported = try file(#"{"session_id":"abc-123","state":"needs_you","pid":4242}"#)
        // The scanner never learned the id (no env, or a non-Claude agent) — matched by pid.
        let scanned = discovered(id: "discovered-4242", pid: 4242)

        let merged = Session.merge(files: [reported], discovered: [scanned])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].sessionID, "abc-123")
        XCTAssertEqual(merged[0].state, .needsYou)
    }

    func testAGenuinelyDifferentAgentSurvives() throws {
        let reported = try file(#"{"session_id":"abc-123","state":"working","pid":4242}"#)
        let scanned = discovered(id: "def-456", pid: 5555, agent: "gemini", host: .unknown)

        let merged = Session.merge(files: [reported], discovered: [scanned])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.sessionID), ["abc-123", "def-456"])
        XCTAssertTrue(merged[1].isDiscovered)
    }

    func testDiscoveredRowsNeverCollideWithEachOther() throws {
        let reported = try file(#"{"session_id":"abc-123","state":"working","pid":1}"#)
        let merged = Session.merge(
            files: [reported],
            discovered: [
                discovered(id: "dup", pid: 100),
                discovered(id: "dup", pid: 101),
                discovered(id: "other", pid: 100),
                discovered(id: "third", pid: 102),
            ]
        )
        XCTAssertEqual(merged.map(\.sessionID), ["abc-123", "dup", "third"])
    }

    func testAFileWithNoPIDStillWinsOnID() throws {
        let reported = try file(#"{"session_id":"abc-123","state":"done"}"#)
        let merged = Session.merge(
            files: [reported], discovered: [discovered(id: "abc-123", pid: 77)]
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].state, .done)
    }

    func testNothingToMergeIsNotASpecialCase() {
        XCTAssertTrue(Session.merge(files: [], discovered: []).isEmpty)
        XCTAssertEqual(Session.merge(files: [], discovered: [discovered(id: "x", pid: 1)]).count, 1)
    }

    /// The end-to-end shape §9.1 describes: the scanner finds a desktop session and gives it the
    /// real id, then the hook file for that very session lands and takes the row over.
    func testADiscoveredDesktopSessionIsReplacedByItsHookFileByID() throws {
        let scanned = discovered(id: "1d9e4b77-0c52-4a36-8f21-77a5c3b9d401", pid: 31844)
        XCTAssertEqual(Session.merge(files: [], discovered: [scanned]).count, 1)

        let reported = try file("""
        {"session_id":"1d9e4b77-0c52-4a36-8f21-77a5c3b9d401","state":"needs_you",
         "host":"claude-desktop","host_ref":"local_9c1d6e204a7f11ef","pid":31844}
        """)
        let merged = Session.merge(files: [reported], discovered: [scanned])
        XCTAssertEqual(merged.count, 1)
        XCTAssertFalse(merged[0].isDiscovered)
        XCTAssertNotNil(Jumper.desktopLink(hostRef: merged[0].hostRef))
    }
}
