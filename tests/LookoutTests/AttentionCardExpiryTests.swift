import AppKit
import SwiftUI
import XCTest
@testable import Lookout

extension AttentionCardTests {
    // MARK: - Done-card expiry and dedupe (cards lane, 2026-09-04)
    //
    // Measured: 39 cards shown in 2 hours, 14 ignored. `done` cards now self-expire after 30
    // minutes instead of piling up, and the same finished turn is never shown twice. `needs_you`
    // keeps today's behaviour throughout — it has no queue-owned TTL at all.

    func testADoneCardExpiresThirtyMinutesAfterItOpens() {
        var now = Date()
        let coordinator = AttentionCoordinator(settings: settings, clock: { now })
        settings.cardOnDone = true

        coordinator.handle(transition: session(state: .done), from: .working)
        XCTAssertEqual(coordinator.current?.id, "s1")
        XCTAssertEqual(coordinator.current?.expiresAt, now.addingTimeInterval(30 * 60))

        // A second short of 30 minutes: still there.
        now = now.addingTimeInterval(30 * 60 - 1)
        XCTAssertFalse(coordinator.expireDoneCards(isTypingInCurrent: false))
        XCTAssertNotNil(coordinator.current)

        // Past the mark: gone silently — no answer, no notification, just an empty queue.
        now = now.addingTimeInterval(2)
        XCTAssertTrue(coordinator.expireDoneCards(isTypingInCurrent: false))
        XCTAssertNil(coordinator.current)
    }

    func testTheNextQueuedCardTakesOverWhenTheFrontOneExpires() {
        var now = Date()
        let coordinator = AttentionCoordinator(settings: settings, clock: { now })
        settings.cardOnDone = true

        coordinator.handle(transition: session(id: "a", state: .done), from: .working)
        coordinator.handle(transition: session(id: "b", state: .needsYou), from: .working)
        XCTAssertEqual(coordinator.queue.map(\.id), ["a", "b"])

        now = now.addingTimeInterval(31 * 60)
        XCTAssertTrue(coordinator.expireDoneCards(isTypingInCurrent: false))
        XCTAssertEqual(coordinator.queue.map(\.id), ["b"], "a leaves silently, b takes over")
    }

    func testNeedsYouCardsNeverExpireFromTheQueue() {
        var now = Date()
        let coordinator = AttentionCoordinator(settings: settings, clock: { now })
        coordinator.handle(transition: session(state: .needsYou), from: .working)
        XCTAssertNil(coordinator.current?.expiresAt, "needs_you has no queue-owned TTL")

        now = now.addingTimeInterval(6 * 3600)
        XCTAssertFalse(coordinator.expireDoneCards(isTypingInCurrent: false))
        XCTAssertNotNil(coordinator.current, "the sweep never touches a needs_you card")
    }

    func testTypingExtendsAnAboutToExpireDoneCardByFiveMinutes() {
        var now = Date()
        let coordinator = AttentionCoordinator(settings: settings, clock: { now })
        settings.cardOnDone = true
        coordinator.handle(transition: session(state: .done), from: .working)

        now = now.addingTimeInterval(30 * 60 + 5)
        // the owner is mid-reply: held open instead of pulled away.
        XCTAssertTrue(coordinator.expireDoneCards(isTypingInCurrent: true))
        XCTAssertNotNil(coordinator.current, "extended while typing")
        XCTAssertEqual(coordinator.current?.expiresAt, now.addingTimeInterval(5 * 60))

        // He stops typing; the extension itself then runs out.
        now = now.addingTimeInterval(5 * 60 + 1)
        XCTAssertTrue(coordinator.expireDoneCards(isTypingInCurrent: false))
        XCTAssertNil(coordinator.current)
    }

    func testADoneCardIsNeverShownTwiceForTheSameStateSince() {
        let coordinator = AttentionCoordinator(settings: settings)
        settings.cardOnDone = true
        let since = Date()
        var finished = session(state: .done)
        finished.stateSince = since

        coordinator.handle(transition: finished, from: .working)
        XCTAssertEqual(coordinator.current?.id, "s1")
        coordinator.dismissCurrent()
        XCTAssertNil(coordinator.current)

        // The session file is re-read, or the app's own transition tracking starts over mid-
        // session — either way `previous` reads as nil, which alone would look like a brand-new
        // transition for the exact same finished turn.
        coordinator.handle(transition: finished, from: nil)
        XCTAssertNil(coordinator.current, "the same (id, state_since) must not reopen")

        // A genuinely new `done` — a later turn, a fresh `state_since` — is a different card.
        var again = finished
        again.stateSince = since.addingTimeInterval(120)
        coordinator.handle(transition: again, from: .working)
        XCTAssertEqual(coordinator.current?.id, "s1", "a real new finish still opens a card")
    }

    /// Bug fix, 2026-09-06: `enqueue`'s "already in the queue" branch used to only refresh
    /// `session`/`trigger` and return — a card that opened as `needs_you` and then turned into
    /// `done` in place (the common real-world path: the same session, same queue slot) never got
    /// `expiresAt` set or its done key recorded, so it never expired and could reopen after a
    /// restart. This exercises that exact in-place transition, not the "brand-new item" path
    /// `testADoneCardExpiresThirtyMinutesAfterItOpens` already covers.
    func testANeedsYouCardThatFinishesInPlaceGetsTheDoneExpiryAndDedupe() {
        var now = Date()
        let coordinator = AttentionCoordinator(settings: settings, clock: { now })
        settings.cardOnDone = true

        coordinator.handle(transition: session(state: .needsYou), from: .working)
        XCTAssertEqual(coordinator.current?.trigger, .needsYou)
        XCTAssertNil(coordinator.current?.expiresAt, "needs_you has no queue-owned TTL")

        // The same session id, still the same queue slot, turns into done.
        var finished = session(state: .done)
        finished.stateSince = Date(timeIntervalSince1970: 1_700_000_000)
        coordinator.handle(transition: finished, from: .needsYou)

        XCTAssertEqual(coordinator.current?.trigger, .done)
        XCTAssertEqual(
            coordinator.current?.expiresAt, now.addingTimeInterval(AttentionCoordinator.doneExpiry),
            "flipping to done in place must start the 30-minute clock, exactly like a brand-new done card"
        )

        // Past 31 minutes: expires exactly like any other done card.
        now = now.addingTimeInterval(31 * 60)
        XCTAssertTrue(coordinator.expireDoneCards(isTypingInCurrent: false))
        XCTAssertNil(coordinator.current)

        // Reopening for the very same (session, state_since) is refused — the done key must have
        // been recorded when the trigger flipped in place, not only on the brand-new-item path.
        coordinator.handle(transition: finished, from: nil)
        XCTAssertNil(coordinator.current, "the same (id, state_since) must not reopen")
    }

    /// The other direction: a `done` card whose owner reopens the same request (session goes
    /// back to `needs_you` in place) must lose its expiry — it must not silently expire out from
    /// under an active `needs_you` ask just because it once had a TTL as `done`.
    func testADoneCardThatReopensAsNeedsYouInPlaceClearsItsExpiry() {
        var now = Date()
        let coordinator = AttentionCoordinator(settings: settings, clock: { now })
        settings.cardOnDone = true

        coordinator.handle(transition: session(state: .done), from: .working)
        XCTAssertNotNil(coordinator.current?.expiresAt)

        coordinator.handle(transition: session(state: .needsYou), from: .done)
        XCTAssertEqual(coordinator.current?.trigger, .needsYou)
        XCTAssertNil(coordinator.current?.expiresAt, "needs_you carries no queue-owned TTL")

        // And the expiry sweep must never touch it, even long after the old done deadline.
        now = now.addingTimeInterval(6 * 3600)
        XCTAssertFalse(coordinator.expireDoneCards(isTypingInCurrent: false))
        XCTAssertNotNil(coordinator.current)
    }

    func testIsTypingOrFocusedReflectsTextAndFieldFocus() {
        let (model, coordinator) = makeModel()
        settings.cardOnDone = true
        coordinator.present(session(state: .done))
        model.present(coordinator.current, request: nil)

        XCTAssertFalse(model.isTypingOrFocused)
        model.text = "half-written reply"
        XCTAssertTrue(model.isTypingOrFocused)
        model.text = ""
        XCTAssertFalse(model.isTypingOrFocused)
        model.replyFieldFocused = true
        XCTAssertTrue(model.isTypingOrFocused, "focus alone also counts, not just typed text")
    }

    func testModelTickAppliesTheCoordinatorsExpirySweep() {
        var now = Date()
        let coordinator = AttentionCoordinator(settings: settings, clock: { now })
        let model = AttentionCardModel(
            settings: settings, coordinator: coordinator, suggester: Suggester(), home: home
        )
        model.jumper = { _ in }
        settings.cardOnDone = true

        coordinator.handle(transition: session(state: .done), from: .working)
        model.present(coordinator.current, request: nil)

        // Typing holds it open past the 30-minute mark.
        model.text = "still writing"
        now = now.addingTimeInterval(30 * 60 + 5)
        model.tick(now: now)
        XCTAssertNotNil(coordinator.current, "extended while the owner is typing")

        // He finishes and clears the field; the extension itself then runs out.
        model.text = ""
        now = now.addingTimeInterval(5 * 60 + 1)
        model.tick(now: now)
        XCTAssertNil(coordinator.current)
    }

    func testTheExpiryCaptionOnlyShowsInsideTheLastFiveMinutes() {
        var now = Date()
        let coordinator = AttentionCoordinator(settings: settings, clock: { now })
        let model = AttentionCardModel(
            settings: settings, coordinator: coordinator, suggester: Suggester(), home: home
        )
        model.jumper = { _ in }
        settings.cardOnDone = true

        coordinator.handle(transition: session(state: .done), from: .working)
        model.present(coordinator.current, request: nil)
        XCTAssertNil(model.expiryCaption, "30 minutes out — no caption yet")
        XCTAssertNil(model.statusLine)

        // Six minutes left: still quiet.
        now = now.addingTimeInterval(24 * 60)
        model.tick(now: now)
        XCTAssertNil(model.expiryCaption)

        // Inside the last five minutes: the caption takes the card's existing footer line —
        // no second line, no layout jump.
        now = now.addingTimeInterval(61)
        model.tick(now: now)
        XCTAssertEqual(model.expiryCaption, "Expires in 5m")
        XCTAssertEqual(model.statusLine, "Expires in 5m")
        XCTAssertFalse(model.statusLineIsError)

        // A needs_you card never shows a caption at all.
        coordinator.present(session(id: "n", state: .needsYou))
        model.present(coordinator.current, request: nil)
        XCTAssertNil(model.expiryCaption)
    }
}
