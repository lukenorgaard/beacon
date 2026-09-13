import AppKit
import Combine
import Foundation

extension AppState {
    // MARK: - Summary

    var needsYouCount: Int { allSessions.filter { $0.state == .needsYou }.count }
    // On hold: excluded from the header's counts and the status item's while held (a held
    // session is never `needs_you` — `SessionHold` clears the hold outright, so that count needs
    // no filter of its own).
    var workingCount: Int { allSessions.filter { $0.state == .working && !$0.isHeld }.count }
    var unseenDoneCount: Int { seen.unseenDone(in: allSessions).filter { !$0.isHeld }.count }

    /// `9 agents · 7 claude · 2 codex` (SPEC §8.2).
    var summaryText: String { Session.summary(allSessions) }

    /// Header line 1: `10 agents`. Line 2: `8 claude · 2 codex · 5 sub-agents` (empty when there
    /// is nothing to break down).
    var summaryHeadline: String {
        summaryText.components(separatedBy: " · ").first ?? summaryText
    }
    /// SPEC §17.3: `showing 4 of 13` once a chip or the host popover hides rows, else the usual
    /// `8 claude · 2 codex · 5 sub-agents` breakdown — with SPEC §19.2's `· 2 to compact` after
    /// it whenever any session is over the threshold, and nothing extra when none is.
    var summaryDetail: String {
        Session.appendingToCompact(
            filterSummary ?? Session.detail(allSessions), count: toCompactCount
        )
    }

    /// SPEC §19.2: how many sessions are showing a red context chip. Counted over
    /// `allSessions` — the reporter deletes a session's state file when it ends, so nothing that
    /// has ended is in there — and over every live one regardless of the filter chips, because
    /// the header's other counts work the same way. A held session counts: §19.2 keeps its chip,
    /// and it may well be the one to compact.
    var toCompactCount: Int {
        allSessions.filter {
            $0.contextGauge(windows: settings.contextWindows)?
                .isOverThreshold(settings.contextWarnFraction) ?? false
        }.count
    }

    /// The same line, said shorter. Header line 2 shares its row with the usage summary now
    /// (SPEC §18.3, after the owner's review), and when the two do not both fit it is the *counts*
    /// that give way — first by dropping the long word, only then by truncating. `24 sub-agents`
    /// becomes `24 subs`; nothing else about the line changes.
    static func compactDetail(_ detail: String) -> String {
        detail
            .replacingOccurrences(of: " sub-agents", with: " subs")
            .replacingOccurrences(of: " sub-agent", with: " sub")
    }

    /// Every live sub-agent across every session (SPEC §9.3).
    var subagentCount: Int { Session.subagentCount(allSessions) }

    // MARK: - Sorting and filtering (SPEC §17.3)

    /// Nil when nothing is hiding rows — the status item's own counts are unaffected either way,
    /// since they read `allSessions`, never `visibleSessions`.
    var filterSummary: String? {
        SessionFilter.summary(shown: visibleSessions.count, total: idleFilteredCount)
    }

    func isPinned(_ session: Session) -> Bool { settings.isPinned(session.sessionID) }

    func togglePin(for session: Session) {
        settings.togglePin(session.sessionID)
        objectWillChange.send()
    }

    // MARK: - On hold (manual override)

    /// The decorated flag `apply()` already worked out — sort, the filter chips and the row's
    /// own "On hold" label all read this, never `Settings.heldSessions` directly.
    func isHeld(_ session: Session) -> Bool { session.isEffectivelyHeld }

    /// The row's "Put on hold" / "Resume" toggle (next to Pin to top). Resuming removes the
    /// entry outright rather than leaving a stale timestamp `SessionHold` would have to reason
    /// about later.
    func toggleHold(for session: Session) {
        if settings.heldSessions[session.sessionID] != nil {
            settings.heldSessions.removeValue(forKey: session.sessionID)
        } else {
            settings.heldSessions[session.sessionID] = Date()
        }
        objectWillChange.send()
    }

    /// SPEC §17.2's ⌃⌥J: needs_you oldest first, else the newest `done`. `allSessions` already
    /// carries the §8.2 order (needs_you oldest-first, then done newest-first), so the session
    /// this hotkey wants is simply the first row that is one or the other.
    var longestWaitingSession: Session? {
        allSessions.first { $0.state == .needsYou || $0.state == .done }
    }

    /// SPEC §17.2's ⌃⌥R fallback: the top `needs_you` session, for opening a card when none is
    /// showing.
    var topNeedsYouSession: Session? {
        allSessions.first { $0.state == .needsYou }
    }

    // MARK: - Cards (SPEC §11.4)

    /// Never prune the per-session card choices against an empty list: the store publishes one
    /// before its first read, and pruning then would throw every choice away at launch.
    static func shouldPrune(_ sessions: [Session]) -> Bool { !sessions.isEmpty }

    /// The row's right-click menu item, and the per-session list in Settings.
    func cardsEnabled(for session: Session) -> Bool {
        settings.cardsEnabled(for: session.sessionID)
    }

    func toggleCards(for session: Session) {
        settings.setCards(!cardsEnabled(for: session), for: session.sessionID)
        objectWillChange.send()
    }

    // MARK: - Rename (SPEC §15.4)

    /// The row's `Rename…`. `rowFrame` is SwiftUI's `.global` rect for that row, which is what
    /// puts the panel beside the row it is about rather than in the middle of the screen.
    func beginRename(_ session: Session, rowFrame: CGRect) {
        renameTarget = RenameTarget(session: session, rowFrame: rowFrame)
    }

    func endRename() {
        guard renameTarget != nil else { return }
        renameTarget = nil
    }

    // MARK: - Tabs

    /// History behind a switch: keeps `tab` valid the moment the setting turns History off while
    /// it is selected. Internal, not private, so a test can call it directly without `start()`
    /// (see `refreshCodexUsage()` for why that matters here); wired to `settings.$showHistoryTab`
    /// there for the live app.
    func resolveTabIfNeeded() {
        if tab == .history, !settings.showHistoryTab { tab = .sessions }
        // SPEC §18.5: a tab that is no longer in its own strip cannot stay selected.
        if tab == .sentinel, !settings.sentinelEnabled { tab = .sessions }
    }
}
