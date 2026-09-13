import Foundation

/// One line of `~/.lookout/history.jsonl` (SPEC §17.5): a single state transition the reporter
/// logged. Decoding is as tolerant as `Session`'s — every field but `session_id` may be missing,
/// and a malformed line is simply skipped rather than taking the whole read down.
struct HistoryEntry: Identifiable, Equatable {
    var ts: Date
    var agent: SessionAgent
    var sessionID: String
    var project: String?
    var name: String?
    var from: String?
    var to: String?
    var reason: String?
    var detail: String?
    var lastMessage: String?
    /// Position in the file, oldest first — the only thing that tells two lines with the same
    /// whole-second `ts` apart, and what keeps `id` unique.
    var index: Int = 0

    var id: String { "\(sessionID)#\(index)" }

    /// One `history.jsonl` line. `nil` when the line has no `session_id` at all — the one field
    /// the reporter always writes.
    static func decode(_ line: String, index: Int) -> HistoryEntry? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = object["session_id"] as? String, !sessionID.isEmpty
        else { return nil }
        let ts = (object["ts"] as? String).flatMap(ISO8601.date) ?? .distantPast
        return HistoryEntry(
            ts: ts,
            agent: SessionAgent(raw: object["agent"] as? String),
            sessionID: sessionID,
            project: object["project"] as? String,
            name: object["name"] as? String,
            from: object["from"] as? String,
            to: object["to"] as? String,
            reason: object["reason"] as? String,
            detail: object["detail"] as? String,
            lastMessage: object["last_message"] as? String,
            index: index
        )
    }
}

extension HistoryEntry {
    /// `Bash` out of `Bash: rm -rf build` — the same convention `Session.detailTool` uses for a
    /// live row, so the two vocabularies read as one language.
    var detailTool: String? {
        guard let detail, !detail.isEmpty else { return nil }
        let parts = detail.split(separator: ":", maxSplits: 1)
        // Both halves have to be there, exactly as `detailArgument` insists. Without this the
        // split hands back the whole detail as a "tool name", `statusLabel` swells to the full
        // 120-character detail, and the row draws that at its intrinsic width — which is how a
        // row ended up wider than the panel, clipped at both edges.
        guard parts.count == 2, let head = parts.first else { return nil }
        let tool = head.trimmingCharacters(in: .whitespaces)
        return tool.isEmpty ? nil : tool
    }

    /// `rm -rf build` out of `Bash: rm -rf build`.
    var detailArgument: String? {
        guard let detail, !detail.isEmpty else { return nil }
        let parts = detail.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let argument = parts[1].trimmingCharacters(in: .whitespaces)
        return argument.isEmpty ? nil : argument
    }

    /// `working → needs_you (permission)` — the row's literal "what happened", read straight off
    /// the reporter's own `from`/`to`/`reason` fields.
    var transitionLabel: String {
        let fromText = Session.text(from)?.replacingOccurrences(of: "_", with: " ") ?? "start"
        let toText = Session.text(to)?.replacingOccurrences(of: "_", with: " ") ?? "?"
        var text = "\(fromText) → \(toText)"
        if let reason = Session.text(reason) { text += " (\(reason))" }
        return text
    }

    /// `project — name`, whichever half exists; the session id when neither does.
    var displayLabel: String {
        let projectText = Session.text(project)
        let nameText = Session.text(name)
        switch (projectText, nameText) {
        case let (p?, n?) where p != n: return "\(p) — \(n)"
        case let (p?, _): return p
        case let (_, n?): return n
        default: return sessionID
        }
    }

    /// The row's tooltip: everything the two visible lines had to leave out.
    var tooltip: String {
        var lines = [displayLabel, transitionLabel]
        if let detail = Session.text(detail) { lines.append(detail) }
        if let lastMessage = Session.text(lastMessage) { lines.append(lastMessage) }
        lines.append("Session \(sessionID)")
        return lines.joined(separator: "\n")
    }
}

/// SPEC §17.5's four filter chips. `running`/`working`/`idle` transitions that are none of these
/// still show up in the unfiltered list — they just do not belong to any chip.
enum HistoryFilter: String, CaseIterable, Identifiable {
    case needsYou = "needs_you"
    case done
    case started
    case ended

    var id: String { rawValue }

    var label: String {
        switch self {
        case .needsYou: return "Needs you"
        case .done: return "Finished"
        case .started: return "Started"
        case .ended: return "Ended"
        }
    }

    /// `reason == "session_start"` is what the reporter writes on every session's very first
    /// history line (SPEC §4's `SessionStart → idle / session_start`), whatever `from`/`to` say,
    /// so it is a more reliable "Started" test than `from == nil` alone.
    static func of(_ entry: HistoryEntry) -> HistoryFilter? {
        if entry.to == "ended" { return .ended }
        if entry.reason == "session_start" { return .started }
        if entry.to == "needs_you" { return .needsYou }
        if entry.to == "done" { return .done }
        return nil
    }
}

/// One calendar day's worth of history rows, newest day first.
struct HistoryDayGroup: Identifiable, Equatable {
    let day: Date
    let entries: [HistoryEntry]

    var id: Date { day }
}

/// Pure parsing, filtering, search and grouping (SPEC §17.5) — no AppKit, no SwiftUI, so every
/// rule here is testable against plain strings and arrays.
enum HistoryStore {
    /// SPEC §17.5: "cap 500 rows in memory".
    static let rowCap = 500
    /// SPEC §17.5: "keeps the last 7 days in memory".
    static let retentionDays = 7

    /// Reads `history.jsonl` and its one rotated predecessor `history.1.jsonl` (SPEC §17.5),
    /// newest entry first, capped at `rowCap` and to the last `retentionDays` days. Missing files
    /// read as empty — a session that has never opened History has neither.
    static func load(home: LookoutHome, now: Date = Date()) -> [HistoryEntry] {
        // Both files are append-only, oldest line first; `.1` holds whatever the reporter rotated
        // out of the live file, so it is strictly older than everything in `history.jsonl`.
        let rotated = lines(at: home.root.appendingPathComponent("history.1.jsonl"))
        let current = lines(at: home.root.appendingPathComponent("history.jsonl"))

        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        var entries: [HistoryEntry] = []
        entries.reserveCapacity(min(rotated.count + current.count, rowCap))
        var index = 0
        for line in rotated + current {
            index += 1
            guard let entry = HistoryEntry.decode(line, index: index), entry.ts >= cutoff
            else { continue }
            entries.append(entry)
        }

        entries.sort { $0.ts == $1.ts ? $0.index > $1.index : $0.ts > $1.ts }
        if entries.count > rowCap { entries.removeLast(entries.count - rowCap) }
        return entries
    }

    private static func lines(at url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Project, name, detail or the last message — whichever one has the query in it.
    static func search(_ entries: [HistoryEntry], query: String) -> [HistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter { entry in
            [entry.project, entry.name, entry.detail, entry.lastMessage]
                .compactMap { $0 }
                .contains { $0.lowercased().contains(needle) }
        }
    }

    /// An empty set means "All" — nothing is filtered out, exactly like `SessionFilter`'s state
    /// chips (SPEC §17.3), which this row reuses the convention from.
    static func filtered(_ entries: [HistoryEntry], kinds: Set<HistoryFilter>) -> [HistoryEntry] {
        guard !kinds.isEmpty else { return entries }
        return entries.filter { entry in
            guard let kind = HistoryFilter.of(entry) else { return false }
            return kinds.contains(kind)
        }
    }

    /// Both together — what the tab actually shows before grouping.
    static func apply(
        _ entries: [HistoryEntry], filters: Set<HistoryFilter>, search query: String
    ) -> [HistoryEntry] {
        search(filtered(entries, kinds: filters), query: query)
    }

    /// Groups already-sorted (newest first) entries by calendar day, day order preserved from
    /// first sight — which, since the input is newest first, means newest day first.
    static func grouped(_ entries: [HistoryEntry], calendar: Calendar = .current) -> [HistoryDayGroup] {
        var order: [Date] = []
        var buckets: [Date: [HistoryEntry]] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.ts)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(entry)
        }
        return order.map { HistoryDayGroup(day: $0, entries: buckets[$0] ?? []) }
    }
}
