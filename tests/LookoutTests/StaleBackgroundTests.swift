import AppKit
import XCTest
@testable import Lookout

/// Bug fix (2026-09-04): a session sat "Working… · 1 background task running" for ten hours —
/// the reporter set `working`/`background` when Claude Code reported a live background task,
/// the task hung, and no later hook event ever arrived, even though the turn had actually ended
/// (with a question) hours earlier. The reporter side is fixed separately; this is the pure
/// staleness rule plus its `AppState` wiring: sort, counts, the one-shot notification and card.
final class StaleBackgroundTests: XCTestCase {
    private func session(
        id: String = "s1", updatedAgo: TimeInterval = 3 * 60 * 60, reason: String? = "background",
        state: SessionState = .working
    ) -> Session {
        var value = Session()
        value.sessionID = id
        value.project = id
        value.state = state
        value.reason = reason
        value.updatedAt = Date().addingTimeInterval(-updatedAgo)
        value.detail = "1 background task running"
        return value
    }

    // MARK: - The pure rule

    func testOnlyWorkingBackgroundOlderThanTwoHoursIsStale() {
        XCTAssertTrue(StaleBackground.isStale(session: session(updatedAgo: 3 * 60 * 60)))

        XCTAssertFalse(
            StaleBackground.isStale(session: session(updatedAgo: 60 * 60)),
            "under two hours is not stale yet"
        )
        XCTAssertFalse(
            StaleBackground.isStale(session: session(updatedAgo: 3 * 60 * 60, reason: "tool")),
            "only the background reason qualifies — an ordinary working session is untouched"
        )
        XCTAssertFalse(
            StaleBackground.isStale(session: session(updatedAgo: 3 * 60 * 60, state: .needsYou)),
            "needs_you is never reinterpreted, whatever the reason says"
        )
        XCTAssertFalse(
            StaleBackground.isStale(session: session(updatedAgo: 3 * 60 * 60, state: .done)),
            "an already-done session has nothing to decorate"
        )

        var noTimestamp = session(updatedAgo: 3 * 60 * 60)
        noTimestamp.updatedAt = nil
        XCTAssertFalse(StaleBackground.isStale(session: noTimestamp), "no updated_at, no verdict")
    }

    /// Two hours exactly is not yet stale — `>`, not `>=` (SPEC: "older than 2 hours"). Both
    /// sides are pinned against the same fixed `now`, not a live `Date()`, so the assertion
    /// cannot flake on however many microseconds pass between building the session and asking.
    func testTheTwoHourBoundaryIsExclusive() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        var onTheDot = session()
        onTheDot.updatedAt = now.addingTimeInterval(-StaleBackground.staleAfter)
        XCTAssertFalse(StaleBackground.isStale(session: onTheDot, now: now))

        var aSecondPast = session()
        aSecondPast.updatedAt = now.addingTimeInterval(-StaleBackground.staleAfter - 1)
        XCTAssertTrue(StaleBackground.isStale(session: aSecondPast, now: now))
    }

    func testDecorateOverridesStateAndDetailOnlyWhenStaleAndLeavesEverythingElseAlone() {
        let stale = session(updatedAgo: 3 * 60 * 60)
        let decorated = StaleBackground.decorate(stale)
        XCTAssertEqual(decorated.state, .done)
        XCTAssertEqual(decorated.detail, StaleBackground.detail)
        XCTAssertEqual(decorated.statusLabel, "Finished")
        XCTAssertEqual(decorated.reason, "background", "the raw reason survives untouched")
        XCTAssertEqual(decorated.updatedAt, stale.updatedAt, "nothing else on the record moves")

        let fresh = session(updatedAgo: 5 * 60)
        XCTAssertEqual(
            StaleBackground.decorate(fresh), fresh, "not stale — the record is handed back as is"
        )
    }

    // MARK: - `AppState` wiring: sort, counts, notification/card

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var settings: Lookout.Settings!
    private var state: AppState!
    private var temporary: URL?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        suiteName = "io.github.lukenorgaard.beacon.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = Lookout.Settings(defaults: defaults)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-stale-\(UUID().uuidString)")
        temporary = root
        state = AppState(
            settings: settings,
            store: SessionStore(home: root),
            usage: UsageClient(),
            home: LookoutHome(root: root)
        )
        // `Notifier.notify` crashes the whole test binary outside a real app bundle — the same
        // reasoning `AppStateHoldTests` uses; every test here goes through the card instead.
        settings.notifyNeedsYou = false
        settings.notifyDone = false
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

    func testAStaleBackgroundSessionSortsAboveAGenuinelyWorkingOneAndDropsOutOfTheWorkingCount() {
        let stale = session(id: "stale", updatedAgo: 3 * 60 * 60)
        let busy = session(id: "busy", updatedAgo: 60)

        state.apply([stale, busy])

        // "done" outranks "working" (SPEC §8.2) — the decorated session moves to the front.
        XCTAssertEqual(state.allSessions.map(\.id), ["stale", "busy"])
        let decorated = try! XCTUnwrap(state.allSessions.first { $0.id == "stale" })
        XCTAssertEqual(decorated.state, .done)
        XCTAssertEqual(decorated.statusLabel, "Finished")
        XCTAssertEqual(state.workingCount, 1, "the stale session no longer counts as working")
        XCTAssertEqual(state.unseenDoneCount, 1, "and it does count in the done/unseen total")
    }

    func testAFreshWorkingBackgroundSessionIsLeftAlone() {
        let fresh = session(id: "fresh", updatedAgo: 5 * 60)
        state.apply([fresh])

        XCTAssertEqual(state.allSessions.first?.state, .working)
        XCTAssertEqual(state.allSessions.first?.detail, "1 background task running")
        XCTAssertEqual(state.workingCount, 1)
    }

    func testAStaleBackgroundSessionOpensADoneCardOnceAndNeverReopensItOnTheNextApply() {
        settings.cardOnDone = true
        let stale = session(id: "stale", updatedAgo: 3 * 60 * 60)

        state.apply([stale])
        XCTAssertEqual(state.attention.current?.id, "stale")
        XCTAssertEqual(state.attention.current?.trigger, .done)

        // The user dismisses it — re-applying the *same*, still-stale session must not reopen
        // it: without the one-time guard, every apply() (the ticker fires every minute in the
        // real app) would read as a fresh working → done transition and pop it right back.
        state.attention.dismissCurrent()
        state.apply([stale])
        XCTAssertNil(state.attention.current, "already handled once")
    }

    func testAStaleBackgroundSessionNeverOpensACardWhenCardOnDoneIsOff() {
        settings.cardOnDone = false
        state.apply([session(id: "stale", updatedAgo: 3 * 60 * 60)])
        XCTAssertNil(state.attention.current, "done cards are opt-in — this is still just a done card")
    }

    /// Once the reporter's own fix eventually lands a real `Stop`/`SessionEnd`, or the session
    /// otherwise leaves the picture, the one-time notification bookkeeping must not leak.
    func testANewlyGoneSessionIsForgottenSoItCanNotifyAgainIfItEverReturns() {
        settings.cardOnDone = true
        let stale = session(id: "stale", updatedAgo: 3 * 60 * 60)
        state.apply([stale])
        XCTAssertEqual(state.attention.current?.id, "stale")

        state.attention.dismissCurrent()
        state.apply([]) // the session vanished entirely
        XCTAssertNil(state.attention.current)

        // A brand new session reusing the id (unlikely, but the bookkeeping must not assume
        // otherwise) opens its own card again rather than being silently treated as "already
        // handled".
        state.apply([stale])
        XCTAssertEqual(state.attention.current?.id, "stale")
    }
}
