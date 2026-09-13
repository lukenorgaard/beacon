import Foundation

/// One user or assistant message from a transcript, flattened to text (SPEC §13.2).
struct TranscriptTurn: Equatable {
    var role: String
    var text: String

    var line: String { "\(role): \(text)" }
}

/// Reads the end of a Claude Code transcript (`transcript_path` in the state file, SPEC §4).
///
/// Only the tail is read — a long session's JSONL runs to megabytes, and the card wants six
/// turns. Everything that is not a plain user/assistant message is dropped: tool calls, tool
/// results and the meta lines the CLI injects are noise in a one-line suggestion.
enum TranscriptTail {
    /// SPEC §13.2: the last 64 KB.
    static let maxBytes = 64 * 1024
    /// SPEC §13.2: the last six user/assistant messages.
    static let maxTurns = 6
    /// SPEC §13.2: assistant text is cut here; a user turn is bounded by the 6 KB total instead.
    static let assistantLimit = 600

    /// Reads the tail without pulling the whole file into memory. Never on the main thread.
    static func read(path: String?, maxBytes: Int = maxBytes) -> String? {
        guard let path = Session.text(path) else { return nil }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        // A tail almost always starts mid-line; that fragment is not valid JSON anyway, and
        // `turns` skips it, but decoding is cheaper when it is gone first.
        let text = String(decoding: data, as: UTF8.self)
        guard start > 0, let newline = text.firstIndex(of: "\n") else { return text }
        return String(text[text.index(after: newline)...])
    }

    /// The last `limit` user/assistant turns in the tail, oldest first.
    static func turns(
        inTail tail: String,
        limit: Int = maxTurns,
        assistantLimit: Int = assistantLimit
    ) -> [TranscriptTurn] {
        var collected: [TranscriptTurn] = []
        // Backwards: the newest turns are the ones worth the budget, and a huge transcript tail
        // stops being parsed as soon as six are in hand.
        for line in tail.components(separatedBy: .newlines).reversed() {
            guard collected.count < limit else { break }
            guard let turn = turn(fromLine: line, assistantLimit: assistantLimit) else { continue }
            collected.append(turn)
        }
        return collected.reversed()
    }

    static func turns(
        path: String?, maxBytes: Int = maxBytes, limit: Int = maxTurns
    ) -> [TranscriptTurn] {
        guard let tail = read(path: path, maxBytes: maxBytes) else { return [] }
        return turns(inTail: tail, limit: limit)
    }

    /// One JSONL line → a turn, or nil for everything that is not plain conversation.
    static func turn(fromLine line: String, assistantLimit: Int = assistantLimit)
        -> TranscriptTurn? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // `isMeta` marks the reminders and caveats the CLI writes as if the user had — they are
        // not something the developer said.
        if root["isMeta"] as? Bool == true { return nil }
        guard let type = root["type"] as? String, type == "user" || type == "assistant"
        else { return nil }
        guard let message = root["message"] as? [String: Any] else { return nil }
        let role = (message["role"] as? String) ?? type
        guard role == "user" || role == "assistant" else { return nil }
        guard let text = Session.text(flatten(message["content"])) else { return nil }
        guard role == "assistant" else { return TranscriptTurn(role: role, text: text) }
        return TranscriptTurn(role: role, text: cap(text, to: assistantLimit))
    }

    /// `Session.truncate` puts its ellipsis *after* the limit; SPEC §13.2 counts the ellipsis,
    /// so the cap here is on the result.
    static func cap(_ text: String, to limit: Int) -> String {
        guard text.count > limit, limit > 0 else { return text }
        return Session.truncate(text, to: limit - 1)
    }

    /// String content, or the `text` blocks of a block list. `tool_use`, `tool_result`,
    /// `thinking` and `image` blocks contribute nothing (SPEC §13.2).
    static func flatten(_ content: Any?) -> String? {
        if let text = content as? String { return Session.text(text) }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let parts = blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return Session.text(block["text"] as? String)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}

/// SPEC §13.2's language rule: the model answers in the language the developer last wrote in.
/// A guess, not a detector — two outcomes, and the Danish one only needs one good signal.
enum LanguageGuess {
    static let danish = "Danish"
    static let english = "English"

    /// Words that are common in Danish and are not English words, so a single hit is enough.
    static let danishWords: Set<String> = [
        "og", "ikke", "jeg", "det", "der", "til", "med", "har", "kan", "skal", "hvis",
        "hvad", "hvordan", "hvorfor", "tak", "ja", "nej", "af", "er", "som", "ved",
        "denne", "dette", "mig", "din", "min", "vores", "fejl", "virker", "lige",
        "gerne", "nu", "ellers", "bare", "kun", "godt", "meget", "noget", "andet",
    ]

    static func guess(_ text: String?) -> String {
        guard let text = Session.text(text)?.lowercased() else { return english }
        if text.contains(where: { $0 == "æ" || $0 == "ø" || $0 == "å" }) { return danish }
        let words = text.split(whereSeparator: { !$0.isLetter })
        for word in words where danishWords.contains(String(word)) { return danish }
        return english
    }
}
