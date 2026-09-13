import Foundation

struct Session: Codable, Identifiable, Equatable {
    var schema: Int = 1
    var agent: SessionAgent = .unknown
    var sessionID: String = ""
    var state: SessionState = .idle
    var reason: String?
    var detail: String?
    var cwd: String = ""
    var project: String = ""
    var title: String?
    /// The desktop app's own, evolving title for this session (`custom-title` in the transcript,
    /// SPEC §9.4). Rows prefer it over `title`, and the jumper matches the sidebar button by it.
    var desktopTitle: String?
    var lastMessage: String?
    var pid: Int32?
    var tty: String?
    /// SPEC §16.2: the nearest shell above the agent — `zsh` in
    /// `claude → zsh → Cursor Helper: terminal pty-host`. It is what the editor companion calls
    /// a terminal's `processId`, and therefore the only exact key a jump into a tab has.
    var shellPid: Int32?
    var host: SessionHost = .unknown
    var hostPID: Int32?
    var hostRef: String?
    var entrypoint: String?
    var transcriptPath: String?
    /// SPEC §11.3: the session's own messaging socket (`/tmp/cc-socks/<pid>.sock`). Claude only,
    /// and only the *path* — the token that goes with it is never written to disk (SPEC §11.2).
    var messagingSocket: String?
    /// SPEC §11.3: the permission request currently waiting for an answer, if any.
    var requestID: String?
    var requestSummary: String?
    /// SPEC §12.2: the directory the session started in, recorded once and never rewritten.
    var originCwd: String?
    /// SPEC §12.2: where the newest tool event ran, when that is not `cwd` — a sub-agent in a
    /// git worktree is the case this exists for.
    var activeCwd: String?
    /// SPEC §12.2: basename of the worktree behind `active_cwd` (`wt-export-import`).
    var worktree: String?
    /// The model behind the session (SPEC §9.5), verbatim from the reporter: `claude-fable-5-1`,
    /// `gpt-5.6-sol`, `llama-3.3-70b`. Absent for a discovered row, which knows nothing.
    var model: String?
    /// `anthropic` | `openai` | `openrouter` | `local` | `custom` (SPEC §9.5).
    var provider: String?
    var startedAt: Date?
    var stateSince: Date?
    var updatedAt: Date?
    /// Live sub-agents of this session (SPEC §9.3). Absent in the file → empty here.
    var subagents: [Subagent] = []
    /// SPEC §17.6/§17.7: cumulative token counts per model since `usage_offset`, refreshed at
    /// `Stop`. Absent in the file (a session that has not stopped yet) → empty here, which is
    /// exactly what "nothing to price" means to `Session.cost(pricing:)`.
    var tokens: [String: TokenBucket] = [:]

    /// SPEC §19.1: the prompt size of the session's latest turn, as the reporter measured it —
    /// input + cache-creation + cache-read for Claude, `last_token_usage.input_tokens` for
    /// Codex. Absent until something has been measured, and cleared again on a compaction.
    var contextTokens: Int?
    /// SPEC §19.1/§19.3: the window those tokens sit in. Codex reports its own
    /// (`model_context_window`); Claude never does, and the app resolves it from
    /// `ContextWindows` instead — which is why this stays `nil` on a Claude record.
    var contextWindow: Int?
    /// When `contextTokens` was measured (SPEC §19.1) — the tooltip's "measured 12s ago".
    var contextAt: Date?
    /// SPEC §19.1: when the session last compacted. The tail still shows the pre-compact size at
    /// that moment, so the reporter clears `contextTokens` and stamps this; the next measurement
    /// fills the size in again.
    var contextCompactedAt: Date?

    /// True for rows the process scanner invented; a state file for the same pid always wins.
    var isDiscovered: Bool = false

    /// SPEC §15.4: the name the owner gave this session, put here by `SessionNames` after the store
    /// has read the files. Never decoded and never encoded — it belongs to `names.json`, not to
    /// the reporter's state file, and a session that has not been renamed simply has none.
    var customName: String?

    /// The "Put on hold" row action, put here by `AppState` from `Settings.heldSessions` after
    /// the store has read the files — like `customName`, this is the owner's own manual override,
    /// never decoded from or encoded to the reporter's state file. `AppState.apply(_:)` has
    /// already run it through `SessionHold`'s auto-clear rule by the time this is `true`, so
    /// nothing downstream (sort, the filter chips, the row) has to ask that question again.
    var isHeld: Bool = false

    var id: String { sessionID }

    init() {}

    enum CodingKeys: String, CodingKey {
        case schema
        case agent
        case sessionID = "session_id"
        case state
        case reason
        case detail
        case cwd
        case project
        case title
        case desktopTitle = "desktop_title"
        case lastMessage = "last_message"
        case pid
        case tty
        case shellPid = "shell_pid"
        case host
        case hostPID = "host_pid"
        case hostRef = "host_ref"
        case entrypoint
        case transcriptPath = "transcript_path"
        case messagingSocket = "messaging_socket"
        case requestID = "request_id"
        case requestSummary = "request_summary"
        case originCwd = "origin_cwd"
        case activeCwd = "active_cwd"
        case worktree
        case model
        case provider
        case startedAt = "started_at"
        case stateSince = "state_since"
        case updatedAt = "updated_at"
        case subagents
        case tokens
        // SPEC §19.1
        case contextTokens = "context_tokens"
        case contextWindow = "context_window"
        case contextAt = "context_at"
        case contextCompactedAt = "context_compacted_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        schema = ((try? c.decodeIfPresent(Int.self, forKey: .schema)) ?? nil) ?? 1
        agent = SessionAgent(raw: ((try? c.decodeIfPresent(String.self, forKey: .agent)) ?? nil))
        state = SessionState(raw: ((try? c.decodeIfPresent(String.self, forKey: .state)) ?? nil))
        reason = (try? c.decodeIfPresent(String.self, forKey: .reason)) ?? nil
        detail = (try? c.decodeIfPresent(String.self, forKey: .detail)) ?? nil
        cwd = ((try? c.decodeIfPresent(String.self, forKey: .cwd)) ?? nil) ?? ""
        host = SessionHost(raw: ((try? c.decodeIfPresent(String.self, forKey: .host)) ?? nil))
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        desktopTitle = (try? c.decodeIfPresent(String.self, forKey: .desktopTitle)) ?? nil
        lastMessage = (try? c.decodeIfPresent(String.self, forKey: .lastMessage)) ?? nil
        pid = (try? c.decodeIfPresent(Int32.self, forKey: .pid)) ?? nil
        tty = (try? c.decodeIfPresent(String.self, forKey: .tty)) ?? nil
        shellPid = (try? c.decodeIfPresent(Int32.self, forKey: .shellPid)) ?? nil
        hostPID = (try? c.decodeIfPresent(Int32.self, forKey: .hostPID)) ?? nil
        hostRef = (try? c.decodeIfPresent(String.self, forKey: .hostRef)) ?? nil
        entrypoint = (try? c.decodeIfPresent(String.self, forKey: .entrypoint)) ?? nil
        transcriptPath = (try? c.decodeIfPresent(String.self, forKey: .transcriptPath)) ?? nil
        messagingSocket = (try? c.decodeIfPresent(String.self, forKey: .messagingSocket)) ?? nil
        requestID = (try? c.decodeIfPresent(String.self, forKey: .requestID)) ?? nil
        requestSummary = (try? c.decodeIfPresent(String.self, forKey: .requestSummary)) ?? nil
        originCwd = (try? c.decodeIfPresent(String.self, forKey: .originCwd)) ?? nil
        activeCwd = (try? c.decodeIfPresent(String.self, forKey: .activeCwd)) ?? nil
        worktree = (try? c.decodeIfPresent(String.self, forKey: .worktree)) ?? nil
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? nil
        provider = (try? c.decodeIfPresent(String.self, forKey: .provider)) ?? nil

        let explicitProject = ((try? c.decodeIfPresent(String.self, forKey: .project)) ?? nil) ?? ""
        // A missing `project` is recoverable — it is only ever basename(cwd).
        project = explicitProject.isEmpty ? Session.projectName(for: cwd) : explicitProject

        startedAt = Session.date(in: c, forKey: .startedAt)
        stateSince = Session.date(in: c, forKey: .stateSince)
        updatedAt = Session.date(in: c, forKey: .updatedAt)
        // A malformed list degrades to no sub-agents rather than taking the session down.
        subagents = ((try? c.decodeIfPresent([Subagent].self, forKey: .subagents)) ?? nil) ?? []
        tokens = ((try? c.decodeIfPresent([String: TokenBucket].self, forKey: .tokens)) ?? nil) ?? [:]
        // SPEC §19.1: four optional fields an older reporter simply does not write. A null, a
        // missing key and a value of the wrong type all mean the same thing here — not measured.
        contextTokens = (try? c.decodeIfPresent(Int.self, forKey: .contextTokens)) ?? nil
        contextWindow = (try? c.decodeIfPresent(Int.self, forKey: .contextWindow)) ?? nil
        contextAt = Session.date(in: c, forKey: .contextAt)
        contextCompactedAt = Session.date(in: c, forKey: .contextCompactedAt)
        isDiscovered = false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(agent.name, forKey: .agent)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(state.rawValue, forKey: .state)
        try c.encodeIfPresent(reason, forKey: .reason)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(project, forKey: .project)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(desktopTitle, forKey: .desktopTitle)
        try c.encodeIfPresent(lastMessage, forKey: .lastMessage)
        try c.encodeIfPresent(pid, forKey: .pid)
        try c.encodeIfPresent(tty, forKey: .tty)
        try c.encodeIfPresent(shellPid, forKey: .shellPid)
        try c.encode(host.rawValue, forKey: .host)
        try c.encodeIfPresent(hostPID, forKey: .hostPID)
        try c.encodeIfPresent(hostRef, forKey: .hostRef)
        try c.encodeIfPresent(entrypoint, forKey: .entrypoint)
        try c.encodeIfPresent(transcriptPath, forKey: .transcriptPath)
        try c.encodeIfPresent(messagingSocket, forKey: .messagingSocket)
        try c.encodeIfPresent(requestID, forKey: .requestID)
        try c.encodeIfPresent(requestSummary, forKey: .requestSummary)
        try c.encodeIfPresent(originCwd, forKey: .originCwd)
        try c.encodeIfPresent(activeCwd, forKey: .activeCwd)
        try c.encodeIfPresent(worktree, forKey: .worktree)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(provider, forKey: .provider)
        try c.encodeIfPresent(startedAt.map(ISO8601.string), forKey: .startedAt)
        try c.encodeIfPresent(stateSince.map(ISO8601.string), forKey: .stateSince)
        try c.encodeIfPresent(updatedAt.map(ISO8601.string), forKey: .updatedAt)
        if !subagents.isEmpty { try c.encode(subagents, forKey: .subagents) }
        if !tokens.isEmpty { try c.encode(tokens, forKey: .tokens) }
        // SPEC §19.1
        try c.encodeIfPresent(contextTokens, forKey: .contextTokens)
        try c.encodeIfPresent(contextWindow, forKey: .contextWindow)
        try c.encodeIfPresent(contextAt.map(ISO8601.string), forKey: .contextAt)
        try c.encodeIfPresent(
            contextCompactedAt.map(ISO8601.string), forKey: .contextCompactedAt
        )
    }

    static func projectName(for cwd: String) -> String {
        guard !cwd.isEmpty else { return "session" }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "session" : name
    }

    static func date(
        in container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
    ) -> Date? {
        guard let raw = ((try? container.decodeIfPresent(String.self, forKey: key)) ?? nil) else {
            return nil
        }
        return ISO8601.date(raw)
    }
}
