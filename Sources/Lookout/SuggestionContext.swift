import Foundation
import os

/// Where the card's suggested reply comes from (SPEC §11.4).
enum SuggestionSource: String, CaseIterable, Codable {
    case off
    case heuristic
    case ollama
    /// the owner's own Claude, through `claude -p` — his subscription, not an API key (SPEC §13.1).
    case claude

    var label: String {
        switch self {
        case .off: return "Off"
        case .heuristic: return "Heuristic"
        case .ollama: return "Ollama (local)"
        case .claude: return "Claude (subscription)"
        }
    }
}

/// What one `suggest` call produced. The card needs more than the text: when Claude was asked
/// and the heuristic answered instead, the status line has to say so (SPEC §13.2).
struct SuggestionOutcome: Equatable {
    var text: String?
    /// What actually produced `text`, which is not always what was asked for.
    var source: SuggestionSource
    /// The one line for the card's status, or nil when the asked-for source answered.
    var note: String?

    static let claudeFallbackNote = "Claude unavailable → heuristic"

    static func value(_ text: String?, from source: SuggestionSource) -> SuggestionOutcome {
        SuggestionOutcome(text: text, source: source, note: nil)
    }
}

/// What the card is asking about, flattened into the few facts a suggestion needs. Nothing here
/// leaves the machine: the only consumer beyond the heuristic is a local Ollama (SPEC §11.2).
struct SuggestionContext: Equatable {
    enum Kind: Equatable {
        case permission
        case question
        case done
    }

    var kind: Kind
    var project: String = ""
    var toolName: String?
    var command: String?
    var question: String?
    var options: [String] = []
    var lastMessage: String?

    // SPEC §13.2 — the facts only the Claude prompt uses.
    /// Where the session runs (`Cursor`, `Terminal`, …), for the `{{host}}` placeholder.
    var host: String = ""
    /// The session's own model, verbatim from the reporter — not the suggester's model.
    var model: String?
    /// `desktop_title` when there is one, else `title` (SPEC §9.4).
    var title: String?
    /// The session's working directory: the suggester runs `claude -p` there so the model sees
    /// the right project (SPEC §13.2).
    var cwd: String = ""
    /// `transcript_path` from the state file; read lazily by `loadTranscript()`.
    var transcriptPath: String?
    /// The last six user/assistant turns, oldest first. Empty until `loadTranscript()` runs.
    var turns: [TranscriptTurn] = []
    /// `Danish` or `English`, guessed from the last thing the developer wrote.
    var language: String = LanguageGuess.english

    init(kind: Kind) { self.kind = kind }

    /// The card's own view of a session plus its request. Cheap on purpose — it runs on the
    /// main thread, so the transcript is left for `loadTranscript()` to read off it.
    init(session: Session, request: AttentionRequest?) {
        project = session.project
        lastMessage = session.lastMessage
        host = session.host == .unknown ? "" : session.host.chip
        model = Session.text(session.model)
        title = session.displayTitle
        cwd = session.cwd
        transcriptPath = Session.text(session.transcriptPath)
        language = LanguageGuess.guess(title)
        // SPEC §17.7: there is no AskUserQuestion-equivalent hook for Codex, so no request the
        // *reporter* writes for one is ever really a question — but this is defended here too,
        // not just trusted upstream, so a stray or malformed request file can never open a
        // Codex session's card with option buttons that answer nothing. Bug fix 2026-09-04:
        // `CodexQuestionWatcher` now builds a genuine in-memory question for Codex by reading the
        // rollout file itself (never the reporter) — `isCodexQuestion` is what tells the two
        // apart, so that one alone is exempt from the coercion below.
        let isCodex = session.agent == .codex
        let isRealCodexQuestion = isCodex && (request?.isCodexQuestion ?? false)
        switch request?.kind {
        case .permission:
            kind = .permission
            toolName = Session.text(request?.toolName) ?? session.detailTool
            command = Session.text(request?.commandOrPath) ?? session.detailArgument
        case .question where !isCodex || isRealCodexQuestion:
            kind = .question
            question = Session.text(request?.question) ?? Session.text(request?.summary)
                ?? session.detail
            options = request?.options ?? []
        case .question:
            // Codex, coerced: a stray/malformed reporter file — present it as the permission
            // ask it must actually be.
            kind = .permission
            toolName = Session.text(request?.toolName) ?? session.detailTool
            command = Session.text(request?.commandOrPath) ?? session.detailArgument
        case nil:
            if session.state == .done {
                kind = .done
            } else if session.reason == "question", !isCodex {
                kind = .question
                question = Session.text(session.detail)
            } else {
                kind = .permission
                toolName = session.detailTool
                command = session.detailArgument
            }
        }
    }

    /// The prompt body handed to the model — plain facts, one per line.
    var promptText: String {
        var lines: [String] = []
        if !project.isEmpty { lines.append("Project: \(project)") }
        switch kind {
        case .permission:
            lines.append("The agent is asking permission to run a tool.")
            if let toolName { lines.append("Tool: \(toolName)") }
            if let command { lines.append("Command or path: \(String(command.prefix(600)))") }
            lines.append("Answer as the developer: approve, refuse, or ask for a change.")
        case .question:
            lines.append("The agent asked the developer a question.")
            if let question { lines.append("Question: \(String(question.prefix(600)))") }
            if !options.isEmpty {
                lines.append("Offered options: \(options.joined(separator: " | "))")
            }
        case .done:
            lines.append("The agent finished its turn and is waiting for the next instruction.")
            if let lastMessage {
                lines.append("Last message: \(String(lastMessage.prefix(600)))")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - The Claude prompt (SPEC §13.2)

    /// SPEC §13.2: the whole context handed to the model stays under 6 KB.
    static let maxPromptBytes = 6 * 1024

    /// Reads the transcript tail and re-guesses the language from it. File IO — never on the
    /// main thread. Idempotent: calling it twice reads the file twice and lands on the same
    /// answer, which is what a ↻ should do.
    mutating func loadTranscript() {
        turns = TranscriptTail.turns(path: transcriptPath)
        if let lastUser = turns.last(where: { $0.role == "user" })?.text {
            language = LanguageGuess.guess(lastUser)
        }
    }

    /// The exact thing being asked, for `{{ask}}`.
    var ask: String {
        switch kind {
        case .permission:
            let tool = Session.text(toolName)
            guard let command = Session.text(command) else {
                return tool.map { "The agent wants to run \($0)." } ?? "The agent wants permission."
            }
            guard let tool else { return command }
            return "\(tool): \(command)"
        case .question:
            return Session.text(question) ?? "The agent asked you a question."
        case .done:
            return "The agent finished its turn and is waiting for the next instruction."
        }
    }

    var kindName: String {
        switch kind {
        case .permission: return "permission"
        case .question: return "question"
        case .done: return "done"
        }
    }

    /// The ten placeholder values (SPEC §13.2). `turns` decides `recent_turns`; the caller
    /// trims it from the oldest end when the whole prompt does not fit.
    func values(turns: [TranscriptTurn]) -> [String: String] {
        [
            "kind": kindName,
            "ask": ask,
            "options": options.isEmpty ? "" : options.joined(separator: " | "),
            "project": project,
            "host": host,
            "model": model ?? "",
            "title": title ?? "",
            "last_assistant": lastMessage ?? "",
            "recent_turns": turns.map(\.line).joined(separator: "\n"),
            "language": language,
        ]
    }

    /// Fills the template and keeps the result under `maxPromptBytes` by dropping the oldest
    /// turn until it fits — the ask itself is never the thing that gets cut, and only a prompt
    /// that is still too big with no turns at all is truncated outright.
    func prompt(template: String, limit: Int = SuggestionContext.maxPromptBytes) -> SuggestPrompt {
        var kept = turns
        while true {
            let rendered = SuggestPromptTemplate.render(template, values: values(turns: kept))
            if rendered.user.utf8.count <= limit { return rendered }
            guard !kept.isEmpty else {
                return SuggestPrompt(
                    system: rendered.system,
                    user: SuggestionContext.clip(rendered.user, toBytes: limit)
                )
            }
            kept.removeFirst()
        }
    }

    /// Cuts on a character boundary, never mid-scalar, so the byte cap cannot produce mojibake.
    static func clip(_ text: String, toBytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var result = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            if bytes + size > limit { break }
            result.append(character)
            bytes += size
        }
        return result
    }
}

/// The offline fallback (SPEC §11.2) — and what every card starts with while a model thinks.
enum Heuristic {
    static func suggestion(for context: SuggestionContext) -> String {
        switch context.kind {
        case .permission:
            guard let command = Session.text(context.command) else {
                guard let tool = Session.text(context.toolName) else { return "Allow" }
                return "Allow — runs \(tool)"
            }
            // A permission command is often several lines; the suggestion is one.
            let flat = command
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            return "Allow — runs `\(Session.truncate(flat, to: 72))`"
        case .question:
            if let first = context.options.compactMap(Session.text).first { return first }
            return "Yes, go ahead"
        case .done:
            return "Continue with the next step"
        }
    }
}

/// One model Ollama has pulled.
