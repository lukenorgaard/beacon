import XCTest
@testable import Lookout

final class SortOrderTests: XCTestCase {
    private func session(
        _ id: String, _ state: SessionState, minutesAgo: Double
    ) throws -> Session {
        let since = ISO8601.string(Date(timeIntervalSince1970: 1_800_000_000 - minutesAgo * 60))
        let json = """
        {"session_id":"\(id)","state":"\(state.rawValue)","state_since":"\(since)"}
        """
        return try JSONDecoder().decode(Session.self, from: Data(json.utf8))
    }

    /// SPEC §8.2: needs_you → done → working → running → idle.
    func testGroupOrder() throws {
        let sessions = try [
            session("idle", .idle, minutesAgo: 1),
            session("running", .running, minutesAgo: 1),
            session("working", .working, minutesAgo: 1),
            session("done", .done, minutesAgo: 1),
            session("needs", .needsYou, minutesAgo: 1),
        ]
        XCTAssertEqual(
            Session.sorted(sessions).map(\.id),
            ["needs", "done", "working", "running", "idle"]
        )
    }

    func testNeedsYouIsOldestFirstAndDoneIsNewestFirst() throws {
        let sessions = try [
            session("needs-new", .needsYou, minutesAgo: 2),
            session("needs-old", .needsYou, minutesAgo: 40),
            session("done-old", .done, minutesAgo: 30),
            session("done-new", .done, minutesAgo: 1),
        ]
        XCTAssertEqual(
            Session.sorted(sessions).map(\.id),
            ["needs-old", "needs-new", "done-new", "done-old"]
        )
    }

    func testWorkingRunningAndIdleAreNewestFirstWithinTheirGroup() throws {
        let sessions = try [
            session("work-old", .working, minutesAgo: 20),
            session("work-new", .working, minutesAgo: 1),
            session("run-old", .running, minutesAgo: 90),
            session("run-new", .running, minutesAgo: 3),
            session("idle-old", .idle, minutesAgo: 60),
            session("idle-new", .idle, minutesAgo: 5),
        ]
        XCTAssertEqual(
            Session.sorted(sessions).map(\.id),
            ["work-new", "work-old", "run-new", "run-old", "idle-new", "idle-old"]
        )
    }

    func testTiesFallBackToSessionIDSoTheListNeverJitters() throws {
        let sessions = try [
            session("b", .working, minutesAgo: 5),
            session("a", .working, minutesAgo: 5),
        ]
        XCTAssertEqual(Session.sorted(sessions).map(\.id), ["a", "b"])
        XCTAssertEqual(Session.sorted(sessions.reversed()).map(\.id), ["a", "b"])
    }

    /// On hold (manual override): a held session sorts below every real state, including idle.
    func testAHeldSessionSortsBelowIdle() throws {
        var held = try session("held", .working, minutesAgo: 1)
        held.isHeld = true
        let sessions = try [
            session("idle", .idle, minutesAgo: 1),
            held,
            session("working", .working, minutesAgo: 1),
        ]
        XCTAssertEqual(Session.sorted(sessions).map(\.id), ["working", "idle", "held"])
    }

    /// `needs_you` always wins — a session that is somehow both `isHeld` and `needs_you` (which
    /// `AppState` never actually produces, `SessionHold` clears the hold outright) still sorts
    /// on top, not at the bottom.
    func testNeedsYouSortsFirstEvenIfSomehowMarkedHeld() throws {
        var held = try session("held-needs", .needsYou, minutesAgo: 1)
        held.isHeld = true
        let sessions = try [session("idle", .idle, minutesAgo: 1), held]
        XCTAssertEqual(Session.sorted(sessions).map(\.id), ["held-needs", "idle"])
    }

    func testSessionsWithNoTimestampSinkToTheBottomOfTheirGroup() throws {
        let dated = try session("dated", .working, minutesAgo: 30)
        let undated = try JSONDecoder().decode(
            Session.self, from: Data(#"{"session_id":"undated","state":"working"}"#.utf8)
        )
        XCTAssertEqual(Session.sorted([undated, dated]).map(\.id), ["dated", "undated"])
    }

    func testTheFixtureFolderSortsTheWayTheREADMEClaims() throws {
        let names = try FileManager.default
            .contentsOfDirectory(atPath: Fixtures.sessionsDirectory.path)
            .filter { $0.hasSuffix(".json") }
        let sessions = try names.map { name -> Session in
            let url = Fixtures.sessionsDirectory.appendingPathComponent(name)
            return try JSONDecoder().decode(Session.self, from: Data(contentsOf: url))
        }
        XCTAssertEqual(
            Session.sorted(sessions).map(\.project),
            [
                "daily-notes",         // needs_you, oldest
                "billing-api",    // needs_you, newer
                "Lookout",                 // done
                "docs-site",             // working, newest
                "Voyager",                   // working
                "Beacon",                // idle
            ]
        )
    }
}
