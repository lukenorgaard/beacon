import Foundation

/// Bug fix (2026-09-04): the reporter can leave a session parked at `working`/`background`
/// forever — Claude Code reported a live background task, the task hung, and no later hook
/// event ever arrived, even though the session's own turn actually ended (with a question)
/// hours ago. The reporter side is being fixed separately (a turn that ends with a question
/// becomes `done`); this is the app-side backstop so a session stuck this way does not sit
/// showing "Working… · 1 background task running" for the rest of the night.
///
/// A pure function of a session and "now", in exactly the shape `SessionHold` already uses for
/// its own auto-clear rule: it never touches the state file on disk, and it hands back the
/// *decorated* `Session` the rest of the app should read — sort, the header/status counts, the
/// notification and the card all go by `Session.state`/`Session.detail` alone, so decorating
/// those two fields is enough to make a stuck session behave exactly like a real `done` one
/// everywhere downstream (mirrors `Session.isHeld`'s own local-override shape).
enum StaleBackground {
    /// What the decorated `detail` reads — also the marker `AppState` uses to tell a session
    /// that only *looks* done because of this rule from one that really did stop.
    static let detail = "stale background task"

    /// Two hours parked at `working`/`background` with nothing since is long enough that the
    /// task is not coming back on its own.
    static let staleAfter: TimeInterval = 2 * 60 * 60

    /// True only for the exact shape the reporter's `Stop`-with-live-background-tasks path
    /// writes (SPEC §4's `reason` column) — a session in any other `working` reason, or any
    /// other state entirely, is never touched by this rule.
    static func isStale(session: Session, now: Date = Date()) -> Bool {
        guard session.state == .working, session.reason == "background" else { return false }
        guard let updated = session.updatedAt else { return false }
        return now.timeIntervalSince(updated) > staleAfter
    }

    /// The session `AppState` should actually show: unchanged unless `isStale`, in which case
    /// `state` becomes `.done` (so sort, the header/status counts, `statusLabel` — "Finished" —
    /// and the notification/card triggers all read it exactly like a real `done` session) and
    /// `detail` explains why. Everything else on the record, including `reason`, is left as the
    /// reporter wrote it — the original stays on disk, only this in-memory copy differs.
    static func decorate(_ session: Session, now: Date = Date()) -> Session {
        guard isStale(session: session, now: now) else { return session }
        var decorated = session
        decorated.state = .done
        decorated.detail = StaleBackground.detail
        return decorated
    }
}
