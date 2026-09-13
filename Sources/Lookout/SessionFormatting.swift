import Foundation

/// One live sub-agent plus the session that spawned it — the Agents tab's row model (SPEC
/// §12.3). The parent comes along whole, because the row shows its project, its host chip and
/// jumps to it.
struct LiveSubagent: Identifiable, Equatable {
    let subagent: Subagent
    let session: Session
    /// Index of the parent in the display-sorted session list, and of this entry within it.
    let sessionOrder: Int
    let position: Int

    var id: String {
        let key = subagent.id.isEmpty ? "#\(position)" : subagent.id
        return "\(session.sessionID)/\(key)"
    }

    /// Line 1, semibold: what it is doing, or failing that what it is (SPEC §12.3).
    var headline: String {
        Session.text(subagent.description)
            ?? Session.text(subagent.type)
            ?? "Sub-agent"
    }

    /// The chip beside the headline: the model when there is one, else the type — never both,
    /// the row has one chip's worth of room.
    var chip: String? {
        if let model = Session.modelDisplayName(subagent.model) { return model }
        guard let type = Session.text(subagent.type) else { return nil }
        return Session.truncate(type, to: Session.modelDisplayLimit)
    }

    var chipTooltip: String { subagent.summary }

    /// SPEC §15.4: line 2 names the parent session. A two-line row has room for one label, so
    /// the custom name takes the project's place when there is one and nothing else changes.
    var parentLabel: String { session.displayLabel }

    /// Seconds since it started; zero when the reporter recorded no start time.
    func elapsed(now: Date = Date()) -> TimeInterval {
        guard let started = subagent.startedAt else { return 0 }
        return max(0, now.timeIntervalSince(started))
    }

    var hasElapsed: Bool { subagent.startedAt != nil }

    /// `general-purpose · sonnet · /Users/…/worktrees/fe2` — the row's tooltip.
    var tooltip: String {
        var lines = [subagent.summary, "Session \(session.project)"]
        if let cwd = Session.text(subagent.cwd) { lines.append(cwd) }
        return lines.joined(separator: "\n")
    }
}

/// ISO-8601 in two flavours: with fractional seconds (the usage API) and without (the reporter).
enum ISO8601 {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return fractional.date(from: trimmed) ?? plain.date(from: trimmed)
    }

    static func string(_ date: Date) -> String {
        plain.string(from: date)
    }
}

/// `48s`, `3m`, `1h 12m` — the compact spellings the rows and usage cards use.
enum Format {
    /// `/Users/you/Desktop/x` → `~/Desktop/x`. A row has no width for the home prefix.
    static func tildePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.rounded()))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}
