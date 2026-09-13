import Foundation

/// SPEC §17.3: the state chips under the tabs. `running` sessions — discovered without hooks —
/// have no chip of their own; they count as `working`, which is the closer of the two states an
/// active-but-unreported session actually is.
enum StateFilter: String, CaseIterable, Codable, Identifiable {
    case needsYou = "needs_you"
    case working
    case done
    case idle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .needsYou: return "Needs you"
        case .working: return "Working"
        case .done: return "Finished"
        case .idle: return "Idle"
        }
    }

    static func of(_ state: SessionState) -> StateFilter {
        switch state {
        case .needsYou: return .needsYou
        case .done: return .done
        case .working, .running: return .working
        case .idle: return .idle
        }
    }

    /// A held session (SPEC: "on hold") counts and filters as idle, whatever state the reporter
    /// last sent — `needs_you` always wins (`isEffectivelyHeld`), so this can never hide one of
    /// those.
    static func of(_ session: Session) -> StateFilter {
        session.isEffectivelyHeld ? .idle : of(session.state)
    }
}

/// SPEC §17.3: how the sessions tab orders its rows. Every mode's secondary key is the state
/// order (SPEC §8.2) that `Session.sorted` already put the list in, so a stable sort on the
/// primary key alone is enough to keep it — nothing here has to re-derive needs_you-oldest-first
/// or done-newest-first.
enum SessionOrder: String, CaseIterable, Codable {
    /// Today's order, unchanged: needs_you → done → working → running → idle.
    case state
    case activity
    case project
    case pinned

    var label: String {
        switch self {
        case .state: return "By state"
        case .activity: return "By activity"
        case .project: return "By project"
        case .pinned: return "Pinned first"
        }
    }
}

/// Pure filtering and sorting for the sessions tab (SPEC §17.3), kept out of `AppState` so it is
/// testable without a window — a plain function of a session list and a few settings values.
enum SessionFilter {
    /// Which of the state chips a session belongs to. An empty set means "All" — nothing is
    /// filtered out.
    static func matches(_ session: Session, states: Set<StateFilter>) -> Bool {
        states.isEmpty || states.contains(StateFilter.of(session))
    }

    /// An empty set means every host passes — the popover's "nothing narrowed" state.
    static func matches(_ session: Session, hosts: Set<SessionHost>) -> Bool {
        hosts.isEmpty || hosts.contains(session.host)
    }

    /// The rows the panel actually draws: both filters applied, then ordered.
    static func apply(
        _ sessions: [Session],
        states: Set<StateFilter>,
        hosts: Set<SessionHost>,
        order: SessionOrder,
        pinned: Set<String>
    ) -> [Session] {
        let filtered = sessions.filter {
            matches($0, states: states) && matches($0, hosts: hosts)
        }
        return sorted(filtered, order: order, pinned: pinned)
    }

    /// SPEC §17.3: `sessions` arrives already in the §8.2 state order, which is exactly what
    /// `.state` wants and every other order's own secondary key — so a *stable* sort on the
    /// primary key is the whole implementation.
    static func sorted(_ sessions: [Session], order: SessionOrder, pinned: Set<String>) -> [Session] {
        switch order {
        case .state:
            return sessions
        case .activity:
            return sessions.lookoutStableSorted {
                activityDate($0) > activityDate($1)
            }
        case .project:
            return sessions.lookoutStableSorted {
                $0.project.localizedCaseInsensitiveCompare($1.project) == .orderedAscending
            }
        case .pinned:
            return sessions.lookoutStableSorted {
                pinned.contains($0.sessionID) && !pinned.contains($1.sessionID)
            }
        }
    }

    private static func activityDate(_ session: Session) -> Date {
        session.updatedAt ?? session.stateSince ?? session.startedAt ?? .distantPast
    }

    /// `showing 4 of 13` (SPEC §17.3) — nil when no filter is hiding anything, so the header
    /// keeps its plain summary.
    static func summary(shown: Int, total: Int) -> String? {
        guard shown != total else { return nil }
        return "showing \(shown) of \(total)"
    }
}

extension Array {
    /// `sort(by:)` is not documented stable; every `SessionOrder` wants ties to keep the order
    /// they arrived in (which is the §8.2 state order), so every custom order goes through this
    /// instead of the standard library's sort.
    func lookoutStableSorted(by areInIncreasingOrder: (Element, Element) -> Bool) -> [Element] {
        enumerated()
            .sorted { left, right in
                if areInIncreasingOrder(left.element, right.element) { return true }
                if areInIncreasingOrder(right.element, left.element) { return false }
                return left.offset < right.offset
            }
            .map(\.element)
    }
}
