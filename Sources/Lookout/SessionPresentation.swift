import Foundation

extension Session {
    // MARK: - Row text (SPEC §5.2, §8.2)

    /// `Bash` out of `Bash: rm -rf build`.
    var detailTool: String? {
        guard let detail, !detail.isEmpty else { return nil }
        guard let head = detail.split(separator: ":", maxSplits: 1).first else { return nil }
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

    /// The title a row shows (SPEC §9.4): the desktop app rewrites its own title as the session
    /// evolves, so when the reporter captured one it beats the first-prompt `title`. Blank and
    /// whitespace-only values fall through as if they were absent.
    var displayTitle: String? {
        Session.text(desktopTitle) ?? Session.text(title)
    }

    /// Trimmed, or nil when there was nothing there.
    static func text(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    // MARK: - Family, model, provider (SPEC §9.5)

    /// Lower-cased `provider`, or nil when the field is absent or blank.
    var providerKey: String? {
        Session.text(provider)?.lowercased()
    }

    /// SPEC §9.5, in the order the rules are written: the provider decides first, the agent
    /// name only when the provider says nothing interesting.
    var family: SessionFamily {
        switch providerKey {
        case "local": return .local
        case "openrouter", "custom": return .api
        default: break
        }
        switch agent.name {
        case "claude": return .claude
        case "codex": return .codex
        default: return .other
        }
    }

    /// The chip never grows past this, whatever a reporter puts in `model`.
    static let modelDisplayLimit = 14

    /// Reasoning-effort tails Codex appends to a model name (`gpt-5.6-sol`, `gpt-5.6-high`).
    static let modelEffortSuffixes: Set<String> = ["sol", "minimal", "low", "medium", "high"]

    /// `Fable`, `Sonnet`, `Opus`, `Haiku`, `GPT-5.6`, `Llama` (SPEC §9.5).
    var modelDisplayName: String? {
        Session.modelDisplayName(model)
    }

    /// Strip the vendor prefix and the version noise; keep a GPT model's version, because that
    /// *is* its name. Anything whose shape is not recognisable comes back verbatim, capped at
    /// `modelDisplayLimit` — a chip that says something odd beats a chip that says nothing.
    static func modelDisplayName(_ raw: String?) -> String? {
        guard let value = text(raw) else { return nil }

        // `anthropic/claude-opus-5` and `claude-opus-5[1m]` both turn up in the wild.
        var stem = value.lowercased()
        if let slash = stem.lastIndex(of: "/") { stem = String(stem[stem.index(after: slash)...]) }
        if let bracket = stem.firstIndex(of: "[") { stem = String(stem[..<bracket]) }

        var parts = stem.split(separator: "-").map(String.init)
        while let last = parts.last, modelEffortSuffixes.contains(last) { parts.removeLast() }
        guard !parts.isEmpty else { return capped(value) }

        // Codex models keep their version: `gpt-5.6-sol` → `GPT-5.6`.
        if parts[0] == "gpt" {
            return capped((["GPT"] + parts.dropFirst()).joined(separator: "-"))
        }

        if parts[0] == "claude" { parts.removeFirst() }
        // `claude-3-5-sonnet-20241022` hides the family word behind the version.
        while let first = parts.first, isVersionNoise(first) { parts.removeFirst() }
        if let head = parts.first, isModelWord(head), parts.dropFirst().allSatisfy(isVersionNoise) {
            return head.capitalized
        }
        return capped(value)
    }

    private static func isModelWord(_ part: String) -> Bool {
        part.count >= 2 && part.allSatisfy { $0.isASCII && $0.isLetter }
    }

    /// `5`, `3.3`, `20251001`, `70b`, `1m`, `latest`, `preview` — everything that is a version
    /// and not a name.
    private static func isVersionNoise(_ part: String) -> Bool {
        if part == "latest" || part == "preview" { return true }
        guard let first = part.first, first.isNumber else { return false }
        return part.allSatisfy { $0.isNumber || $0 == "." || ($0.isASCII && $0.isLetter) }
    }

    private static func capped(_ value: String) -> String {
        guard value.count > modelDisplayLimit else { return value }
        return String(value.prefix(modelDisplayLimit - 1)) + "…"
    }

    /// The provider that needs no spelling out, per agent (SPEC §9.5).
    static func defaultProvider(for agent: SessionAgent) -> String? {
        switch agent.name {
        case "claude": return "anthropic"
        case "codex": return "openai"
        default: return nil
        }
    }

    static func providerLabel(_ raw: String?) -> String? {
        guard let key = text(raw)?.lowercased() else { return nil }
        switch key {
        case "anthropic": return "Anthropic"
        case "openai": return "OpenAI"
        case "openrouter": return "OpenRouter"
        case "local": return "Local"
        case "custom": return "Custom"
        default: return key.capitalized
        }
    }

    /// True when the provider is worth a word in the chip — i.e. it is not the agent's own.
    var showsProvider: Bool {
        guard let key = providerKey else { return false }
        return key != Session.defaultProvider(for: agent)
    }

    /// What the chip reads: `Fable`, `Fable · OpenRouter`, `Llama · Local` (SPEC §9.5).
    /// Nil when the reporter named no model, and the row keeps its agent glyph.
    var modelChip: String? {
        guard let name = modelDisplayName else { return nil }
        guard showsProvider, let label = Session.providerLabel(provider) else { return name }
        return "\(name) · \(label)"
    }

    /// The chip's tooltip: the model exactly as the reporter wrote it, plus the provider.
    var modelTooltip: String? {
        guard let raw = Session.text(model) else { return nil }
        guard let label = Session.providerLabel(provider) else { return raw }
        return "\(raw) · \(label)"
    }

    /// `⎇ wt-export-import` — the chip that says a tool event is running somewhere other
    /// than the session's own directory (SPEC §12.3). Nil when there is no worktree.
    var worktreeChip: String? {
        guard let name = Session.text(worktree) else { return nil }
        return "⎇ \(Session.truncate(name, to: Session.worktreeNameLimit))"
    }

    /// Measured against the 360 pt panel: line 1 of a row offers 234 pt, and
    /// `docs-site · Devin · ⎇ wt-export-impo…` needs 221 of them. Fourteen characters is what
    /// leaves the project name — the row's identity — whole; the full path is in the tooltip.
    static let worktreeNameLimit = 14

    /// The worktree chip's tooltip: where the tool events are really running, plus the model
    /// and sub-agent count the chip took the place of on line 1.
    var worktreeTooltip: String {
        var lines: [String] = []
        if let active = Session.text(activeCwd) { lines.append(active) }
        if let chip = modelChip { lines.append(chip) }
        if !subagents.isEmpty {
            let count = subagents.count
            lines.append("\(count) \(count == 1 ? "sub-agent" : "sub-agents")")
        }
        if lines.isEmpty { lines.append(Session.text(worktree) ?? "worktree") }
        return lines.joined(separator: "\n")
    }
}
