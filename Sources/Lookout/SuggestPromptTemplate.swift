import Foundation

/// The two halves of one filled prompt: what goes in `--append-system-prompt-file`, and what is
/// passed as the `claude -p` argument (SPEC §13.2).
struct SuggestPrompt: Equatable {
    var system: String
    var user: String
}

/// `~/.lookout/suggest-prompt.md` — the editable template behind every Claude suggestion
/// (SPEC §13.2). The file is plain Markdown split by two marker lines, so it stays readable and
/// hand-editable; the Settings editor writes the same text back.
///
/// Everything here is a pure function over strings except `load`/`save`/`reset`, which is what
/// lets the tests cover the split and the substitution without touching a real home directory.
enum SuggestPromptTemplate {
    static let fileName = "suggest-prompt.md"
    static let systemMarker = "---system---"
    static let userMarker = "---user---"

    /// The ten names §13.2 lists, in the order the default template uses them.
    static let placeholders = [
        "kind", "ask", "options", "project", "host", "model",
        "title", "last_assistant", "recent_turns", "language",
    ]

    /// SPEC §13.2, verbatim — one paragraph, because that is how it is quoted in the spec.
    static let defaultSystem =
        "You draft the one-line reply a developer sends to a coding agent that is waiting for "
        + "them. Be decisive. Permission: say allow or deny and why in ≤ 12 words. Question: "
        + "pick the best option and say why in ≤ 20 words. Otherwise: the next instruction, "
        + "≤ 30 words. Reply with the message only."

    /// The user half: the filled context, one fact per line.
    static let defaultUser = """
    Request: {{kind}}
    Ask: {{ask}}
    Options: {{options}}
    Project: {{project}}
    Host: {{host}}
    Model: {{model}}
    Title: {{title}}
    Last assistant message: {{last_assistant}}

    Recent turns:
    {{recent_turns}}

    Answer in {{language}} — the language the developer last wrote in.
    """

    static var defaultText: String {
        """
        \(systemMarker)
        \(defaultSystem)

        \(userMarker)
        \(defaultUser)
        """
    }

    // MARK: - Parsing

    /// Lenient on purpose: a file the user edited into nonsense must still produce a prompt.
    /// Text before any marker counts as the system half, and a missing user half falls back to
    /// the default one — an empty user prompt would be the only unrecoverable shape.
    static func parse(_ raw: String) -> SuggestPrompt {
        var system: [String] = []
        var user: [String] = []
        var inUser = false
        for line in raw.components(separatedBy: .newlines) {
            let marker = line.trimmingCharacters(in: .whitespaces)
            if marker == systemMarker {
                inUser = false
                continue
            }
            if marker == userMarker {
                inUser = true
                continue
            }
            if inUser { user.append(line) } else { system.append(line) }
        }
        let systemText = system.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let userText = user.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SuggestPrompt(
            system: systemText.isEmpty ? defaultSystem : systemText,
            user: userText.isEmpty ? defaultUser : userText
        )
    }

    /// `{{kind}}` → its value. Only the ten known names are touched: anything else the user
    /// typed stays on screen, which is the only way they can tell they mistyped one.
    static func substitute(_ text: String, values: [String: String]) -> String {
        var result = text
        for name in placeholders {
            let value = values[name].flatMap(Session.text) ?? "(none)"
            result = result.replacingOccurrences(of: "{{\(name)}}", with: value)
        }
        return result
    }

    static func render(_ raw: String, values: [String: String]) -> SuggestPrompt {
        let template = parse(raw)
        return SuggestPrompt(
            system: substitute(template.system, values: values),
            user: substitute(template.user, values: values)
        )
    }

    // MARK: - The file

    static func url(in home: LookoutHome) -> URL {
        home.root.appendingPathComponent(fileName)
    }

    /// Reads the template, creating it from the default on first use (SPEC §13.2). A file that
    /// cannot be read is *not* overwritten — the default is used for this call and whatever the
    /// user has in there survives for them to fix.
    static func load(in home: LookoutHome) -> String {
        let file = url(in: home)
        if let data = try? Data(contentsOf: file),
           let text = String(data: data, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        if !FileManager.default.fileExists(atPath: file.path) {
            _ = save(defaultText, in: home)
        }
        return defaultText
    }

    @discardableResult
    static func save(_ text: String, in home: LookoutHome) -> Bool {
        guard home.ensure(home.root), let data = text.data(using: .utf8) else { return false }
        let file = url(in: home)
        let temporary = file.appendingPathExtension("tmp")
        let fm = FileManager.default
        do {
            try data.write(to: temporary, options: .atomic)
            if fm.fileExists(atPath: file.path) {
                _ = try fm.replaceItemAt(file, withItemAt: temporary)
            } else {
                try fm.moveItem(at: temporary, to: file)
            }
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch {
            try? fm.removeItem(at: temporary)
            return false
        }
    }

    @discardableResult
    static func reset(in home: LookoutHome) -> String {
        _ = save(defaultText, in: home)
        return defaultText
    }
}
