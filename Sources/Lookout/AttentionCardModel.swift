import AppKit
import Combine
import Foundation

/// Everything the attention card does (SPEC §11.4): it holds the editable reply, asks for a
/// suggestion, writes the answer file, sends the message, and falls back to Copy & go whenever
/// Send cannot deliver.
///
/// One long-lived object; `present(_:)` swaps the card it is about.
final class AttentionCardModel: ObservableObject {
    /// The card on screen, or nil when there is none.
    @Published private(set) var item: AttentionItem?
    /// The reporter's request for that session, when there is one (SPEC §11.3).
    @Published var request: AttentionRequest?
    /// The editable field. Never sent by itself — only a button sends.
    @Published var text: String = ""
    @Published var suggestion: String?
    @Published var isSuggesting = false
    /// SPEC §13.2: `Claude unavailable → heuristic`, shown on the status line under the buttons
    /// when the asked-for source could not answer. Never overwrites a send/answer status.
    @Published var suggestionNote: String?
    @Published var isSending = false
    /// The one line under the buttons.
    @Published var status: String?
    @Published var statusIsError = false
    /// Set once Allow/Deny has been written; the buttons go quiet until the card closes itself.
    @Published var answered: AnswerDecision?
    /// How many more cards are waiting (SPEC §11.4's "next" chip).
    @Published var pendingCount = 0
    /// SPEC §16.3: a live companion for this session's editor, probed once when the card opens.
    /// It is what lets a Codex session inside Cursor use Send at all — §11.2's socket is Claude's
    /// alone, and the companion types into the terminal instead.
    @Published private(set) var companionAvailable = false
    /// SPEC §17.2's ⌃⌥R: a new value here is the view's cue to focus the reply field. A token
    /// rather than a `Bool` so two requests in a row (the card already open, pressed again) both
    /// take effect.
    @Published var focusRequestToken = UUID()
    /// Cards lane, 2026-09-04: set by the view whenever the reply field's own `@FocusState`
    /// changes — the other half of `isTypingOrFocused`, which keeps an about-to-expire `done`
    /// card from being pulled out from under the owner while he is looking at the field, even before
    /// he has typed a character.
    @Published var replyFieldFocused = false
    /// Cards lane, 2026-09-04: "Expires in 5m" — set only for a `done` card inside the last 5
    /// minutes of its `expiresAt`, nil otherwise (including always for `needs_you`, which has no
    /// queue-owned expiry at all). Read by the card's existing footer line, so the caption never
    /// costs it a layout jump.
    @Published var expiryCaption: String?

    let settings: Settings
    let coordinator: AttentionCoordinator
    let suggester: Suggester
    let home: LookoutHome
    var suggestionToken = UUID()
    /// Cards lane, 2026-09-04: the only production driver of `AttentionCoordinator.expireDoneCards`
    /// — the tests call that directly with an injected clock instead. Started once by the card's
    /// controller; nothing runs it in a test process, since nothing calls `start()` there.
    private var expiryTimer: DispatchSourceTimer?
    /// 15 s is plenty of resolution for a 30-minute TTL and a caption that only ever counts whole
    /// minutes.
    static let tickInterval: TimeInterval = 15

    /// Seam for the tests: none of these may run for real in a test process.
    var sender: (String, Session, @escaping (SessionMessenger.Result) -> Void) -> Void
    /// SPEC §17.7: Codex's own Send channel — `codex queue`, tried before the companion/Copy & go
    /// fallback chain, exactly the way `sender` is for Claude's messaging socket.
    var codexSender: (String, Session, @escaping (CodexQueueSender.Result) -> Void) -> Void
    var jumper: (Session) -> Void
    /// SPEC §16.3: the editor companion, tried after the socket and before Copy & go.
    var companionSender: (String, Session, @escaping (CompanionMatch?) -> Void) -> Void
    /// SPEC §16.3: is any window of this session's editor answering? File scan only, no HTTP.
    var companionProbe: (Session, @escaping (Bool) -> Void) -> Void

    init(
        settings: Settings,
        coordinator: AttentionCoordinator,
        suggester: Suggester,
        home: LookoutHome = LookoutHome()
    ) {
        self.settings = settings
        self.coordinator = coordinator
        self.suggester = suggester
        self.home = home
        self.sender = { text, session, completion in
            SessionMessenger.send(text: text, session: session, home: home, completion: completion)
        }
        self.codexSender = { text, session, completion in
            CodexQueueSender.send(text: text, session: session, home: home, completion: completion)
        }
        self.jumper = { session in Jumper.jump(to: session) }
        let companion = EditorCompanion.client(home: home)
        self.companionSender = { text, session, completion in
            DispatchQueue.global(qos: .userInitiated).async {
                let match = companion.send(text: text, session: session)
                DispatchQueue.main.async { completion(match) }
            }
        }
        self.companionProbe = { session, completion in
            guard let app = EditorCompanion.app(for: session.host) else {
                completion(false)
                return
            }
            DispatchQueue.global(qos: .utility).async {
                let live = companion.hasLiveInstance(app: app)
                DispatchQueue.main.async { completion(live) }
            }
        }
    }

    deinit {
        expiryTimer?.cancel()
    }

    /// Cards lane, 2026-09-04: starts the real-world tick that drives
    /// `AttentionCoordinator.expireDoneCards` and refreshes `expiryCaption`. Called once by
    /// `AttentionCardController`; never called in a test process, so no test pays for a live
    /// timer. Safe to call twice — the second call is a no-op.
    func start() {
        guard expiryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + AttentionCardModel.tickInterval,
            repeating: AttentionCardModel.tickInterval, leeway: .seconds(2)
        )
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        expiryTimer = timer
    }

    /// Cards lane, 2026-09-04: sweeps the coordinator's queue for an expired `done` card (or
    /// extends the one on screen while the owner is typing into it) and refreshes the countdown
    /// caption — both read the same `now` so a test can drive them in lockstep with the
    /// coordinator's own injected clock.
    func tick(now: Date = Date()) {
        _ = coordinator.expireDoneCards(isTypingInCurrent: isTypingOrFocused)
        updateExpiryCaption(now: now)
    }

    /// Cards lane, 2026-09-04: true while there is something in the reply field, or the field
    /// itself has keyboard focus — the signal that holds an about-to-expire `done` card open
    /// instead of letting it be pulled away mid-sentence.
    var isTypingOrFocused: Bool { !trimmedText.isEmpty || replyFieldFocused }

    private func updateExpiryCaption(now: Date) {
        guard let item, item.trigger == .done, let expiresAt = item.expiresAt else {
            expiryCaption = nil
            return
        }
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining > 0, remaining <= AttentionCardModel.expiryCaptionThreshold else {
            expiryCaption = nil
            return
        }
        let minutes = max(1, Int((remaining / 60).rounded(.up)))
        expiryCaption = "Expires in \(minutes)m"
    }

    /// Only inside the last 5 minutes does the countdown earn a place in the footer — any
    /// earlier and it would just be noise next to the suggestion and the buttons.
    static let expiryCaptionThreshold: TimeInterval = 5 * 60

    var session: Session? { item?.session }

    /// What the "Asks" section is about, in the absence of a request file.
    var kind: SuggestionContext.Kind {
        guard let session else { return .permission }
        return SuggestionContext(session: session, request: request).kind
    }

    /// Allow/Deny exist only for a permission request that has not expired (SPEC §11.4).
    var canAnswerWithFile: Bool {
        guard let request else { return false }
        return request.isAnswerable()
    }

    /// A permission request whose wait ran out: the prompt is up in the terminal now.
    var isExpired: Bool {
        guard let request, request.kind == .permission else { return false }
        return request.isExpired()
    }

    var canSend: Bool {
        guard let session, !isSending, answered == nil else { return false }
        return canDeliver(session) && !trimmedText.isEmpty
    }

    /// SPEC §11.2's socket, SPEC §17.7's `codex queue`, or SPEC §16.3's companion — any one of
    /// them can carry a reply without moving the owner's focus, which is the whole point of Send.
    ///
    /// Bug fix 2026-09-04: none of that applies to a Codex *question* — Codex only ever takes an
    /// answer to its own `request_user_input` call from its own TUI prompt, never from `codex
    /// queue` (which starts a new turn, not an answer) or the companion, so Send has nothing to
    /// deliver into and is off outright, whatever channel would otherwise be available.
    private func canDeliver(_ session: Session) -> Bool {
        if isCodexQuestionCard { return false }
        return session.canSendMessage || session.agent == .codex || companionAvailable
    }

    var canCopy: Bool { !trimmedText.isEmpty }

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Bug fix 2026-09-04: true only for the in-memory question `CodexQuestionWatcher` built —
    /// never for a Codex permission or a plain "done" card, and never for any other agent.
    var isCodexQuestionCard: Bool {
        session?.agent == .codex && (request?.isCodexQuestion ?? false)
    }

    /// Why Send is off, for the button's tooltip.
    var sendHelp: String {
        guard let session else { return "No session" }
        if isCodexQuestionCard {
            return "Answer in the Codex terminal — Codex takes this answer only from its own prompt"
        }
        if !canDeliver(session) {
            return "\(session.agent.display) has no messaging socket — use Copy & go"
        }
        if trimmedText.isEmpty { return "Write a reply first" }
        if session.agent == .codex {
            return "Send via `codex queue` without moving focus (⌘↩)"
        }
        if !session.canSendMessage {
            return "Type it into the \(session.host.chip) terminal through the companion (⌘↩)"
        }
        return "Send into the session without moving focus (⌘↩)"
    }

    // MARK: - Presenting

    /// Swaps the card. Same session → only the snapshot refreshes, so typing survives an update.
    func present(_ item: AttentionItem?, request: AttentionRequest?) {
        let sameCard = item?.id == self.item?.id
        self.item = item
        self.request = request
        // Cards lane, 2026-09-04: even a same-card refresh can carry a new `expiresAt` (the
        // typing extension), so the caption is recomputed either way.
        updateExpiryCaption(now: Date())
        guard !sameCard else { return }

        text = ""
        suggestion = nil
        suggestionNote = nil
        status = nil
        statusIsError = false
        answered = nil
        isSending = false
        companionAvailable = false
        replyFieldFocused = false
        suggestionToken = UUID()
        guard let session = item?.session else { return }
        // The probe is a directory listing off the main thread; the button starts disabled and
        // turns on if a companion answers, never the other way round mid-card.
        companionProbe(session) { [weak self] live in
            guard let self, self.item?.session.sessionID == session.sessionID else { return }
            self.companionAvailable = live
        }
        regenerate()
    }
}
