import Foundation

/// What a session is waiting for (SPEC §11.3). `done` never has a request file — the card for a
/// finished session is built from the state file alone — so it is not a request kind.
enum RequestKind: String, Codable, CaseIterable {
    case permission
    case question

    init(raw: String?) {
        self = RequestKind(rawValue: (raw ?? "").lowercased()) ?? .permission
    }
}

/// One `~/.lookout/requests/<agent>-<session_id>-<request_id>.json` (SPEC §11.3).
///
/// Decoding is as forgiving as `Session`'s: a newer reporter must never break an older app, and
/// a half-written file must never take the card down.
struct AttentionRequest: Codable, Identifiable, Equatable {
    var schema: Int = 1
    var agent: SessionAgent = .unknown
    var sessionID: String = ""
    var requestID: String = ""
    var kind: RequestKind = .permission
    var toolName: String?
    /// ≤ 120 chars, the one-line version for the card's header.
    var summary: String?
    /// The full command or path, up to 2000 chars — shown verbatim in the monospaced box.
    var commandOrPath: String?
    var question: String?
    var options: [String] = []
    var cwd: String = ""
    var createdAt: Date?
    /// When the reporter stops waiting for an answer file. Past → the terminal has taken over.
    var waitsUntil: Date?

    /// The file this was read from, without `.json`. The answer must carry the same name
    /// (SPEC §11.3), so it travels with the request rather than being rebuilt from parts.
    var name: String = ""

    /// True only for the in-memory question `CodexQuestionWatcher` builds (bug fix 2026-09-04) —
    /// never decoded from disk, and never true for a request the reporter actually wrote, because
    /// Codex has no real question hook to write one from (SPEC §17.7). What tells
    /// `AttentionCardModel.canDeliver`/`SuggestionContext` this `.question` is the genuine TUI
    /// question only Codex's own prompt can answer, not the stray/malformed reporter file both
    /// already defend against.
    var isCodexQuestion: Bool = false
    /// Every question Codex's `request_user_input` call asked, not just the first — `question`/
    /// `options` above stay the first one, so the single-question layout every other request
    /// already uses needs no special case; the card's compact list reads this instead once there
    /// is more than one. Empty for every request that is not a Codex question.
    var codexQuestions: [CodexQuestion.Question] = []

    var id: String { name.isEmpty ? "\(sessionID)-\(requestID)" : name }

    init() {}

    enum CodingKeys: String, CodingKey {
        case schema
        case agent
        case sessionID = "session_id"
        case requestID = "request_id"
        case kind
        case toolName = "tool_name"
        case summary
        case commandOrPath = "command_or_path"
        case question
        case options
        case cwd
        case createdAt = "created_at"
        case waitsUntil = "waits_until"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        schema = ((try? c.decodeIfPresent(Int.self, forKey: .schema)) ?? nil) ?? 1
        agent = SessionAgent(raw: ((try? c.decodeIfPresent(String.self, forKey: .agent)) ?? nil))
        requestID = ((try? c.decodeIfPresent(String.self, forKey: .requestID)) ?? nil) ?? ""
        kind = RequestKind(raw: ((try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil))
        toolName = (try? c.decodeIfPresent(String.self, forKey: .toolName)) ?? nil
        summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? nil
        commandOrPath = (try? c.decodeIfPresent(String.self, forKey: .commandOrPath)) ?? nil
        question = (try? c.decodeIfPresent(String.self, forKey: .question)) ?? nil
        options = AttentionRequest.decodeOptions(in: c)
        cwd = ((try? c.decodeIfPresent(String.self, forKey: .cwd)) ?? nil) ?? ""
        if let raw = ((try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil) {
            createdAt = ISO8601.date(raw)
        }
        if let raw = ((try? c.decodeIfPresent(String.self, forKey: .waitsUntil)) ?? nil) {
            waitsUntil = ISO8601.date(raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(agent.name, forKey: .agent)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(requestID, forKey: .requestID)
        try c.encode(kind.rawValue, forKey: .kind)
        try c.encodeIfPresent(toolName, forKey: .toolName)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encodeIfPresent(commandOrPath, forKey: .commandOrPath)
        try c.encodeIfPresent(question, forKey: .question)
        if !options.isEmpty { try c.encode(options, forKey: .options) }
        try c.encode(cwd, forKey: .cwd)
        try c.encodeIfPresent(createdAt.map(ISO8601.string), forKey: .createdAt)
        try c.encodeIfPresent(waitsUntil.map(ISO8601.string), forKey: .waitsUntil)
    }

    /// AskUserQuestion options arrive as plain strings from one reporter and as
    /// `{"label": …}` objects from another — both are read, anything else is dropped.
    private static func decodeOptions(in c: KeyedDecodingContainer<CodingKeys>) -> [String] {
        if let plain = ((try? c.decodeIfPresent([String].self, forKey: .options)) ?? nil) {
            return plain.compactMap(Session.text)
        }
        if let objects = ((try? c.decodeIfPresent([[String: String]].self, forKey: .options)) ?? nil) {
            return objects.compactMap { entry in
                for key in ["label", "text", "option", "value", "title"] {
                    if let value = Session.text(entry[key]) { return value }
                }
                return nil
            }
        }
        return []
    }

    // MARK: - Reading

    /// The reporter's file name, minus `.json` (SPEC §11.3).
    static func fileName(agent: SessionAgent, sessionID: String, requestID: String) -> String {
        "\(agent.name)-\(sessionID)-\(requestID)"
    }

    static func decode(_ data: Data, name: String) -> AttentionRequest? {
        guard var request = try? JSONDecoder().decode(AttentionRequest.self, from: data) else {
            return nil
        }
        request.name = name
        return request
    }

    // MARK: - State

    /// SPEC §11.4: past `waits_until` the reporter has stopped polling, the prompt is up in the
    /// terminal, and Allow/Deny would write a file nobody reads.
    func isExpired(now: Date = Date()) -> Bool {
        guard let waitsUntil else { return false }
        return now >= waitsUntil
    }

    /// Only a permission request can be answered with a file; a question is answered by sending
    /// text (SPEC §11.3).
    func isAnswerable(now: Date = Date()) -> Bool {
        kind == .permission && !isExpired(now: now)
    }

    /// Seconds left before the terminal takes over, for the card's countdown.
    func secondsLeft(now: Date = Date()) -> TimeInterval? {
        guard let waitsUntil else { return nil }
        return max(0, waitsUntil.timeIntervalSince(now))
    }

    /// The card's "Asks" headline: `Bash` + the summary the reporter wrote.
    var headline: String {
        switch kind {
        case .permission:
            let tool = Session.text(toolName) ?? "Permission"
            guard let summary = Session.text(summary) else { return tool }
            return "\(tool) · \(summary)"
        case .question:
            return Session.text(question) ?? Session.text(summary) ?? "Question for you"
        }
    }

    /// The monospaced box's contents (SPEC §11.4), never longer than the reporter's own cap.
    var commandText: String? {
        guard let value = Session.text(commandOrPath) else { return nil }
        return String(value.prefix(2000))
    }
}

/// What the reporter is polling for (SPEC §11.3).
enum AnswerDecision: String, Codable, CaseIterable {
    case allow
    case deny
    /// Written by nobody today: the card's Ignore simply stops answering, which is what a
    /// timeout already means. It exists because the reporter accepts it.
    case pass

    var label: String {
        switch self {
        case .allow: return "Allow"
        case .deny: return "Deny"
        case .pass: return "Pass"
        }
    }
}

/// Writes `~/.lookout/answers/<same name>.json` atomically (SPEC §11.3).
enum AnswerWriter {
    struct Answer: Codable, Equatable {
        var decision: AnswerDecision
        var answeredAt: Date

        enum CodingKeys: String, CodingKey {
            case decision
            case answeredAt = "answered_at"
        }

        init(decision: AnswerDecision, answeredAt: Date = Date()) {
            self.decision = decision
            self.answeredAt = answeredAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            decision = AnswerDecision(rawValue: try c.decode(String.self, forKey: .decision)) ?? .pass
            let raw = ((try? c.decodeIfPresent(String.self, forKey: .answeredAt)) ?? nil) ?? ""
            answeredAt = ISO8601.date(raw) ?? Date()
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(decision.rawValue, forKey: .decision)
            try c.encode(ISO8601.string(answeredAt), forKey: .answeredAt)
        }
    }

    enum WriteError: Error, Equatable {
        case noName
        case directoryUnavailable
        case writeFailed(String)
    }

    static func url(for request: AttentionRequest, in directory: URL) -> URL {
        directory.appendingPathComponent("\(request.name).json")
    }

    /// `.tmp` then `rename`, exactly as the reporter writes its own files, so the poller can
    /// never read half an answer.
    @discardableResult
    static func write(
        _ decision: AnswerDecision,
        for request: AttentionRequest,
        in directory: URL,
        at date: Date = Date()
    ) throws -> URL {
        guard !request.name.isEmpty else { throw WriteError.noName }

        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            do {
                try fm.createDirectory(
                    at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw WriteError.directoryUnavailable
            }
        }

        let target = url(for: request, in: directory)
        let temporary = target.appendingPathExtension("tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Answer(decision: decision, answeredAt: date))
        do {
            try data.write(to: temporary, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: temporary, to: target)
        } catch {
            try? fm.removeItem(at: temporary)
            throw WriteError.writeFailed(error.localizedDescription)
        }
        return target
    }

    static func read(_ url: URL) -> Answer? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Answer.self, from: data)
    }
}

/// Every answer and every send, one line each, in `~/.lookout/answers.log` (SPEC §11.4).
/// Never the message itself beyond the first 60 characters, and never a token.
enum AnswerAudit {
    static let textLimit = 60

    /// Which way the answer went.
    enum Channel: String {
        case answerFile = "answer-file"
        case message
        case clipboard
        case ignored
        /// SPEC §15.5: a rename that was pushed into the session itself.
        case rename
        /// SPEC §17.1: an action button on the notification itself, not the card.
        case notification
        /// SPEC §17.7: `codex queue --thread <id> --message <text>` — Codex's Send channel.
        case codexQueue = "codex-queue"
    }

    static func line(
        session: Session, channel: Channel, outcome: String, text: String?
    ) -> String {
        var parts = [
            "\(session.project)/\(session.sessionID)",
            channel.rawValue,
            outcome,
        ]
        if let text = Session.text(text) {
            let flat = text
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            parts.append("\"\(String(flat.prefix(textLimit)))\"")
        }
        return parts.joined(separator: " · ")
    }

    static func record(
        session: Session, channel: Channel, outcome: String, text: String? = nil,
        home: LookoutHome = LookoutHome()
    ) {
        LogFile.append(line(session: session, channel: channel, outcome: outcome, text: text),
                       to: home.answersLog)
    }
}
