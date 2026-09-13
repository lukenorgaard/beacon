import Foundation

/// Codex sessions found straight from Codex's own session logs — no hook, no trust prompt.
///
/// A Codex Desktop session has no process of its own (the app runs one `codex app-server` for
/// everything, which the process scan rightly treats as a helper), so the scan can never see
/// it; and Codex runs the reporter's hooks only after a one-time trust that on many machines
/// has never been granted. The rollout file is enough on its own: its first line names the
/// session (id, cwd, originator, whether it is a sub-agent and of whom), `turn_context` lines
/// carry the model, `token_count` lines carry the account's rate limits, and the last few lines
/// say what it is doing. A file written within `liveWindow` is a live session.
///
/// Rows made here are discovered rows (SPEC §8.2): `isDiscovered`, no pid, `reason: rollout`.
/// A hook-written state file for the same session id always wins in `Session.merge`.
enum CodexRolloutDiscovery {
    /// A rollout untouched for longer than this is a finished session, not a quiet one.
    static let liveWindow: TimeInterval = 30 * 60
    /// Written within this long ago → `working`.
    static let workingWindow: TimeInterval = 120
    /// A final agent message has to sit unchanged this long before the row says `done` — the
    /// same event also precedes the next tool call by a fraction of a second mid-turn.
    static let settleWindow: TimeInterval = 20
    static let tailBytes = 128 * 1024
    /// The first line carries `base_instructions` — the whole system prompt, tens of KB — so the
    /// head is read up to this cap or the first newline, whichever comes first. A fixed 16 KB
    /// cut that line in half, the JSON failed to parse, and every live session was skipped.
    static let headBytes = 2 * 1024 * 1024
    static let reason = "rollout"
    static let titleLimit = 80
    static let messageLimit = 160
    static let detailLimit = 120

    /// `$CODEX_HOME/sessions`, the tree Codex itself writes (`YYYY/MM/DD/rollout-<ts>-<id>.jsonl`).
    static var sessionsDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        let home = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("sessions")
    }

    struct Rollout: Equatable {
        let path: String
        let modifiedAt: Date
        let size: Int
    }

    /// Line 1 of a rollout, `type: session_meta`.
    struct Meta: Equatable {
        var id = ""
        var cwd = ""
        var originator: String?
        var threadSource: String?
        var parentThreadID: String?
        var agentNickname: String?
        var startedAt: Date?

        var isSubagent: Bool { threadSource == "subagent" || parentThreadID != nil }

        /// Only a thread the user started is a session of its own. Codex writes a rollout for
        /// its own sub-agents (`subagent`) and for its internal review passes
        /// (`guardian_review`) too — 11 of 15 live files on one measured machine — and those
        /// belong under their parent in the Agents tab, never as rows in Sessions. A rollout
        /// with no `thread_source` at all is the CLI's own shape, which is a main thread.
        var isMainThread: Bool { (threadSource ?? "user") == "user" && parentThreadID == nil }
    }

    /// What the tail of a rollout says the session has been doing.
    struct Look: Equatable {
        var model: String?
        var lastUserMessage: String?
        var lastAgentMessage: String?
        var lastToolName: String?
        /// The payload type (or line type) of the newest line — `agent_message`,
        /// `function_call`, `token_count`, `task_complete`, …
        var lastKind: String?
        var lastAt: Date?
        /// The newest `token_count` rate limits, already in `codex-usage.json`'s shape.
        var usage: CodexUsageSnapshot?
    }

    /// File access, injectable so the parsing and the rules are testable without a `~/.codex`.
    struct IO {
        var list: (_ now: Date) -> [Rollout]
        var head: (_ path: String, _ maxBytes: Int) -> Data?
        var tail: (_ path: String, _ maxBytes: Int) -> Data?

        static let live = IO(
            list: { now in rollouts(under: sessionsDirectory, now: now) },
            head: { path, maxBytes in firstLine(ofFileAt: path, maxBytes: maxBytes) },
            tail: { path, maxBytes in CodexQuestionWatcher.defaultTailReader(path, maxBytes) }
        )
    }

    /// Reads until the first newline (inclusive) or `maxBytes`, in 64 KB steps, so a long first
    /// line costs no more than it has to and a short one costs one read.
    static func firstLine(ofFileAt path: String, maxBytes: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        let step = 64 * 1024
        while buffer.count < maxBytes {
            guard let chunk = try? handle.read(upToCount: min(step, maxBytes - buffer.count)),
                  !chunk.isEmpty
            else { break }
            buffer.append(chunk)
            if chunk.contains(UInt8(ascii: "\n")) { break }
        }
        return buffer.isEmpty ? nil : buffer
    }

    // MARK: - Listing

    static func rollouts(
        under directory: URL, now: Date, fileManager: FileManager = .default
    ) -> [Rollout] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [Rollout] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) <= liveWindow
            else { continue }
            result.append(Rollout(path: url.path, modifiedAt: modified, size: values.fileSize ?? 0))
        }
        return result
    }

    // MARK: - Parsing

    static func meta(head data: Data) -> Meta? {
        guard let first = data.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first,
              let line = object(Data(first)), line["type"] as? String == "session_meta",
              let payload = line["payload"] as? [String: Any]
        else { return nil }

        var meta = Meta()
        meta.id = (payload["id"] as? String) ?? (payload["session_id"] as? String) ?? ""
        guard !meta.id.isEmpty else { return nil }
        meta.cwd = payload["cwd"] as? String ?? ""
        meta.originator = payload["originator"] as? String
        meta.threadSource = payload["thread_source"] as? String
        meta.startedAt = (payload["timestamp"] as? String).flatMap(ISO8601.date)
        meta.parentThreadID = payload["parent_thread_id"] as? String
        meta.agentNickname = payload["agent_nickname"] as? String
        // A sub-agent's parent also sits under `source.subagent.thread_spawn`.
        if let source = payload["source"] as? [String: Any],
           let subagent = source["subagent"] as? [String: Any],
           let spawn = subagent["thread_spawn"] as? [String: Any] {
            meta.parentThreadID = meta.parentThreadID ?? spawn["parent_thread_id"] as? String
            meta.agentNickname = meta.agentNickname ?? spawn["agent_nickname"] as? String
        }
        return meta
    }

    /// Forgiving like `CodexQuestion.parse`: the tail may open mid-line and end mid-write, and
    /// any line that is not JSON of a known shape is skipped, never an error.
    static func look(tail data: Data) -> Look {
        var look = Look()
        for lineData in data.split(separator: UInt8(ascii: "\n")) {
            guard let line = object(Data(lineData)), let type = line["type"] as? String else { continue }
            let payload = line["payload"] as? [String: Any] ?? [:]
            let at = (line["timestamp"] as? String).flatMap(ISO8601.date)
            let kind = payload["type"] as? String ?? type

            switch type {
            case "turn_context":
                if let model = payload["model"] as? String, !model.isEmpty { look.model = model }
                continue
            case "event_msg":
                switch kind {
                case "token_count":
                    if let limits = payload["rate_limits"] as? [String: Any] {
                        look.usage = snapshot(limits: limits, at: at) ?? look.usage
                    }
                case "user_message":
                    look.lastUserMessage = Session.text(payload["message"] as? String)
                case "agent_message":
                    look.lastAgentMessage = Session.text(payload["message"] as? String)
                default:
                    break
                }
            case "response_item":
                switch kind {
                case "function_call", "custom_tool_call":
                    look.lastToolName = Session.text(payload["name"] as? String)
                case "agent_message":
                    if let text = text(blocks: payload["content"]) { look.lastAgentMessage = text }
                default:
                    break
                }
            default:
                continue
            }
            look.lastKind = kind
            if let at { look.lastAt = at }
        }
        return look
    }

    /// The rollout's `rate_limits` already use `codex-usage.json`'s field names; only `updated`
    /// is added, so the one parser serves both.
    static func snapshot(limits: [String: Any], at: Date?) -> CodexUsageSnapshot? {
        var object = limits
        object["updated"] = ISO8601.string(at ?? Date())
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else { return nil }
        return CodexUsageSnapshot.parse(data)
    }

    // MARK: - Rows

    static func state(look: Look, modifiedAt: Date, now: Date) -> SessionState {
        let age = now.timeIntervalSince(modifiedAt)
        let ended = look.lastKind == "agent_message" || look.lastKind == "task_complete"
        if ended, age >= settleWindow { return .done }
        if age <= workingWindow { return .working }
        return .idle
    }

    static func session(meta: Meta, look: Look, rollout: Rollout, now: Date) -> Session {
        var session = Session()
        session.agent = .codex
        session.sessionID = meta.id
        session.isDiscovered = true
        session.reason = reason
        session.state = state(look: look, modifiedAt: rollout.modifiedAt, now: now)
        session.cwd = meta.cwd
        session.project = URL(fileURLWithPath: meta.cwd).lastPathComponent
        session.host = meta.originator == "Codex Desktop" ? .codexApp : .unknown
        session.entrypoint = "codex"
        session.provider = "openai"
        session.model = look.model
        session.transcriptPath = rollout.path
        session.startedAt = meta.startedAt
        session.stateSince = rollout.modifiedAt
        session.updatedAt = rollout.modifiedAt
        session.title = look.lastUserMessage.map { TranscriptTail.cap($0, to: titleLimit) }
        session.lastMessage = look.lastAgentMessage.map { TranscriptTail.cap($0, to: messageLimit) }
        if session.state == .working, let tool = look.lastToolName {
            session.detail = TranscriptTail.cap(tool, to: detailLimit)
        }
        return session
    }

    static func subagent(meta: Meta, look: Look, rollout: Rollout) -> Subagent {
        var subagent = Subagent()
        subagent.id = meta.id
        subagent.type = meta.agentNickname ?? "codex"
        subagent.description = look.lastToolName ?? look.lastAgentMessage.map {
            TranscriptTail.cap($0, to: detailLimit)
        }
        subagent.model = look.model
        subagent.startedAt = meta.startedAt ?? rollout.modifiedAt
        subagent.cwd = meta.cwd.isEmpty ? nil : meta.cwd
        return subagent
    }

    struct Found {
        var sessions: [Session] = []
        var usage: CodexUsageSnapshot?
    }

    /// Every live *user-started* rollout as a session row, with Codex's own sub-agent and
    /// review threads folded into their parent's `subagents`, plus the newest rate-limit
    /// snapshot seen in any of them.
    static func discover(now: Date = Date(), io: IO = .live) -> Found {
        var parents: [String: Session] = [:]
        var children: [(Meta, Look, Rollout)] = []
        var found = Found()

        for rollout in io.list(now) {
            guard let headData = io.head(rollout.path, headBytes),
                  let meta = meta(head: headData)
            else { continue }
            let look = look(tail: io.tail(rollout.path, tailBytes) ?? Data())
            if let usage = look.usage,
               (found.usage?.updated ?? .distantPast) < (usage.updated ?? .distantPast) {
                found.usage = usage
            }
            if meta.isMainThread {
                parents[meta.id] = session(meta: meta, look: look, rollout: rollout, now: now)
            } else {
                children.append((meta, look, rollout))
            }
        }

        // A sub-agent belongs to its parent. One whose parent is not live is dropped rather
        // than promoted: the Sessions tab lists sessions, and a stray review thread reads as
        // one more thing to attend to when it is really Codex talking to itself.
        for (meta, look, rollout) in children {
            guard let parentID = meta.parentThreadID, var parent = parents[parentID] else { continue }
            parent.subagents.append(subagent(meta: meta, look: look, rollout: rollout))
            parents[parentID] = parent
        }

        found.sessions = parents.values.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        return found
    }

    /// Codex's content blocks are `output_text` for what the model says and `input_text` for
    /// what it was told — in a multi-agent session the latter is inter-agent envelope text with
    /// an `author`/`recipient`, never the reply the user is waiting for. Claude's `text` is
    /// accepted too, which is why `TranscriptTail.flatten` is not reused: it knows only `text`.
    static func text(blocks: Any?) -> String? {
        if let text = blocks as? String { return Session.text(text) }
        guard let blocks = blocks as? [[String: Any]] else { return nil }
        let parts = blocks.compactMap { block -> String? in
            guard let type = block["type"] as? String, type == "output_text" || type == "text"
            else { return nil }
            return Session.text(block["text"] as? String)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private static func object(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
