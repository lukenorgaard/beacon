import Foundation

/// The "Put on hold" row action (the owner: "I should be able to move one to idle — one can be
/// finished or on hold where I'm just not working on it at the moment but not closing it") and
/// the one rule that lifts it again on its own.
///
/// A hold is a manual override kept in `Settings.heldSessions` (session id → the moment it was
/// held), never in the reporter's own state file — the reporter has no idea a session is held.
/// Kept as a pure function of a session and that timestamp, out of `AppState`, so the auto-clear
/// rule, the sort order and the filter chips can all ask the same question without a window
/// (mirrors `AttentionCoordinator`'s own reasoning for staying AppKit-free).
enum SessionHold {
    /// True the moment the hold no longer applies:
    /// - the session needs the owner outright (`needs_you` always wins, whatever the hold says), or
    /// - a *new* turn started after the hold (`working`, with `state_since`/`updated_at` newer
    ///   than `heldSince` — a fresh prompt).
    ///
    /// A quiet `Stop` → `done` after the hold does **not** clear it (finishing quietly is exactly
    /// what "on hold" is for), and neither does `idle` or `running` — nothing there is "activity".
    static func shouldClear(session: Session, heldSince: Date) -> Bool {
        if session.state == .needsYou { return true }
        guard session.state == .working else { return false }
        guard let activity = session.stateSince ?? session.updatedAt else { return false }
        return activity > heldSince
    }

    /// Whether a session held at `heldSince` is still on hold right now. `nil` means "never
    /// held" — the common case for every session that has no entry in `Settings.heldSessions`.
    static func isHeld(session: Session, heldSince: Date?) -> Bool {
        guard let heldSince else { return false }
        return !shouldClear(session: session, heldSince: heldSince)
    }
}
