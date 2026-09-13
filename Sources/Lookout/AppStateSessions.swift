import AppKit
import Combine
import Foundation

extension AppState {
    /// Bug fix (2026-09-04): a minute is plenty of resolution for a rule measured in hours —
    /// see `staleTicker`'s own doc comment for why `apply()` needs a clock of its own at all.
    func startStaleTicker() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.apply(self.rawSessions)
        }
        timer.resume()
        staleTicker = timer
    }

    /// Internal rather than private so a headless test can drive the on-hold sweep, the sort and
    /// the counts directly (see `refreshCodexUsage()` for why `start()` is not an option there).
    func apply(_ raw: [Session]) {
        rawSessions = raw
        // SPEC §15.4: names follow pid merges, stamps stay fresh, 30-day-old entries go — then
        // every row downstream reads one property and none of them knows this store exists.
        names.observe(raw)
        var sessions = names.decorate(raw)

        // Bug fix (2026-09-04): Codex has no hook for a question in its TUI, so the watcher has
        // to find one itself — fed the *hook-driven* state here, before any decoration (its own
        // `isNeedsYouByHook` doc comment says why), so it keeps checking a session exactly until
        // the hook itself says needs_you, never blinding itself to its own decoration below.
        let codexCandidates = sessions.compactMap { session -> CodexQuestionCandidate? in
            guard session.agent == .codex, let path = Session.text(session.transcriptPath) else {
                return nil
            }
            return CodexQuestionCandidate(
                sessionID: session.sessionID, transcriptPath: path,
                isNeedsYouByHook: session.state == .needsYou
            )
        }
        codexQuestions.observe(codexCandidates)
        // Ahead of `StaleBackground`: a Codex session stuck at working/background because the
        // question that would explain it never got a hook is exactly the bug this exists to fix,
        // so an open question must win over "looks stale" — not the other way round.
        sessions = sessions.map { CodexQuestionDecoration.decorate($0, questions: codexQuestions.questions) }

        // Bug fix (2026-09-04): a session stuck at working/background for 2h+ (the reporter
        // hung waiting on a task that never came back) is decorated to look exactly like a real
        // `done` session — sort, the header/status counts, `statusLabel`, the notification and
        // the card all read this copy, never the raw one, and the file on disk is never touched
        // (see `StaleBackground`, the same shape as `Session.isHeld`'s override below).
        sessions = sessions.map { StaleBackground.decorate($0) }

        // On hold: sweep every held session against `SessionHold`'s auto-clear rule before
        // anything downstream reads `isHeld` — a session that started a fresh turn, or that
        // needs the owner outright, is not held any more (needs_you always wins and clears it).
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionID, $0) })
        for (id, since) in settings.heldSessions {
            guard let session = byID[id] else { continue }
            if SessionHold.shouldClear(session: session, heldSince: since) {
                settings.heldSessions.removeValue(forKey: id)
            }
        }
        sessions = sessions.map { session in
            var session = session
            session.isHeld = settings.heldSessions[session.sessionID] != nil
            return session
        }
        // A held session sorts below idle (`SessionState.heldSortRank`), which `Session.sorted`
        // only knows once `isHeld` is on the record — re-run it now that it is.
        sessions = Session.sorted(sessions)

        allSessions = sessions
        // On hold is treated like idle (SPEC: "no — treat held like idle"): hidden right along
        // with it when idle sessions are hidden.
        let idleFiltered = settings.showIdle
            ? sessions
            : sessions.filter { $0.state != .idle && !$0.isHeld }
        idleFilteredCount = idleFiltered.count
        // SPEC §17.3: the chips, the host popover and the order — what the panel actually draws.
        visibleSessions = SessionFilter.apply(
            idleFiltered,
            states: settings.filterStates, hosts: settings.filterHosts,
            order: settings.sessionOrder, pinned: settings.pinnedSessions
        )
        subagents = Session.liveSubagents(sessions)
        seen.reconcile(with: sessions)
        // Bug fix (2026-09-04): a session that only just crossed into `StaleBackground`'s
        // decorated `done` gets the same one-time notification and card a real `Stop` would —
        // `staleNotified` is what keeps the ticker above from reopening a card the user already
        // dismissed every time it fires.
        notifyNewlyStaleBackground(sessions)
        // Bug fix (2026-09-04): same one-shot shape, for a Codex session `CodexQuestionDecoration`
        // just turned needs_you — nothing on disk changed, so `store.onTransition` never fires
        // for it on its own.
        notifyNewlyOpenCodexQuestions(sessions)
        // A card closes by itself when its session leaves the state that opened it (SPEC §11.4).
        attention.apply(sessions: sessions)
        if AppState.shouldPrune(sessions) {
            let ids = Set(sessions.map(\.sessionID))
            settings.pruneCardOverrides(keeping: ids)
            settings.prunePinned(keeping: ids)
            settings.pruneHeld(keeping: ids)
        }
        // SPEC §11.3 bug fix (2026-09-04): garbage-collects `~/.lookout/requests/*.json` — an
        // orphan the reporter forgot to delete (the session it was about moved on hours ago, or
        // ended outright) — at the same cadence sessions themselves refresh. Off the main thread;
        // `pruneOrphans` only ever touches files under `requests`, reading `sessions` merely to
        // check one exists.
        let requestsStore = requests
        DispatchQueue.global(qos: .utility).async { requestsStore.pruneOrphans() }
    }

    /// Bug fix (2026-09-04): opens the same one-shot notification/card a real `Stop` would for
    /// every session that only just became `StaleBackground`-stale, and never repeats it for a
    /// session still stale on the next tick — `AttentionCoordinator` has no memory of "already
    /// asked and dismissed" on its own; every call here would otherwise read as a fresh
    /// `working` → `done` transition and reopen a card the user just closed.
    private func notifyNewlyStaleBackground(_ sessions: [Session]) {
        let currentlyStale = Set(
            sessions
                .filter { $0.detail == StaleBackground.detail && !$0.isHeld }
                .map(\.sessionID)
        )
        for id in currentlyStale.subtracting(staleNotified) {
            guard let session = sessions.first(where: { $0.sessionID == id }) else { continue }
            if settings.notifyDone { notifier.notify(session) }
            attention.handle(transition: session, from: .working)
        }
        staleNotified = currentlyStale
    }

    /// Bug fix (2026-09-04): opens the same one-shot notification/card a real hook-driven
    /// `needs_you` transition would for every Codex session `CodexQuestionDecoration` just turned
    /// needs_you — deduped on the call id (not just the session id), so a *second* question
    /// replacing the first in the same still-`needs_you` session notifies again, exactly like a
    /// fresh `AskUserQuestion` would for Claude.
    private func notifyNewlyOpenCodexQuestions(_ sessions: [Session]) {
        var current: [String: String] = [:] // sessionID -> callID
        for session in sessions where session.agent == .codex && session.reason == "question" {
            guard let question = codexQuestions.questions[session.sessionID] else { continue }
            current[session.sessionID] = question.callID
        }
        for (sessionID, callID) in current where codexQuestionNotified[sessionID] != callID {
            guard let session = sessions.first(where: { $0.sessionID == sessionID }) else {
                continue
            }
            if settings.notifyNeedsYou { notifier.notify(session) }
            attention.handle(transition: session, from: .working)
        }
        // Forgotten once the question closes, so the same call id notifying again later (a
        // session that came back) is not read as "already handled" (mirrors `staleNotified`).
        codexQuestionNotified = current
    }

    /// Bug fix (2026-09-04): the in-memory request `AttentionCardWindow.sync()` falls back to
    /// when a Codex session's card is showing only because of `CodexQuestionDecoration` — never
    /// written to disk, so a real, hook-driven `RequestStore` request for the same session always
    /// wins when both exist (tried first by the caller; see item 3's own rule).
    func codexQuestionRequest(for session: Session) -> AttentionRequest? {
        guard session.agent == .codex, session.reason == "question" else { return nil }
        guard let question = codexQuestions.questions[session.sessionID] else { return nil }
        return question.attentionRequest(session: session)
    }

    /// Internal rather than private so a headless test can drive the on-hold suppression rule
    /// directly (see `refreshCodexUsage()` for why `start()` is not an option there).
    func handle(transition raw: Session, from previous: SessionState?) {
        // On hold: a session still on hold once `SessionHold`'s auto-clear rule is applied never
        // triggers a notification or a card for a done/idle/working transition — that is the
        // whole point of holding it. `needs_you` always wins, which is exactly what clears it.
        if let since = settings.heldSessions[raw.sessionID] {
            if SessionHold.shouldClear(session: raw, heldSince: since) {
                settings.heldSessions.removeValue(forKey: raw.sessionID)
            } else {
                return
            }
        }
        // The card and the notification say the session's name, so they get the decorated row
        // and not the one straight off disk (SPEC §15.4).
        let session = names.decorate(raw)
        // SPEC §11.4: the card is a *second* channel, not a replacement for the notification.
        attention.handle(transition: session, from: previous)
        switch session.state {
        case .needsYou:
            if settings.notifyNeedsYou { notifier.notify(session) }
        case .done:
            if settings.notifyDone { notifier.notify(session) }
            // A finished turn is exactly when the usage numbers moved (SPEC §5.3).
            usage.refreshAfterStop()
        default:
            break
        }
    }
}
