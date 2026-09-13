import Foundation

extension Session {
    // MARK: - Answering from the widget (SPEC §11.4)

    /// The messaging socket is Claude-only and undocumented; without one, the card offers
    /// Copy & go alone (SPEC §11.2).
    var canSendMessage: Bool {
        agent == .claude && (Session.text(messagingSocket) != nil || (pid ?? 0) > 0)
    }

    /// True when `isHeld` should actually change anything: `needs_you` always wins, so even a
    /// session that somehow still carries a stale hold (in practice `AppState` clears it via
    /// `SessionHold` before this is ever read) is never treated as held here. Internal, not
    /// private — `StateFilter.of(_:)` and the row's accent colour ask the same question.
    var isEffectivelyHeld: Bool { isHeld && state != .needsYou }

    /// What `Session.sorted` actually orders by: a held session sorts at
    /// `SessionState.heldSortRank`, below idle; every other session — including a `needs_you`
    /// one that is somehow still marked `isHeld` — keeps its own state's rank.
    var sortRank: Int { isEffectivelyHeld ? SessionState.heldSortRank : state.sortRank }

    var statusLabel: String {
        // A held session shows "On hold" whatever it was doing underneath — that is the whole
        // point of holding it. `needs_you` always wins regardless (`isEffectivelyHeld` above),
        // so this never hides a permission or a question.
        if isEffectivelyHeld { return "On hold" }
        switch state {
        case .needsYou:
            if reason == "question" { return "Question for you" }
            if let tool = detailTool { return "Needs permission · \(tool)" }
            return "Needs permission"
        case .done:
            return "Finished"
        case .working:
            return "Working…"
        case .running:
            return "Running · no hooks"
        case .idle:
            return "Idle"
        }
    }

    /// SPEC §15.3, line 2 of a row: what this session actually *is*. A home-folder name is not
    /// it, so the folder name on line 1 is never the whole answer — the desktop app's own title
    /// first, then the first prompt, and for a row discovered without hooks (which has neither)
    /// the working directory it is running in.
    var sessionName: String? {
        if let shown = displayTitle {
            return Session.truncate(shown, to: Session.sessionNameLimit)
        }
        guard let path = Session.text(cwd) else { return nil }
        return Format.tildePath(path)
    }

    /// SPEC §15.4: what line 2 of a row shows, what the card's header says under the project,
    /// and what a Rename… field is prefilled with — the custom name when there is one, else
    /// whatever §15.3 worked out.
    var displayName: String? {
        if let custom = Session.text(customName) {
            return Session.truncate(custom, to: Session.sessionNameLimit)
        }
        return sessionName
    }

    /// SPEC §15.4, for the two places that have room for exactly one word about a session and
    /// spent it on the folder: the notification title and the Agents tab's parent line. A custom
    /// name is what the owner would rather read there; without one they keep the project they had,
    /// because a first prompt or a full path fits neither.
    var displayLabel: String { Session.text(customName) ?? project }

    /// A path is truncated in the middle (the last component is the informative half), a title
    /// at the end. A custom name is a name, never a path.
    var sessionNameIsPath: Bool { Session.text(customName) == nil && displayTitle == nil }

    /// Long titles are cut here, not by the label, so the row reads the same at every width.
    static let sessionNameLimit = 90

    /// SPEC §15.3, line 3: the detail, minus anything line 2 has already said — a `running` row
    /// whose only detail is its title would otherwise print the same string twice.
    var rowDetail: String? {
        guard let text = secondaryText else { return nil }
        // `running` puts the raw cwd on the old second line and line 2 shows it shortened —
        // the same fact either way, so compare both spellings. Both names are checked: a
        // renamed session still must not repeat the title line 2 used to carry (SPEC §15.4).
        for name in [displayName, sessionName].compactMap({ $0 }) {
            if text == name || Format.tildePath(text) == name { return nil }
        }
        return text
    }

    /// The secondary, dimmed half of line 2.
    var secondaryText: String? {
        switch state {
        case .done:
            return lastMessage ?? displayTitle
        case .needsYou:
            return detailArgument ?? displayTitle ?? detail
        case .running:
            return displayTitle ?? (cwd.isEmpty ? nil : cwd)
        case .working:
            // A working session with sub-agents says what they are doing (SPEC §9.3).
            if let text = subagentText { return text }
            return displayTitle ?? detail
        default:
            return displayTitle ?? detail
        }
    }

    /// `3 agents · Review the diff…` — the working line when sub-agents are running (SPEC §9.3).
    var subagentText: String? {
        guard !subagents.isEmpty else { return nil }
        let count = subagents.count
        let head = "\(count) \(count == 1 ? "agent" : "agents")"
        let first = subagents
            .compactMap { $0.description?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let first else { return head }
        return "\(head) · \(Session.truncate(first, to: Session.subagentDescriptionLimit))"
    }

    /// Long descriptions are cut here rather than by the label, so the row text is the same
    /// whatever the panel is doing with its width.
    static let subagentDescriptionLimit = 48

    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    var tooltip: String {
        var lines = [cwd.isEmpty ? project : cwd]
        // SPEC §15.4: a renamed row shows the custom name, so the tooltip is the only place the
        // name it replaced still exists.
        if let custom = Session.text(customName) {
            lines.append(custom)
            if let original = sessionName, original != custom, original != lines[0],
               Format.tildePath(lines[0]) != original {
                lines.append("Was: \(original)")
            }
        } else if let shown = displayTitle {
            lines.append(shown)
        }
        // SPEC §9.4: when the desktop app's title has drifted from the first prompt, the tooltip
        // is where both are visible at once — the row only has room for one.
        if let desktop = Session.text(desktopTitle), let prompt = Session.text(title),
           desktop != prompt {
            lines.append("Prompt: \(prompt)")
        }
        // SPEC §12.3: the row keeps the main session's project; the worktree a tool event ran
        // in only ever shows up here and in the chip, so it can never hijack the title.
        if let active = Session.text(activeCwd), active != cwd {
            lines.append("Active: \(active)")
        }
        // The chip that took the model's slot on line 1 puts it here instead.
        if worktreeChip != nil, let model = modelTooltip { lines.append(model) }
        if !isDiscovered { lines.append("Session \(sessionID)") }
        if let tty, !tty.isEmpty { lines.append("tty \(tty)") }
        if let pid { lines.append("pid \(pid)") }
        // One line per sub-agent: `type · model · description` (SPEC §9.3).
        lines.append(contentsOf: subagents.map(\.summary))
        return lines.joined(separator: "\n")
    }

    /// Seconds spent in the current state, for the live duration label.
    func timeInState(now: Date = Date()) -> TimeInterval {
        guard let since = stateSince ?? updatedAt ?? startedAt else { return 0 }
        return max(0, now.timeIntervalSince(since))
    }
}
