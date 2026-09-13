import XCTest
@testable import Lookout

/// The "Put on hold" auto-clear rule (the owner: "one can be finished or on hold ... not closing
/// it") — `SessionHold` is a pure function of a session and the moment it was held, so all of
/// this is tested without a window or a `Settings` instance.
final class SessionHoldTests: XCTestCase {
    private func session(
        _ state: SessionState, stateSince: Date? = nil, updatedAt: Date? = nil
    ) -> Session {
        var session = Session()
        session.sessionID = "s1"
        session.state = state
        session.stateSince = stateSince
        session.updatedAt = updatedAt
        return session
    }

    private let heldAt = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - shouldClear

    /// needs_you always wins, whatever the timestamps say.
    func testNeedsYouAlwaysClearsTheHoldEvenWithNoTimestampAtAll() {
        let session = session(.needsYou)
        XCTAssertTrue(SessionHold.shouldClear(session: session, heldSince: heldAt))
    }

    /// A quiet `Stop` → `done` after the hold is exactly what "on hold" is for — it must not
    /// clear it.
    func testAQuietDoneAfterTheHoldKeepsTheHold() {
        let session = session(.done, stateSince: heldAt.addingTimeInterval(60))
        XCTAssertFalse(SessionHold.shouldClear(session: session, heldSince: heldAt))
    }

    /// A fresh prompt (working, with activity newer than the hold) clears it.
    func testANewPromptAfterTheHoldClearsIt() {
        let session = session(.working, stateSince: heldAt.addingTimeInterval(60))
        XCTAssertTrue(SessionHold.shouldClear(session: session, heldSince: heldAt))
    }

    /// `working` from *before* the hold (the state the session was already in when it was held)
    /// must not clear it — only activity *since* the hold counts.
    func testWorkingActivityFromBeforeTheHoldDoesNotClearIt() {
        let session = session(.working, stateSince: heldAt.addingTimeInterval(-60))
        XCTAssertFalse(SessionHold.shouldClear(session: session, heldSince: heldAt))
    }

    /// `working` with no timestamp at all is treated as no activity — never clears.
    func testWorkingWithNoTimestampDoesNotClearIt() {
        let session = session(.working)
        XCTAssertFalse(SessionHold.shouldClear(session: session, heldSince: heldAt))
    }

    /// `updated_at` counts too when `state_since` is missing.
    func testWorkingUsesUpdatedAtWhenStateSinceIsMissing() {
        let session = session(.working, updatedAt: heldAt.addingTimeInterval(5))
        XCTAssertTrue(SessionHold.shouldClear(session: session, heldSince: heldAt))
    }

    func testIdleAndRunningNeverClearTheHold() {
        XCTAssertFalse(
            SessionHold.shouldClear(
                session: session(.idle, stateSince: heldAt.addingTimeInterval(60)),
                heldSince: heldAt
            )
        )
        XCTAssertFalse(
            SessionHold.shouldClear(
                session: session(.running, stateSince: heldAt.addingTimeInterval(60)),
                heldSince: heldAt
            )
        )
    }

    // MARK: - isHeld

    func testANeverHeldSessionIsNotHeld() {
        XCTAssertFalse(SessionHold.isHeld(session: session(.idle), heldSince: nil))
    }

    func testAHeldSessionThatHasNotClearedIsHeld() {
        let session = session(.idle)
        XCTAssertTrue(SessionHold.isHeld(session: session, heldSince: heldAt))
    }

    func testAHeldSessionThatShouldClearIsNotHeldAnyMore() {
        let session = session(.needsYou)
        XCTAssertFalse(SessionHold.isHeld(session: session, heldSince: heldAt))
    }

    func testADoneSessionStaysHeldIndefinitely() {
        let session = session(.done, stateSince: heldAt.addingTimeInterval(3600))
        XCTAssertTrue(SessionHold.isHeld(session: session, heldSince: heldAt))
    }
}
