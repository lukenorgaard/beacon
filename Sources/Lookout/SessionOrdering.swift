import Foundation

extension Session {
    // MARK: - Ordering

    /// SPEC §8.2: needs_you (oldest first) → done (newest first) → working → running → idle →
    /// held (a manual override, sorting below even idle — see `Session.sortRank`).
    /// Within `working`, `running` and `idle` — unspecified — most recently changed first.
    static func sorted(_ sessions: [Session]) -> [Session] {
        sessions.sorted { a, b in
            if a.sortRank != b.sortRank { return a.sortRank < b.sortRank }
            let left = a.stateSince ?? a.updatedAt ?? .distantPast
            let right = b.stateSince ?? b.updatedAt ?? .distantPast
            if left != right {
                return a.state == .needsYou ? left < right : left > right
            }
            return a.sessionID < b.sessionID
        }
    }

    /// Every live sub-agent across every session (SPEC §9.3).
    static func subagentCount(_ sessions: [Session]) -> Int {
        sessions.reduce(0) { $0 + $1.subagents.count }
    }

    /// Header row 2: `12 claude · 1 codex · 27 sub-agents` — in words, no symbol (SPEC §12.3).
    /// It gets the panel's full width now, which is what the symbol shorthand was working
    /// around; on one full-width line the words fit and read better.
    static func detail(_ sessions: [Session]) -> String {
        let components = summary(sessions).components(separatedBy: " · ")
        var parts = Array(components.dropFirst())
        let count = subagentCount(sessions)
        if count > 0 { parts.append("\(count) \(count == 1 ? "sub-agent" : "sub-agents")") }
        return parts.joined(separator: " · ")
    }

    /// SPEC §19.2: `8 claude · 2 codex · 2 to compact` — the header detail with the number of
    /// sessions whose context chip is over the threshold appended, and nothing at all appended
    /// when that number is zero. Kept next to `detail(_:)` because it is the same line: the
    /// counts are composed there, and this is the only thing §19 adds to them.
    static func appendingToCompact(_ detail: String, count: Int) -> String {
        guard count > 0 else { return detail }
        let phrase = "\(count) to compact"
        return detail.isEmpty ? phrase : detail + " · " + phrase
    }

    /// Every live sub-agent, flattened, in the Agents tab's order: parent session order first
    /// (the list is already sorted for display), then start time (SPEC §12.3).
    static func liveSubagents(_ sessions: [Session]) -> [LiveSubagent] {
        var result: [LiveSubagent] = []
        for (index, session) in sessions.enumerated() {
            let sorted = session.subagents.enumerated().sorted { left, right in
                let a = left.element.startedAt ?? .distantFuture
                let b = right.element.startedAt ?? .distantFuture
                if a != b { return a < b }
                return left.offset < right.offset
            }
            for (position, entry) in sorted.enumerated() {
                result.append(
                    LiveSubagent(
                        subagent: entry.element, session: session,
                        sessionOrder: index, position: position
                    )
                )
            }
        }
        return result
    }

    /// SPEC §9.1: a hook-reported file always beats a discovered row for the same session —
    /// matched by `session_id` *or* by pid, because a discovered row now carries the real id
    /// as often as not.
    static func merge(files: [Session], discovered: [Session]) -> [Session] {
        var ids = Set(files.map(\.sessionID))
        var pids = Set(files.compactMap(\.pid))

        var result = files
        result.reserveCapacity(files.count + discovered.count)
        for session in discovered {
            if ids.contains(session.sessionID) { continue }
            if let pid = session.pid, pids.contains(pid) { continue }
            ids.insert(session.sessionID)
            if let pid = session.pid { pids.insert(pid) }
            result.append(session)
        }
        return result
    }

    /// `9 agents · 7 claude · 2 codex` (SPEC §8.2) — every agent, whatever its name.
    static func summary(_ sessions: [Session]) -> String {
        guard !sessions.isEmpty else { return "No sessions" }
        var counts: [String: Int] = [:]
        for session in sessions { counts[session.agent.display, default: 0] += 1 }
        let noun = sessions.count == 1 ? "agent" : "agents"
        let breakdown = counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "\($0.value) \($0.key)" }
        return (["\(sessions.count) \(noun)"] + breakdown).joined(separator: " · ")
    }
}
