import XCTest
@testable import Lookout

/// Bug fix (2026-09-04): a `PreToolUse` `AskUserQuestion` at 13:34Z got answered in the
/// terminal; the session ran on for six more hours; the reporter never removed the request file
/// (it only ever deletes the *one* file it currently references); when the session finally went
/// `done`, `RequestStore.request(for:)` handed the card that six-hour-old question back, and
/// clicking an option sent it into a session that had long since moved on.
///
/// These tests cover the three-part fix: (a) the session's own state file decides whether a
/// request still counts, (b) a request that is simply too old never attaches whatever the
/// session says, (c) an orphaned file is deleted outright rather than just hidden.
final class RequestStoreTests: XCTestCase {
    private var temporary: URL?

    override func tearDown() {
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        temporary = nil
        super.tearDown()
    }

    private func makeHome() -> LookoutHome {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-requeststore-\(UUID().uuidString)")
        temporary = url
        return LookoutHome(root: url)
    }

    /// Writes a request file for real, starts the store and waits for its own watcher/ticker to
    /// load it — the same asynchronous path the app uses (mirrors `NotificationActionsTests`'
    /// `loadedRequestStore`). `expecting` is the number of files that should actually make it
    /// into `store.requests` — some fixtures here are deliberately stale and load() is meant to
    /// filter them out, so waiting for "as many as were written" would just spin to the deadline.
    private func loadedStore(
        home: LookoutHome, requests: [(name: String, json: String)], expecting: Int? = nil
    ) throws -> RequestStore {
        try FileManager.default.createDirectory(
            at: home.requests, withIntermediateDirectories: true
        )
        for (name, json) in requests {
            try Data(json.utf8).write(to: home.requests.appendingPathComponent("\(name).json"))
        }
        let store = RequestStore(home: home)
        store.start()
        let wanted = expecting ?? requests.count
        let deadline = Date().addingTimeInterval(wanted == 0 ? 1 : 5)
        while store.requests.count < wanted, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return store
    }

    /// A minimal, valid session state file at the path `SessionStore`/`RequestStore` both expect
    /// (SPEC §4): `~/.lookout/sessions/<agent>-<session_id>.json`.
    private func writeSession(
        home: LookoutHome, agent: String, sessionID: String, state: String = "needs_you"
    ) throws {
        try FileManager.default.createDirectory(
            at: home.sessions, withIntermediateDirectories: true
        )
        let json = #"{"session_id":"\#(sessionID)","agent":"\#(agent)","state":"\#(state)"}"#
        try Data(json.utf8).write(
            to: home.sessions.appendingPathComponent("\(agent)-\(sessionID).json")
        )
    }

    private func session(
        id: String = "s1", state: SessionState = .needsYou, requestID: String? = "r1"
    ) -> Session {
        var value = Session()
        value.sessionID = id
        value.state = state
        value.requestID = requestID
        return value
    }

    // MARK: - (a) The session record decides, not "newest file for this id"

    func testAMatchingNeedsYouSessionGetsItsRequest() throws {
        let home = makeHome()
        let store = try loadedStore(home: home, requests: [
            (name: "claude-s1-r1", json: #"""
            {"session_id":"s1","request_id":"r1","kind":"permission",
             "created_at":"\#(ISO8601.string(Date()))"}
            """#),
        ])

        let found = store.request(for: session(state: .needsYou, requestID: "r1"))
        XCTAssertEqual(found?.requestID, "r1")
    }

    /// The exact shape of the bug: an orphaned, older question sits next to (or after) the live
    /// request for the same session — the session's own `request_id` is what breaks the tie, not
    /// which file is newer.
    func testAStaleOrphanNextToTheLiveRequestIsIgnoredEvenThoughItIsNewerByFile() throws {
        let home = makeHome()
        let old = ISO8601.string(Date().addingTimeInterval(-6 * 3600))
        let newer = ISO8601.string(Date().addingTimeInterval(-5 * 60))
        let store = try loadedStore(home: home, requests: [
            (name: "claude-s1-old", json: #"""
            {"session_id":"s1","request_id":"old","kind":"question","created_at":"\#(old)"}
            """#),
            // Written *after* — a real reporter would never do this, but the point is the id
            // match decides, not recency.
            (name: "claude-s1-newer-orphan", json: #"""
            {"session_id":"s1","request_id":"newer-orphan","kind":"question",
             "created_at":"\#(newer)"}
            """#),
        ], expecting: 1)
        // The session moved on and points at neither — both are orphans of one shape or another.
        XCTAssertNil(store.request(for: session(state: .needsYou, requestID: "current")))
    }

    func testARequestIdMismatchNeverAttaches() throws {
        let home = makeHome()
        let store = try loadedStore(home: home, requests: [
            (name: "claude-s1-r1", json: #"""
            {"session_id":"s1","request_id":"r1","kind":"permission",
             "created_at":"\#(ISO8601.string(Date()))"}
            """#),
        ])
        XCTAssertNil(store.request(for: session(state: .needsYou, requestID: "different")))
        XCTAssertNil(store.request(for: session(state: .needsYou, requestID: nil)))
    }

    /// "A done/working session never shows a question or permission request" — whatever the
    /// file itself says, however recent.
    func testADoneOrWorkingSessionNeverGetsARequestEvenWithAMatchingId() throws {
        let home = makeHome()
        let store = try loadedStore(home: home, requests: [
            (name: "claude-s1-r1", json: #"""
            {"session_id":"s1","request_id":"r1","kind":"question",
             "created_at":"\#(ISO8601.string(Date()))"}
            """#),
        ])
        XCTAssertNil(store.request(for: session(state: .done, requestID: "r1")))
        XCTAssertNil(store.request(for: session(state: .working, requestID: "r1")))
        XCTAssertNil(store.request(for: session(state: .idle, requestID: "r1")))
    }

    // MARK: - (b) Age guard — never attach past `staleAfter`, whatever the kind

    func testARequestOlderThanStaleAfterNeverAttachesEvenWithAPerfectIdMatch() throws {
        let home = makeHome()
        let sixtyOneMinutesAgo = Date().addingTimeInterval(-61 * 60)
        let store = try loadedStore(home: home, requests: [
            (name: "codex-s1-r1", json: #"""
            {"session_id":"s1","request_id":"r1","kind":"question",
             "created_at":"\#(ISO8601.string(sixtyOneMinutesAgo))"}
            """#),
        ], expecting: 0)
        // `store.requests` itself already filters this out on load (extended to all kinds).
        XCTAssertNil(store.request(for: "s1"), "load() prunes it from the published list too")
        XCTAssertNil(store.request(for: session(state: .needsYou, requestID: "r1")))
    }

    /// The direct regression: a `question` has no `waits_until` at all, so before this fix
    /// nothing about its age was ever checked.
    func testAQuestionSixHoursOldNeverAttachesEvenThoughItHasNoWaitsUntil() throws {
        let home = makeHome()
        let sixHoursAgo = Date().addingTimeInterval(-6 * 3600)
        let store = try loadedStore(home: home, requests: [
            (name: "claude-s1-r1", json: #"""
            {"session_id":"s1","request_id":"r1","kind":"question",
             "question":"Which migration?","options":["004","005"],
             "created_at":"\#(ISO8601.string(sixHoursAgo))"}
            """#),
        ], expecting: 0)
        XCTAssertNil(store.request(for: session(state: .needsYou, requestID: "r1")))
    }

    func testARequestJustUnderTheHourStillAttaches() throws {
        let home = makeHome()
        let fiftyNineMinutesAgo = Date().addingTimeInterval(-59 * 60)
        let store = try loadedStore(home: home, requests: [
            (name: "claude-s1-r1", json: #"""
            {"session_id":"s1","request_id":"r1","kind":"permission",
             "created_at":"\#(ISO8601.string(fiftyNineMinutesAgo))"}
            """#),
        ])
        XCTAssertNotNil(store.request(for: session(state: .needsYou, requestID: "r1")))
    }

    // MARK: - (c) Garbage collection: `pruneOrphans`

    func testPruneOrphansDeletesAFileOlderThanSixHoursRegardlessOfItsSession() throws {
        let home = makeHome()
        try writeSession(home: home, agent: "claude", sessionID: "s1")
        let sevenHoursAgo = Date().addingTimeInterval(-7 * 3600)
        let store = try loadedStore(home: home, requests: [
            (name: "claude-s1-r1", json: #"""
            {"agent":"claude","session_id":"s1","request_id":"r1","kind":"permission",
             "created_at":"\#(ISO8601.string(sevenHoursAgo))"}
            """#),
        ], expecting: 0)

        let removed = store.pruneOrphans()
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: home.requests.appendingPathComponent("claude-s1-r1.json").path
            )
        )
    }

    func testPruneOrphansDeletesARequestWhoseSessionHasNoStateFileAtAll() throws {
        let home = makeHome()
        // No session file written at all for "s1" — the session ended, or never really existed.
        let fiveMinutesAgo = Date().addingTimeInterval(-5 * 60)
        let store = try loadedStore(home: home, requests: [
            (name: "claude-s1-r1", json: #"""
            {"session_id":"s1","request_id":"r1","kind":"question",
             "created_at":"\#(ISO8601.string(fiveMinutesAgo))"}
            """#),
        ])

        let removed = store.pruneOrphans()
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: home.requests.appendingPathComponent("claude-s1-r1.json").path
            )
        )
    }

    func testPruneOrphansLeavesARecentRequestWithALiveSessionAlone() throws {
        let home = makeHome()
        try writeSession(home: home, agent: "claude", sessionID: "s1")
        let fiveMinutesAgo = Date().addingTimeInterval(-5 * 60)
        let store = try loadedStore(home: home, requests: [
            (name: "claude-s1-r1", json: #"""
            {"agent":"claude","session_id":"s1","request_id":"r1","kind":"permission",
             "created_at":"\#(ISO8601.string(fiveMinutesAgo))"}
            """#),
        ])

        let removed = store.pruneOrphans()
        XCTAssertEqual(removed, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: home.requests.appendingPathComponent("claude-s1-r1.json").path
            )
        )
    }

    /// `pruneOrphans` only ever touches files directly under its own `requests` directory —
    /// it must never so much as look at, let alone delete, anything under `sessions`.
    func testPruneOrphansNeverTouchesTheSessionsDirectory() throws {
        let home = makeHome()
        try writeSession(home: home, agent: "claude", sessionID: "s1")
        let store = try loadedStore(home: home, requests: [
            (name: "claude-s1-r1", json: #"""
            {"agent":"claude","session_id":"s1","request_id":"r1","kind":"permission",
             "created_at":"\#(ISO8601.string(Date()))"}
            """#),
        ])

        _ = store.pruneOrphans()
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: home.sessions.appendingPathComponent("claude-s1.json").path
            ),
            "the session file must survive untouched"
        )
    }
}
