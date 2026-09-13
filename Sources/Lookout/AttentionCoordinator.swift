import Combine
import Foundation

/// One card's worth of work: the session, and the state that opened it.
struct AttentionItem: Identifiable, Equatable {
    var session: Session
    /// `needs_you` or `done` — the card closes when the session leaves it (SPEC §11.4).
    var trigger: SessionState
    var openedAt: Date = Date()
    /// Cards lane, 2026-09-04: only ever set for `trigger == .done` — `openedAt` + 30 minutes,
    /// pushed out by 5 more while the owner is typing a reply (`AttentionCoordinator.expireDoneCards`).
    /// Always nil for `needs_you`: that one keeps today's behaviour and follows the request's own
    /// lifetime (`AttentionRequest.isAnswerable`/`isExpired`), not a queue-owned TTL.
    var expiresAt: Date?

    var id: String { session.sessionID }

    /// Cards lane, 2026-09-04: the dedupe identity for a `done` card — the session id plus the
    /// timestamp its state last changed. Nil for anything that is not `done`, or that carries no
    /// `state_since` at all (an old reporter, or a synthetic session) — such a card can never be
    /// marked seen, so it is simply never deduped, which is the safe default.
    var doneKey: String? {
        AttentionItem.doneKey(sessionID: session.sessionID, stateSince: session.stateSince)
    }

    static func doneKey(sessionID: String, stateSince: Date?) -> String? {
        guard let stateSince else { return nil }
        return "\(sessionID)#\(stateSince.timeIntervalSince1970)"
    }
}

/// Decides which sessions get a card, keeps the queue, and closes cards that are no longer about
/// anything (SPEC §11.4). No AppKit here on purpose: the whole state machine is testable without
/// a window.
final class AttentionCoordinator: ObservableObject {
    /// First entry = the card on screen; the rest are the "next" chip.
    @Published private(set) var queue: [AttentionItem] = []

    private let settings: Settings
    /// Sessions the user ignored, until their next transition (SPEC §11.4).
    private var ignored: Set<String> = []
    /// Sessions already answered from the card, so a re-render does not reopen them.
    private var answered: Set<String> = []
    /// Test seam: everything here reads "now" through this instead of `Date()` directly, so the
    /// 30-minute/5-minute TTLs are exercisable with an injected clock (SPEC "Tests: expiry with
    /// an injected clock").
    private let clock: () -> Date

    /// Cards lane, 2026-09-04: every `(session id, state_since)` a `done` card has already been
    /// shown for. In-memory only, oldest dropped past `maxSeenDoneKeys` — a long-running session
    /// must not grow this forever. This is what keeps the same finished turn from reopening after
    /// a session file re-read or after the app's own transition-tracking starts over mid-session
    /// (`SessionStore.previousStates` has no memory of its own across such a restart, so without
    /// this a `done` session sitting untouched for an hour would read as a brand-new transition).
    private var seenDoneKeys: [String] = []
    private var seenDoneKeySet: Set<String> = []
    static let maxSeenDoneKeys = 200

    /// The most cards that may pile up. A machine with twenty finished sessions must not queue
    /// twenty cards.
    static let maxQueue = 8

    /// Cards lane, 2026-09-04: a `done` card left untouched for half an hour is clutter, not
    /// something waiting on the owner — measured 39 cards/2h with 14 ignored is the backlog this
    /// fixes. `needs_you` is untouched by this constant; see `AttentionItem.expiresAt`.
    static let doneExpiry: TimeInterval = 30 * 60
    /// How much longer an about-to-expire `done` card lives while the owner has text in the reply
    /// field or the field itself has focus, so it is never pulled out from under him mid-sentence
    /// (the same "don't clear the reply while typing" instinct `present(_:)` already protects).
    static let typingExtension: TimeInterval = 5 * 60

    init(settings: Settings, clock: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.clock = clock
    }

    var current: AttentionItem? { queue.first }
    var pendingCount: Int { max(0, queue.count - 1) }

    // MARK: - Triggers

    /// SPEC §11.4: a card opens on the transition *into* `needs_you` (always) or `done` (when
    /// the toggle is on), for a session that is opted in and not ignored.
    static func triggers(state: SessionState, onDone: Bool) -> Bool {
        switch state {
        case .needsYou: return true
        case .done: return onDone
        default: return false
        }
    }

    func shouldOpen(for session: Session, from previous: SessionState?) -> Bool {
        guard settings.attentionCards else { return false }
        guard AttentionCoordinator.triggers(state: session.state, onDone: settings.cardOnDone)
        else { return false }
        guard session.state != previous else { return false }
        guard settings.cardsEnabled(for: session.sessionID) else { return false }
        guard !ignored.contains(session.sessionID) else { return false }
        // Cards lane, 2026-09-04: a `done` card already shown for this exact state never reopens.
        if session.state == .done,
            let key = AttentionItem.doneKey(sessionID: session.sessionID, stateSince: session.stateSince),
            seenDoneKeySet.contains(key)
        {
            return false
        }
        return true
    }

    /// Called for every state change `SessionStore` reports.
    func handle(transition session: Session, from previous: SessionState?) {
        // Any real transition wipes the slate: Ignore lasts until the *next* transition.
        if previous != nil, session.state != previous {
            ignored.remove(session.sessionID)
            answered.remove(session.sessionID)
        }
        guard shouldOpen(for: session, from: previous) else { return }
        enqueue(AttentionItem(session: session, trigger: session.state))
    }

    private func enqueue(_ item: AttentionItem) {
        if let index = queue.firstIndex(where: { $0.id == item.id }) {
            let previousTrigger = queue[index].trigger
            queue[index].session = item.session
            queue[index].trigger = item.trigger
            // Cards lane bug fix, 2026-09-06: a card already in the queue that flips trigger in
            // place (needs_you -> done, or back) used to leave `expiresAt`/the seen-done set
            // exactly as they were — a `needs_you` card that finished never got the 30-minute
            // expiry (SPEC §17.11) or the show-once dedupe (`markSeenDone`), so it sat forever
            // and could reopen after a restart. Only a real flip triggers this: the no-op case
            // (the same trigger reported again) must not restart the clock or re-mark the key.
            if item.trigger != previousTrigger {
                switch item.trigger {
                case .done:
                    queue[index].expiresAt = clock().addingTimeInterval(AttentionCoordinator.doneExpiry)
                    if let key = queue[index].doneKey { markSeenDone(key) }
                case .needsYou:
                    // needs_you carries no queue-owned TTL at all (see `AttentionItem.expiresAt`).
                    queue[index].expiresAt = nil
                default:
                    break
                }
            }
            return
        }
        guard queue.count < AttentionCoordinator.maxQueue else { return }
        var item = item
        item.openedAt = clock()
        if item.trigger == .done {
            item.expiresAt = item.openedAt.addingTimeInterval(AttentionCoordinator.doneExpiry)
            if let key = item.doneKey { markSeenDone(key) }
        }
        queue.append(item)
    }

    private func markSeenDone(_ key: String) {
        guard seenDoneKeySet.insert(key).inserted else { return }
        seenDoneKeys.append(key)
        if seenDoneKeys.count > AttentionCoordinator.maxSeenDoneKeys {
            seenDoneKeySet.remove(seenDoneKeys.removeFirst())
        }
    }

    /// Refreshes the queued snapshots from the live list and drops the cards whose session has
    /// left the state that opened them, or vanished (SPEC §11.4).
    func apply(sessions: [Session]) {
        guard !queue.isEmpty else { return }
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionID, $0) })
        var next: [AttentionItem] = []
        next.reserveCapacity(queue.count)
        for item in queue {
            guard let session = byID[item.id] else { continue }
            guard session.state == item.trigger else { continue }
            var updated = item
            updated.session = session
            next.append(updated)
        }
        if next != queue { queue = next }
    }

    /// Cards lane, 2026-09-04: drops every `done` card whose 30-minute clock (or its 5-minute
    /// typing extension) has run out — silently, no answer-log entry, no notification. The one on
    /// screen (`queue.first`) is spared the pull only while `isTypingInCurrent` is true: extended
    /// by 5 minutes instead of dropped. A `needs_you` card is never touched here — it has no
    /// `expiresAt` to compare against. Returns whether anything actually changed, so a caller
    /// need not diff the queue itself.
    @discardableResult
    func expireDoneCards(isTypingInCurrent: Bool = false) -> Bool {
        guard !queue.isEmpty else { return false }
        let now = clock()
        var changed = false
        var kept: [AttentionItem] = []
        kept.reserveCapacity(queue.count)
        for (index, item) in queue.enumerated() {
            guard item.trigger == .done, let expiresAt = item.expiresAt, now >= expiresAt else {
                kept.append(item)
                continue
            }
            if index == 0, isTypingInCurrent {
                var extended = item
                extended.expiresAt = now.addingTimeInterval(AttentionCoordinator.typingExtension)
                kept.append(extended)
                changed = true
                continue
            }
            changed = true // dropped: expired, silently, no audit line and no notification
        }
        if changed { queue = kept }
        return changed
    }

    // MARK: - Dismissal

    /// Escape and the Ignore button: gone until this session transitions again.
    func ignoreCurrent() {
        guard let item = current else { return }
        ignored.insert(item.id)
        queue.removeFirst()
    }

    /// Answered, sent or copied — the card is done with, but a later transition may reopen one.
    func dismissCurrent() {
        guard !queue.isEmpty else { return }
        answered.insert(queue[0].id)
        queue.removeFirst()
    }

    func dismiss(sessionID: String) {
        queue.removeAll { $0.id == sessionID }
    }

    func closeAll() {
        queue.removeAll()
    }

    /// Test seam: open a card without waiting for a transition.
    func present(_ session: Session) {
        enqueue(AttentionItem(session: session, trigger: session.state))
    }

    var isIgnored: (String) -> Bool { { [ignored] id in ignored.contains(id) } }
}
