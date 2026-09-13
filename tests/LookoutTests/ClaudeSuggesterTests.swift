import XCTest
@testable import Lookout

/// SPEC §13.2: binary discovery, the context the prompt is built from, the template file, the
/// result rule, and the CLI runner itself — against a fake `claude` on PATH, never the real one.
final class ClaudeSuggesterTests: XCTestCase {
    var temporary: URL!

    override func setUpWithError() throws {
        temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporary, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    // MARK: - Helpers

    @discardableResult
    func script(_ name: String, in directory: URL, body: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
        return url
    }

    /// Hides the two absolute fallback paths from discovery, so a Mac that really does have
    /// `/opt/homebrew/bin/claude` cannot turn a "nothing to find" assertion into a real call.
    private final class BlindFileManager: FileManager {
        let blocked: Set<String>
        init(blocking: [String]) {
            blocked = Set(blocking)
            super.init()
        }
        override func isExecutableFile(atPath path: String) -> Bool {
            blocked.contains(path) ? false : super.isExecutableFile(atPath: path)
        }
    }

    var blind: FileManager { BlindFileManager(blocking: ClaudeBinary.fallbackPaths) }

    func home(_ name: String) throws -> URL {
        let url = temporary.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Binary discovery (SPEC §13.2)

    func testDiscoveryPrefersNpmGlobalThenPathThenTheDesktopBundle() throws {
        let fakeHome = try home("home")
        let pathDirectory = temporary.appendingPathComponent("bin")
        try script("claude", in: pathDirectory, body: "#!/bin/sh\nexit 0\n")
        let environment = ["PATH": pathDirectory.path]

        // Nothing in `.npm-global` yet: PATH wins, exactly as `which claude` would.
        XCTAssertEqual(
            ClaudeBinary.discover(home: fakeHome, environment: environment),
            pathDirectory.appendingPathComponent("claude").path
        )

        // `.npm-global` outranks PATH.
        let npm = try script(
            "claude", in: fakeHome.appendingPathComponent(".npm-global/bin"),
            body: "#!/bin/sh\nexit 0\n"
        )
        XCTAssertEqual(
            ClaudeBinary.discover(home: fakeHome, environment: environment), npm.path
        )

        // The Settings override outranks everything…
        let override = try script(
            "claude-override", in: temporary, body: "#!/bin/sh\nexit 0\n"
        )
        XCTAssertEqual(
            ClaudeBinary.discover(
                override: override.path, home: fakeHome, environment: environment
            ),
            override.path
        )
        // …unless it points at something that is not there, in which case the order resumes.
        XCTAssertEqual(
            ClaudeBinary.discover(
                override: "/nope/claude", home: fakeHome, environment: environment
            ),
            npm.path
        )

        // Empty PATH and no npm binary: nothing on this temp home to find.
        try FileManager.default.removeItem(at: npm)
        XCTAssertNil(
            ClaudeBinary.discover(
                home: fakeHome, environment: ["PATH": ""], fileManager: blind
            )
        )

        // The last resort, and the order §13.2 lists for the middle group.
        XCTAssertEqual(
            ClaudeBinary.fallbackPaths, ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        )
    }

    func testTheNewestDesktopBundleIsComparedNumericallyNotAlphabetically() throws {
        let fakeHome = try home("desktop-home")
        let root = ClaudeBinary.desktopRoot(home: fakeHome)
        for version in ["2.1.9", "2.1.10", "2.0.4"] {
            try script(
                "claude",
                in: root.appendingPathComponent("\(version)/claude.app/Contents/MacOS"),
                body: "#!/bin/sh\nexit 0\n"
            )
        }
        let found = try XCTUnwrap(ClaudeBinary.newestDesktopBundle(home: fakeHome))
        XCTAssertTrue(found.contains("/2.1.10/"), found)

        // With nothing else on this temp home, discovery lands there too.
        XCTAssertEqual(
            ClaudeBinary.discover(
                home: fakeHome, environment: ["PATH": ""], fileManager: blind
            ),
            found
        )
    }

    // MARK: - The context builder (SPEC §13.2)

    func testTheTranscriptTailKeepsSixRealTurnsAndDropsToolNoise() throws {
        let turns = TranscriptTail.turns(path: Fixtures.transcript.path)
        XCTAssertEqual(turns.count, TranscriptTail.maxTurns)

        // Oldest first, and the two turns before them fell off the six-turn cap.
        XCTAssertEqual(turns.first?.role, "user")
        XCTAssertEqual(turns.first?.text, "Run the migrations for me")
        XCTAssertFalse(turns.contains { $0.text.contains("also dropped") })
        XCTAssertFalse(turns.contains { $0.text == "dropped assistant reply" })

        // tool_use text never survives, and a user message that is only a tool_result is not
        // a turn at all.
        XCTAssertEqual(turns[1].text, "Starting with 004.")
        XCTAssertFalse(turns.contains { $0.text.contains("psql -f 004.sql") })
        XCTAssertFalse(turns.contains { $0.text.contains("tool_result") })
        // The meta line the CLI writes as if the user had is not the user.
        XCTAssertFalse(turns.contains { $0.text.contains("system-reminder") })
        // `thinking` blocks are not text either.
        XCTAssertFalse(turns.contains { $0.text.contains("hidden") })

        // Assistant text is cut at 600 characters, ellipsis included.
        let long = try XCTUnwrap(turns.first { $0.text.hasPrefix("AAA") })
        XCTAssertEqual(long.role, "assistant")
        XCTAssertEqual(long.text.count, TranscriptTail.assistantLimit)
        XCTAssertTrue(long.text.hasSuffix("…"))

        XCTAssertEqual(turns.last?.role, "user")
        XCTAssertEqual(turns.last?.text, "Ja tak, kør 005 bagefter og sig til hvis noget fejler")
    }

    func testOnlyTheTailIsRead() throws {
        // 200 KB of filler in front of one real turn: with a 64 KB tail the filler is gone, and
        // the fragment the tail starts in the middle of never decodes as a turn.
        let file = temporary.appendingPathComponent("big.jsonl")
        var text = String(repeating: "{\"type\":\"filler\",\"pad\":\"\(String(repeating: "x", count: 200))\"}\n", count: 900)
        text += "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"the last word\"}}\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertGreaterThan(
            try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0,
            TranscriptTail.maxBytes
        )

        let tail = try XCTUnwrap(TranscriptTail.read(path: file.path))
        XCTAssertLessThanOrEqual(tail.utf8.count, TranscriptTail.maxBytes)
        let turns = TranscriptTail.turns(path: file.path)
        XCTAssertEqual(turns.map(\.text), ["the last word"])
    }

    func testTheLanguageGuessFollowsTheLastThingTheDeveloperWrote() {
        XCTAssertEqual(LanguageGuess.guess("Kør den igen"), LanguageGuess.danish)
        XCTAssertEqual(LanguageGuess.guess("det virker ikke"), LanguageGuess.danish)
        XCTAssertEqual(LanguageGuess.guess("Please run the tests again"), LanguageGuess.english)
        XCTAssertEqual(LanguageGuess.guess("   "), LanguageGuess.english)
        XCTAssertEqual(LanguageGuess.guess(nil), LanguageGuess.english)

        // The transcript decides, not the title the session started with.
        var session = Session()
        session.title = "Run the migrations"
        session.transcriptPath = Fixtures.transcript.path
        var context = SuggestionContext(session: session, request: nil)
        XCTAssertEqual(context.language, LanguageGuess.english, "before the transcript is read")
        context.loadTranscript()
        XCTAssertEqual(context.language, LanguageGuess.danish)
        XCTAssertEqual(context.turns.count, 6)
    }

    // MARK: - The template (SPEC §13.2)

    func testTheTemplateSplitsOnItsTwoMarkersAndSurvivesAMangledFile() {
        let parsed = SuggestPromptTemplate.parse(SuggestPromptTemplate.defaultText)
        XCTAssertEqual(parsed.system, SuggestPromptTemplate.defaultSystem)
        XCTAssertEqual(parsed.user, SuggestPromptTemplate.defaultUser)

        // No `---user---`: everything is the system half and the default user half fills in.
        let systemOnly = SuggestPromptTemplate.parse("Be brief.")
        XCTAssertEqual(systemOnly.system, "Be brief.")
        XCTAssertEqual(systemOnly.user, SuggestPromptTemplate.defaultUser)

        // No `---system---`: the default system half fills in.
        let userOnly = SuggestPromptTemplate.parse("---user---\nAsk: {{ask}}")
        XCTAssertEqual(userOnly.system, SuggestPromptTemplate.defaultSystem)
        XCTAssertEqual(userOnly.user, "Ask: {{ask}}")
    }

    func testEveryPlaceholderIsSubstitutedAndAMissingOneReadsAsNone() {
        let values = Dictionary(
            uniqueKeysWithValues: SuggestPromptTemplate.placeholders.map { ($0, "<\($0)>") }
        )
        let filled = SuggestPromptTemplate.render(
            SuggestPromptTemplate.defaultText, values: values
        )
        for name in SuggestPromptTemplate.placeholders {
            XCTAssertFalse(filled.user.contains("{{\(name)}}"), name)
            XCTAssertTrue(filled.user.contains("<\(name)>"), name)
        }

        let empty = SuggestPromptTemplate.render(
            "---user---\n{{ask}} / {{options}} / {{nope}}", values: ["ask": "  "]
        )
        XCTAssertEqual(empty.user, "(none) / (none) / {{nope}}")
    }

    func testTheTemplateFileIsCreatedFromTheDefaultAndCanBeResetAfterAnEdit() throws {
        let home = LookoutHome(root: temporary.appendingPathComponent("lookout"))
        let file = SuggestPromptTemplate.url(in: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        XCTAssertEqual(SuggestPromptTemplate.load(in: home), SuggestPromptTemplate.defaultText)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        XCTAssertTrue(SuggestPromptTemplate.save("---system---\nMine.\n", in: home))
        XCTAssertEqual(SuggestPromptTemplate.load(in: home), "---system---\nMine.\n")
        XCTAssertEqual(SuggestPromptTemplate.parse(SuggestPromptTemplate.load(in: home)).system,
                       "Mine.")

        XCTAssertEqual(SuggestPromptTemplate.reset(in: home), SuggestPromptTemplate.defaultText)
        XCTAssertEqual(SuggestPromptTemplate.load(in: home), SuggestPromptTemplate.defaultText)
    }

    func testThePromptCarriesTheAskAndStaysUnderSixKilobytes() throws {
        var session = Session()
        session.project = "daily-notes"
        session.host = .cursor
        session.model = "claude-opus-5"
        session.desktopTitle = "Journal migrations"
        session.transcriptPath = Fixtures.transcript.path

        var request = AttentionRequest()
        request.kind = .permission
        request.toolName = "Bash"
        request.commandOrPath = "psql -f 005.sql"

        var context = SuggestionContext(session: session, request: request)
        context.loadTranscript()
        let prompt = context.prompt(template: SuggestPromptTemplate.defaultText)

        XCTAssertEqual(prompt.system, SuggestPromptTemplate.defaultSystem)
        XCTAssertTrue(prompt.user.contains("Request: permission"))
        XCTAssertTrue(prompt.user.contains("Ask: Bash: psql -f 005.sql"))
        XCTAssertTrue(prompt.user.contains("Project: daily-notes"))
        XCTAssertTrue(prompt.user.contains("Host: Cursor"))
        XCTAssertTrue(prompt.user.contains("Model: claude-opus-5"))
        XCTAssertTrue(prompt.user.contains("Title: Journal migrations"))
        XCTAssertTrue(prompt.user.contains("Answer in Danish"))
        XCTAssertTrue(prompt.user.contains("user: Run the migrations for me"))
        XCTAssertLessThanOrEqual(prompt.user.utf8.count, SuggestionContext.maxPromptBytes)

        // A transcript far too big for the budget loses its oldest turns, never its ask.
        var fat = context
        fat.turns = (0..<6).map {
            TranscriptTurn(role: "user", text: "\($0) " + String(repeating: "z", count: 4000))
        }
        let trimmed = fat.prompt(template: SuggestPromptTemplate.defaultText)
        XCTAssertLessThanOrEqual(trimmed.user.utf8.count, SuggestionContext.maxPromptBytes)
        XCTAssertTrue(trimmed.user.contains("Ask: Bash: psql -f 005.sql"))
        XCTAssertTrue(trimmed.user.contains("user: 5 zzz"))
        XCTAssertFalse(trimmed.user.contains("user: 0 zzz"))
    }

    // MARK: - The result rule (SPEC §13.2)

    func testTheResultIsTheFirstParagraphTrimmedAndCappedAt300() {
        XCTAssertEqual(
            ClaudeCLI.clean("\n\n  Allow — it only reads files.\n\nThen run the tests.\n"),
            "Allow — it only reads files."
        )
        // A paragraph may still be several lines; the blank line is what ends it.
        XCTAssertEqual(ClaudeCLI.clean("one\ntwo\n\nthree"), "one\ntwo")
        // A model that quotes itself gets unquoted.
        XCTAssertEqual(ClaudeCLI.clean("\"Deny — it deletes the build.\""),
                       "Deny — it deletes the build.")
        XCTAssertNil(ClaudeCLI.clean("   \n\n  "))
        XCTAssertNil(ClaudeCLI.clean(""))

        let long = ClaudeCLI.clean(String(repeating: "n", count: 900))
        XCTAssertEqual(long?.count, ClaudeCLI.maxLength)
    }

    // MARK: - The environment and the argument list (SPEC §13.2)

    func testTheChildLosesTheParentSessionsIdentityAndGainsTheIgnoreFlag() {
        let env = ClaudeCLI.environment(inheriting: [
            "PATH": "/usr/bin",
            "CLAUDECODE": "1",
            "CLAUDE_CODE_SESSION_ID": "abc",
            "CLAUDE_CODE_HOST_SESSION_ID": "def",
            "CLAUDE_PID": "123",
            "CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/cc-socks/1.sock",
            "CLAUDE_CODE_MESSAGING_TOKEN": "secret",
            "CLAUDE_CODE_OAUTH_TOKEN": "secret",
        ])
        XCTAssertEqual(env["LOOKOUT_IGNORE"], "1")
        XCTAssertEqual(env["CLAUDE_CODE_CHILD_SESSION"], "1")
        XCTAssertEqual(env["PATH"], "/usr/bin")
        for key in ClaudeCLI.strippedKeys {
            XCTAssertNil(env[key], key)
        }

        XCTAssertEqual(
            ClaudeCLI.arguments(model: "haiku", systemPromptFile: "/tmp/s.md", userPrompt: "hi"),
            ["-p", "--model", "haiku", "--output-format", "text",
             "--append-system-prompt-file", "/tmp/s.md", "hi"]
        )
    }

    func testTheWorkingDirectoryIsTheSessionsWhenItStillExists() throws {
        let fakeHome = try home("wd-home")
        XCTAssertEqual(
            ClaudeCLI.workingDirectory(cwd: temporary.path, home: fakeHome).path, temporary.path
        )
        XCTAssertEqual(ClaudeCLI.workingDirectory(cwd: "/gone/away", home: fakeHome), fakeHome)
        XCTAssertEqual(ClaudeCLI.workingDirectory(cwd: "", home: fakeHome), fakeHome)
        // A file is not a directory.
        let file = temporary.appendingPathComponent("a-file")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeCLI.workingDirectory(cwd: file.path, home: fakeHome), fakeHome)
    }
}
