import AppKit
import Combine
import Foundation

extension AttentionCardModel {
    // MARK: - Suggestion

    func regenerate() {
        guard let session else { return }
        let source = settings.effectiveSuggestionSource
        guard source != .off else {
            suggestion = nil
            suggestionNote = nil
            isSuggesting = false
            return
        }
        let context = SuggestionContext(session: session, request: request)
        let token = UUID()
        suggestionToken = token
        isSuggesting = true
        suggestionNote = nil
        suggester.suggest(
            for: context, source: source, model: settings.ollamaModel,
            claude: settings.claudeOptions
        ) { [weak self] outcome in
            guard let self, self.suggestionToken == token else { return }
            self.isSuggesting = false
            self.suggestion = outcome.text
            self.suggestionNote = outcome.note
        }
    }

    /// The small label beside `SUGGESTION` — `Claude · haiku` (SPEC §13.2). Nil for the sources
    /// that need no explaining.
    var suggestionSourceLabel: String? {
        switch settings.effectiveSuggestionSource {
        case .claude: return "Claude · \(settings.claudeModel)"
        case .ollama: return Session.text(settings.ollamaModel).map { "Ollama · \($0)" }
        case .heuristic, .off: return nil
        }
    }

    /// The status line: what an action last did, or — when nothing has — the "Expires in Xm"
    /// countdown on a `done` card inside its last 5 minutes, or why the suggestion is not from
    /// where it was supposed to be. Cards lane, 2026-09-04: reuses this one existing footer line
    /// (SPEC: "reserve the line or put it in the existing footer line") rather than adding a
    /// second one that would push the card taller only for the sessions that reach it.
    var statusLine: String? { status ?? expiryCaption ?? suggestionNote }

    var statusLineIsError: Bool {
        guard status == nil else { return statusIsError }
        guard expiryCaption == nil else { return false }
        return suggestionNote != nil
    }

    /// SPEC §11.4: fills the field, never sends.
    func useSuggestion() {
        guard let suggestion = Session.text(suggestion) else { return }
        text = suggestion
    }

    /// A question's option button fills the field too.
    func use(option: String) {
        text = option
    }

    /// SPEC §17.4: a preset button fills the field — like `useSuggestion`, it never sends.
    func use(preset: AnswerPreset) {
        text = preset.text
    }

    /// SPEC §17.2's ⌃⌥R.
    func requestFocus() {
        focusRequestToken = UUID()
    }

    // MARK: - Actions

    func answer(_ decision: AnswerDecision) {
        guard let session, let request, request.isAnswerable() else {
            statusIsError = true
            status = "Answer in the terminal — the request already timed out"
            return
        }
        let directory = home.answers
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: String?
            do {
                _ = try AnswerWriter.write(decision, for: request, in: directory)
            } catch {
                failure = "\(error)"
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let failure {
                    self.statusIsError = true
                    self.status = "Could not write the answer (\(failure))"
                    AnswerAudit.record(
                        session: session, channel: .answerFile,
                        outcome: "failed", text: decision.rawValue, home: self.home
                    )
                    return
                }
                self.answered = decision
                self.statusIsError = false
                self.status = "Answered · \(decision.rawValue)"
                AnswerAudit.record(
                    session: session, channel: .answerFile,
                    outcome: decision.rawValue, text: request.commandOrPath, home: self.home
                )
            }
        }
    }

    /// SPEC §11.4: Send, and on *any* failure automatically Copy & go instead.
    func send() {
        guard let session, canSend else { return }
        let payload = trimmedText
        isSending = true
        statusIsError = false
        status = "Sending…"

        // SPEC §17.7: Codex has no messaging socket at all — `codex queue` is its whole Send
        // channel, tried before the same companion/Copy & go fallback Claude's socket has.
        if session.agent == .codex {
            codexSender(payload, session) { [weak self] result in
                guard let self else { return }
                self.isSending = false
                switch result {
                case .sent:
                    self.statusIsError = false
                    self.status = "Sent · \(AttentionCardModel.clock(Date()))"
                    self.coordinator.dismissCurrent()
                case .failed(let reason):
                    self.deliverViaCompanion(session: session, payload: payload, reason: reason)
                }
            }
            return
        }

        // SPEC §16.3: no socket to try — the companion is the only channel, so the failure line
        // in `send.log` is not written for something that was never attempted.
        guard session.canSendMessage else {
            deliverViaCompanion(
                session: session, payload: payload, reason: "no messaging socket"
            )
            return
        }

        sender(payload, session) { [weak self] result in
            guard let self else { return }
            self.isSending = false
            switch result {
            case .sent:
                self.statusIsError = false
                self.status = "Sent · \(AttentionCardModel.clock(Date()))"
                AnswerAudit.record(
                    session: session, channel: .message, outcome: "sent",
                    text: payload, home: self.home
                )
                self.coordinator.dismissCurrent()
            case .failed(let reason):
                // SPEC §16.3: an editor window with a live companion can take the reply even
                // when the socket could not, so it is tried before the clipboard.
                self.deliverViaCompanion(session: session, payload: payload, reason: reason)
            }
        }
    }

    /// SPEC §16.3. Only the three companion hosts pay for this; everywhere else the fallback is
    /// still the synchronous Copy & go it has always been.
    private func deliverViaCompanion(session: Session, payload: String, reason: String) {
        guard EditorCompanion.app(for: session.host) != nil else {
            failSend(session: session, payload: payload, reason: reason)
            return
        }
        isSending = true
        companionSender(payload, session) { [weak self] match in
            guard let self else { return }
            self.isSending = false
            guard match != nil else {
                self.failSend(session: session, payload: payload, reason: reason)
                return
            }
            self.statusIsError = false
            self.status = AttentionCardModel.companionStatus
            AnswerAudit.record(
                session: session, channel: .message, outcome: "companion",
                text: payload, home: self.home
            )
            self.coordinator.dismissCurrent()
        }
    }

    /// SPEC §11.4's original fallback: the socket failed and no companion took it either.
    private func failSend(session: Session, payload: String, reason: String) {
        let target = copyAndJump(session: session, text: payload)
        statusIsError = true
        status = AttentionCardModel.failureStatus(
            reason: reason, target: target, kind: request?.kind
        )
        AnswerAudit.record(
            session: session, channel: .clipboard,
            outcome: "send-failed: \(reason)", text: payload, home: home
        )
        coordinator.dismissCurrent()
    }

    func copyAndGo() {
        guard let session else { return }
        let payload = trimmedText
        let target = copyAndJump(session: session, text: payload)
        statusIsError = false
        status = "Copied and opened \(target)"
        AnswerAudit.record(
            session: session, channel: .clipboard, outcome: "copied",
            text: payload, home: home
        )
        coordinator.dismissCurrent()
    }

    /// The expired case: nothing to copy, just land in the terminal that is waiting.
    func openSession() {
        guard let session else { return }
        jumper(session)
        AnswerAudit.record(
            session: session, channel: .clipboard, outcome: "opened", home: home
        )
        coordinator.dismissCurrent()
    }

    func ignore() {
        if let session {
            AnswerAudit.record(
                session: session, channel: .ignored, outcome: "ignored", home: home
            )
        }
        coordinator.ignoreCurrent()
    }

    /// Pasteboard first, then the jump — both on the main thread's side of the fence, with the
    /// jump itself queued off it by `Jumper` (SPEC §9.2).
    @discardableResult
    private func copyAndJump(session: Session, text: String) -> String {
        if !text.isEmpty {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        jumper(session)
        return session.host == .unknown ? "the session" : session.host.chip
    }

    /// SPEC §15.1: Send failed, so Copy & go already happened — the line says what was done and,
    /// for a `question`, what is still waiting in the terminal. A permission prompt needs no such
    /// note: the reply is the answer, and pasting it is the whole job.
    static func failureStatus(reason: String, target: String, kind: RequestKind?) -> String {
        let done = "Send failed (\(reason)) → copied and opened \(target)"
        guard kind == .question else { return done }
        return done + " — paste it into the question there"
    }

    /// SPEC §16.3: the reply went into the session's own terminal tab inside the editor.
    static let companionStatus = "Sent via companion"

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
