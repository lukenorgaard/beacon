import Foundation

/// The states a session can be in. Raw values match the reporter contract (SPEC §4 + §8.1).
enum SessionState: String, Codable, CaseIterable {
    case idle
    case working
    case needsYou = "needs_you"
    case done
    /// Alive, but nothing is reporting for it — discovered by process scan (SPEC §8.2).
    case running

    /// Group order for the sessions list (SPEC §8.2 supersedes §5.2).
    var sortRank: Int {
        switch self {
        case .needsYou: return 0
        case .done: return 1
        case .working: return 2
        case .running: return 3
        case .idle: return 4
        }
    }

    /// A manually held session sorts below every real state, including idle — its own group,
    /// one past `.idle`'s rank. Not a case of its own: the reporter never writes "held", it is
    /// `Session.isHeld` (a local override) that puts a session here — see `Session.sortRank`.
    static let heldSortRank = 5

    init(raw: String?) {
        self = SessionState(rawValue: raw ?? "") ?? .idle
    }
}

/// Where the session lives. Unknown hosts degrade to `.unknown` rather than failing the decode.
enum SessionHost: String, Codable, CaseIterable {
    case cursor
    case devin
    case vscode
    case terminal
    case iterm
    case claudeDesktop = "claude-desktop"
    case codexApp = "codex-app"
    case unknown

    init(raw: String?) {
        self = SessionHost(rawValue: raw ?? "") ?? .unknown
    }

    /// Short label for the host chip in a row.
    var chip: String {
        switch self {
        case .cursor: return "Cursor"
        case .devin: return "Devin"
        case .vscode: return "VS Code"
        case .terminal: return "Terminal"
        case .iterm: return "iTerm"
        case .claudeDesktop: return "Desktop"
        case .codexApp: return "Codex"
        case .unknown: return "Unknown"
        }
    }
}

/// How a row is tinted (SPEC §9.5). The provider outranks the agent: Claude Code pointed at a
/// model on localhost is a *local* row, not a Claude one — which is the whole point of the
/// colour, since the two behave nothing alike.
enum SessionFamily: String, Codable, CaseIterable {
    case claude
    case codex
    case local
    /// OpenRouter, or any other base URL that is not the vendor's own.
    case api
    case other

    /// The Settings legend's five labels, in `allCases` order (SPEC §9.5).
    var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .local: return "Local model"
        case .api: return "OpenRouter / API"
        case .other: return "Other"
        }
    }
}

/// Any agent name at all — Lookout has no whitelist (SPEC §8). `claude` and `codex` get a glyph,
/// everything else gets its first letter in a circle.
struct SessionAgent: Codable, Equatable, Hashable {
    let name: String

    init(raw: String?) {
        let cleaned = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        name = cleaned.isEmpty ? "unknown" : cleaned
    }

    init(from decoder: Decoder) throws {
        let value = try? decoder.singleValueContainer().decode(String.self)
        self.init(raw: value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }

    static let claude = SessionAgent(raw: "claude")
    static let codex = SessionAgent(raw: "codex")
    static let unknown = SessionAgent(raw: "unknown")

    /// The character drawn in the row: ✦ claude, ◇ codex, otherwise the first letter.
    var glyph: String {
        switch name {
        case "claude": return "✦"
        case "codex": return "◇"
        default: return String(name.prefix(1)).uppercased()
        }
    }

    /// Letter glyphs get a circle around them; the two symbol glyphs stand alone.
    var glyphIsLetter: Bool {
        name != "claude" && name != "codex"
    }

    var display: String {
        name.isEmpty ? "unknown" : name
    }
}

/// One model's cumulative token counts since `usage_offset` (SPEC §17.6/§17.7). Keyed on
/// `Session.tokens` by the exact model string the reporter wrote — the same string
/// `Session.modelDisplayName` already turns into a short family name for pricing.
struct TokenBucket: Codable, Equatable {
    var inTokens: Int = 0
    var outTokens: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0

    enum CodingKeys: String, CodingKey {
        case inTokens = "in"
        case outTokens = "out"
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
    }

    init(inTokens: Int = 0, outTokens: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.inTokens = inTokens
        self.outTokens = outTokens
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inTokens = ((try? c.decodeIfPresent(Int.self, forKey: .inTokens)) ?? nil) ?? 0
        outTokens = ((try? c.decodeIfPresent(Int.self, forKey: .outTokens)) ?? nil) ?? 0
        cacheRead = ((try? c.decodeIfPresent(Int.self, forKey: .cacheRead)) ?? nil) ?? 0
        cacheWrite = ((try? c.decodeIfPresent(Int.self, forKey: .cacheWrite)) ?? nil) ?? 0
    }
}

/// One sub-agent a session spawned (SPEC §9.3). The reporter appends these on `SubagentStart`
/// and removes them on `SubagentStop`, so the array is always the *live* set.
///
/// Decoding is tolerant in the same way the session is: only the shape has to be right, every
/// field may be missing.
struct Subagent: Codable, Equatable, Identifiable {
    var id: String = ""
    var type: String = ""
    var description: String?
    var model: String?
    var startedAt: Date?
    /// Where this sub-agent is working (SPEC §12.2) — a git worktree as often as not. Best
    /// effort: the reporter can only fill it when the payload carried one.
    var cwd: String?

    init(
        id: String = "", type: String = "", description: String? = nil,
        model: String? = nil, startedAt: Date? = nil, cwd: String? = nil
    ) {
        self.id = id
        self.type = type
        self.description = description
        self.model = model
        self.startedAt = startedAt
        self.cwd = cwd
    }

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case description
        case model
        case startedAt = "started_at"
        case cwd
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = ((try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil) ?? ""
        type = ((try? c.decodeIfPresent(String.self, forKey: .type)) ?? nil) ?? ""
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? nil
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? nil
        if let raw = ((try? c.decodeIfPresent(String.self, forKey: .startedAt)) ?? nil) {
            startedAt = ISO8601.date(raw)
        }
        cwd = (try? c.decodeIfPresent(String.self, forKey: .cwd)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(startedAt.map(ISO8601.string), forKey: .startedAt)
        try c.encodeIfPresent(cwd, forKey: .cwd)
    }

    /// `type · model · description` — one tooltip line (SPEC §9.3).
    var summary: String {
        var parts: [String] = []
        if !type.isEmpty { parts.append(type) }
        if let model, !model.isEmpty { parts.append(model) }
        if let description, !description.isEmpty { parts.append(description) }
        if parts.isEmpty { parts.append(id.isEmpty ? "sub-agent" : id) }
        return parts.joined(separator: " · ")
    }
}

/// One live agent session — decoded from `~/.lookout/sessions/<agent>-<id>.json` (SPEC §4),
/// or synthesised in memory by the process scanner (SPEC §8.2).
///
/// Decoding is deliberately forgiving: every field except `session_id` may be absent, and
/// unknown fields are ignored, so a newer reporter never breaks an older app.
