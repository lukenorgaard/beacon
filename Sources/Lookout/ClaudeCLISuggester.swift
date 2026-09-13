import Foundation
import os

/// Finding `claude` on this Mac (SPEC §13.2), in the order the spec lists.
///
/// Every input is injected so the order itself is testable against a temp layout: the tests
/// build a directory tree, hand it in as `home` and `environment`, and assert which path wins.
enum ClaudeBinary {
    /// SPEC §13.2's third group, after `.npm-global` and `which`.
    static let fallbackPaths = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]

    static func npmGlobal(home: URL) -> URL {
        home.appendingPathComponent(".npm-global/bin/claude")
    }

    static func desktopRoot(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Claude/claude-code")
    }

    /// SPEC §13.2:
    /// 1. an explicit override from Settings (the user's word beats every rule below),
    /// 2. `~/.npm-global/bin/claude`,
    /// 3. the first of `which claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`,
    /// 4. the newest desktop bundle.
    static func discover(
        override: String? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        if let override = Session.text(override) {
            let expanded = (override as NSString).expandingTildeInPath
            if fileManager.isExecutableFile(atPath: expanded) { return expanded }
        }
        let npm = npmGlobal(home: home).path
        if fileManager.isExecutableFile(atPath: npm) { return npm }
        if let onPath = which(environment: environment, fileManager: fileManager) { return onPath }
        for candidate in fallbackPaths where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return newestDesktopBundle(home: home, fileManager: fileManager)
    }

    /// `which claude`, without spawning a shell to ask: the same PATH scan, left to right.
    static func which(
        _ name: String = "claude",
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> String? {
        guard let path = Session.text(environment["PATH"]) else { return nil }
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(name).path
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// `~/Library/Application Support/Claude/claude-code/<newest>/claude.app/Contents/MacOS/claude`.
    /// "Newest" is the highest version-looking directory name, compared numerically so `2.1.9`
    /// loses to `2.1.10` — a plain string sort gets that backwards.
    static func newestDesktopBundle(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> String? {
        let root = desktopRoot(home: home)
        guard let entries = try? fileManager.contentsOfDirectory(atPath: root.path) else {
            return nil
        }
        let sorted = entries
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        for version in sorted.reversed() {
            let candidate = root
                .appendingPathComponent(version)
                .appendingPathComponent("claude.app/Contents/MacOS/claude").path
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

/// The `claude -p` invocation itself (SPEC §13.2) — argument list, environment, result cleanup.
/// Static functions only, so the shape of the call is testable without running anything.
enum ClaudeCLI {
    /// SPEC §13.2.
    static let timeout: TimeInterval = 25
    /// SPEC §13.2: the suggestion never exceeds this.
    static let maxLength = 300
    static let models = ["haiku", "sonnet", "opus"]
    static let defaultModel = "haiku"

    /// The four `CLAUDE_*` id/pid variables §13.2 says to unset, plus the messaging pair and the
    /// OAuth token: a helper process has no business inheriting the parent session's identity,
    /// its socket, or a credential (SPEC §11.2 — the token never leaves the app's memory).
    static let strippedKeys = [
        "CLAUDECODE",
        "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_HOST_SESSION_ID",
        "CLAUDE_PID",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_MESSAGING_SOCKET",
        "CLAUDE_CODE_MESSAGING_TOKEN",
        "CLAUDE_CODE_OAUTH_TOKEN",
    ]

    /// SPEC §13.2: `LOOKOUT_IGNORE=1` so the reporter exits at once for this process and the
    /// helper never shows up as a session, and `CLAUDE_CODE_CHILD_SESSION=1` so it writes no
    /// transcript.
    static func environment(inheriting base: [String: String]) -> [String: String] {
        var env = base
        for key in strippedKeys { env.removeValue(forKey: key) }
        env["LOOKOUT_IGNORE"] = "1"
        env["CLAUDE_CODE_CHILD_SESSION"] = "1"
        return env
    }

    static func arguments(
        model: String, systemPromptFile: String, userPrompt: String
    ) -> [String] {
        [
            "-p",
            "--model", model,
            "--output-format", "text",
            "--append-system-prompt-file", systemPromptFile,
            userPrompt,
        ]
    }

    /// Where the helper runs: the session's `cwd` when it still exists, else home (SPEC §13.2).
    static func workingDirectory(
        cwd: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL {
        guard let path = Session.text(cwd) else { return home }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return home }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// SPEC §13.2's result rule: trimmed, first non-empty paragraph, ≤ 300 chars. A model that
    /// quotes its own answer gets unquoted — the field is for the message, not for a citation.
    static func clean(_ raw: String, limit: Int = maxLength) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var current: [String] = []
        for line in trimmed.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { break }
                continue
            }
            current.append(line)
        }
        var paragraph = current.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paragraph.isEmpty else { return nil }
        if paragraph.count >= 2, paragraph.hasPrefix("\""), paragraph.hasSuffix("\"") {
            paragraph = String(paragraph.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !paragraph.isEmpty else { return nil }
        guard paragraph.count > limit else { return paragraph }
        return String(paragraph.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Asks the owner's own Claude for the suggestion, through the CLI on his subscription (SPEC §13.1).
///
/// Nothing here runs on the main thread, nothing here is logged with content, and every failure
/// — no binary, a non-zero exit, an empty reply, the 25 s timeout — comes back as `nil` so the
/// caller can fall back to the heuristic.
final class ClaudeCLISuggester {
    /// One attempt, for the log line and the card's status.
    struct Outcome {
        var text: String?
        /// `ok`, `timeout`, `no-binary`, `empty`, `exit-1`, `no-temp-file`.
        var reason: String
        var durationMS: Int
        var model: String
    }

    private let log = Logger(subsystem: "io.github.lukenorgaard.beacon", category: "claude-suggest")
    private let home: LookoutHome
    private let queue = DispatchQueue(
        label: "io.github.lukenorgaard.beacon.claude-suggest", qos: .userInitiated
    )

    /// Seam for the tests: the whole child-process call in one closure.
    var runner: (String, [String], [String: String], URL, TimeInterval) -> Shell.Result
    /// SPEC §13.2's 25 s, overridable so a test can prove the timeout path in under a second.
    var timeout: TimeInterval = ClaudeCLI.timeout

    init(home: LookoutHome = LookoutHome()) {
        self.home = home
        self.runner = { binary, arguments, environment, directory, timeout in
            Shell.run(
                binary, arguments, timeout: timeout,
                environment: environment, currentDirectory: directory
            )
        }
    }

    /// Off the main thread; `completion` lands back on it. `template` is read from
    /// `~/.lookout/suggest-prompt.md` when the caller does not supply one, so an edit in
    /// Settings takes effect on the very next ↻ without anything having to be reloaded.
    func suggest(
        for context: SuggestionContext,
        model: String,
        binaryOverride: String?,
        template: String? = nil,
        completion: @escaping (Outcome) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            var enriched = context
            enriched.loadTranscript()
            let text = template ?? SuggestPromptTemplate.load(in: self.home)
            let outcome = self.run(
                context: enriched, model: model, override: binaryOverride, template: text
            )
            self.record(outcome)
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// The blocking half — public to the module so a test can drive it without a run loop.
    func run(
        context: SuggestionContext,
        model: String,
        override: String?,
        template: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Outcome {
        let started = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(started) * 1000) }

        guard let binary = ClaudeBinary.discover(
            override: override, home: homeDirectory, environment: environment
        ) else {
            return Outcome(text: nil, reason: "no-binary", durationMS: elapsed(), model: model)
        }

        let prompt = context.prompt(template: template)
        guard let systemFile = ClaudeCLISuggester.writeSystemPrompt(prompt.system) else {
            return Outcome(text: nil, reason: "no-temp-file", durationMS: elapsed(), model: model)
        }
        defer { try? FileManager.default.removeItem(at: systemFile) }

        let result = runner(
            binary,
            ClaudeCLI.arguments(
                model: model, systemPromptFile: systemFile.path, userPrompt: prompt.user
            ),
            ClaudeCLI.environment(inheriting: environment),
            ClaudeCLI.workingDirectory(cwd: context.cwd, home: homeDirectory),
            timeout
        )

        if result.timedOut {
            return Outcome(text: nil, reason: "timeout", durationMS: elapsed(), model: model)
        }
        guard result.exitCode == 0 else {
            return Outcome(
                text: nil, reason: "exit-\(result.exitCode)",
                durationMS: elapsed(), model: model
            )
        }
        guard let text = ClaudeCLI.clean(result.stdout) else {
            return Outcome(text: nil, reason: "empty", durationMS: elapsed(), model: model)
        }
        return Outcome(text: text, reason: "ok", durationMS: elapsed(), model: model)
    }

    /// The system half goes in a 600 file under the temp directory; `--append-system-prompt-file`
    /// reads it and the `defer` above deletes it, so the prompt never lingers on disk.
    static func writeSystemPrompt(_ text: String) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lookout-suggest-\(UUID().uuidString).md")
        guard let data = text.data(using: .utf8) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
            return url
        } catch {
            return nil
        }
    }

    /// SPEC §13.2: `~/.lookout/suggest.log` gets source, model, duration and outcome — and no
    /// part of the prompt or the reply, ever.
    private func record(_ outcome: Outcome) {
        LogFile.append(
            "source=claude model=\(outcome.model) duration_ms=\(outcome.durationMS) "
                + "outcome=\(outcome.reason)",
            to: home.suggestLog
        )
    }
}
