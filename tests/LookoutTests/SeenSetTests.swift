import XCTest
@testable import Lookout

final class SeenSetTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "io.github.lukenorgaard.beacon.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func session(_ id: String, _ state: SessionState) throws -> Session {
        try JSONDecoder().decode(
            Session.self,
            from: Data(#"{"session_id":"\#(id)","state":"\#(state.rawValue)"}"#.utf8)
        )
    }

    func testUnseenDoneUntilMarked() throws {
        let sessions = try [session("a", .done), session("b", .done), session("c", .working)]
        let seen = SeenSet(defaults: defaults)

        XCTAssertEqual(seen.unseenDone(in: sessions).map(\.id), ["a", "b"])
        seen.markSeen("a")
        XCTAssertTrue(seen.isSeen("a"))
        XCTAssertEqual(seen.unseenDone(in: sessions).map(\.id), ["b"])
    }

    func testMarkAllSeenOnlyTouchesDoneSessions() throws {
        let sessions = try [session("a", .done), session("b", .working), session("c", .needsYou)]
        let seen = SeenSet(defaults: defaults)
        seen.markAllSeen(sessions)

        XCTAssertTrue(seen.isSeen("a"))
        XCTAssertFalse(seen.isSeen("b"))
        XCTAssertTrue(seen.unseenDone(in: sessions).isEmpty)
    }

    func testTheFlagSurvivesARestart() throws {
        let sessions = try [session("a", .done)]
        SeenSet(defaults: defaults).markSeen("a")

        let reopened = SeenSet(defaults: defaults)
        XCTAssertTrue(reopened.isSeen("a"))
        XCTAssertTrue(reopened.unseenDone(in: sessions).isEmpty)
    }

    /// The important one: a session that starts another turn and finishes again must light up
    /// the menu bar a second time.
    func testLeavingDoneClearsTheFlagSoTheNextFinishNotifiesAgain() throws {
        let seen = SeenSet(defaults: defaults)
        seen.markSeen("a")

        seen.reconcile(with: try [session("a", .working)])
        XCTAssertFalse(seen.isSeen("a"))

        let finishedAgain = try [session("a", .done)]
        XCTAssertEqual(seen.unseenDone(in: finishedAgain).map(\.id), ["a"])
    }

    func testVanishedSessionsAreDroppedSoTheSetCannotGrowForever() throws {
        let seen = SeenSet(defaults: defaults)
        seen.markSeen("gone")
        seen.markSeen("here")

        seen.reconcile(with: try [session("here", .done)])
        XCTAssertFalse(seen.isSeen("gone"))
        XCTAssertTrue(seen.isSeen("here"))
        XCTAssertEqual(defaults.stringArray(forKey: "seenDoneSessions"), ["here"])
    }

    func testReconcileWithNothingClearsEverything() throws {
        let seen = SeenSet(defaults: defaults)
        seen.markSeen("a")
        seen.reconcile(with: [])
        XCTAssertFalse(seen.isSeen("a"))
    }
}
