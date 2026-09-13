import XCTest
@testable import Lookout

extension ClaudeSuggesterTests {
    // MARK: - The runner, against a fake `claude` (SPEC §13.2)

    /// The fake writes its argv, three environment variables and its working directory to a
    /// file, then prints a canned reply — so one run proves the invocation *and* the result.
    func testTheRunnerCallsTheFakeClaudeOnPathAndTrimsItsReply() throws {
        let fakeHome = try home("run-home")
        let bin = temporary.appendingPathComponent("run-bin")
        let record = temporary.appendingPathComponent("record.txt")
        let project = temporary.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try script("claude", in: bin, body: """
        #!/bin/sh
        {
          echo "argv=$*"
          echo "ignore=$LOOKOUT_IGNORE"
          echo "child=$CLAUDE_CODE_CHILD_SESSION"
          echo "claudecode=${CLAUDECODE:-<unset>}"
          echo "pwd=$(pwd)"
          echo "system=$(cat "$7")"
        } > "\(record.path)"
        printf '  Allow — it only runs the migration.\\n\\nI would then run the tests.\\n'
        """)

        var context = SuggestionContext(kind: .permission)
        context.toolName = "Bash"
        context.command = "psql -f 005.sql"
        context.cwd = project.path

        let suggester = ClaudeCLISuggester(
            home: LookoutHome(root: temporary.appendingPathComponent("lookout"))
        )
        let outcome = suggester.run(
            context: context, model: "haiku", override: nil,
            template: SuggestPromptTemplate.defaultText,
            homeDirectory: fakeHome,
            environment: [
                "PATH": "\(bin.path):/usr/bin:/bin", "CLAUDECODE": "1", "CLAUDE_PID": "9",
            ]
        )

        XCTAssertEqual(outcome.reason, "ok")
        XCTAssertEqual(outcome.text, "Allow — it only runs the migration.")
        XCTAssertEqual(outcome.model, "haiku")

        let written = try String(contentsOf: record, encoding: .utf8)
        XCTAssertTrue(
            written.contains("argv=-p --model haiku --output-format text "
                + "--append-system-prompt-file "),
            written
        )
        XCTAssertTrue(written.contains("ignore=1"), written)
        XCTAssertTrue(written.contains("child=1"), written)
        XCTAssertTrue(written.contains("claudecode=<unset>"), written)
        // `pwd` reports the physical path and the temp directory sits behind `/private`, so
        // both sides are canonicalised the same way before they are compared.
        let reported = try XCTUnwrap(
            written.split(separator: "\n").first { $0.hasPrefix("pwd=") }
        ).dropFirst("pwd=".count)
        XCTAssertEqual(
            (String(reported) as NSString).resolvingSymlinksInPath,
            (project.path as NSString).resolvingSymlinksInPath,
            written
        )
        XCTAssertTrue(written.contains("You draft the one-line reply"), written)

        // The temp system-prompt file is cleaned up after the call: the path the fake read
        // from is gone by the time `run` returned.
        let systemPath = try XCTUnwrap(
            written.split(separator: "\n").first { $0.hasPrefix("argv=") }
        )
        .split(separator: " ")
        .last { $0.contains("lookout-suggest-") }
        XCTAssertNotNil(systemPath, written)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: String(systemPath ?? "")), written
        )

        // And the log line carries no part of the prompt or the reply (SPEC §13.2).
        let logHome = LookoutHome(root: temporary.appendingPathComponent("lookout-log"))
        LogFile.appendNow(
            "source=claude model=haiku duration_ms=\(outcome.durationMS) "
                + "outcome=\(outcome.reason)",
            to: logHome.suggestLog
        )
        let line = try String(contentsOf: logHome.suggestLog, encoding: .utf8)
        XCTAssertTrue(line.contains("source=claude model=haiku"), line)
        XCTAssertTrue(line.contains("outcome=ok"), line)
        XCTAssertFalse(line.contains("Allow"), line)
        XCTAssertFalse(line.contains("psql"), line)
    }

    func testAClaudeThatNeverAnswersTimesOutAndTheCardFallsBackToTheHeuristic() throws {
        let fakeHome = try home("slow-home")
        let bin = temporary.appendingPathComponent("slow-bin")
        try script("claude", in: bin, body: "#!/bin/sh\n/bin/sleep 30\necho too late\n")

        var context = SuggestionContext(kind: .permission)
        context.command = "npm test"

        let claude = ClaudeCLISuggester(
            home: LookoutHome(root: temporary.appendingPathComponent("lookout"))
        )
        claude.timeout = 0.4
        let started = Date()
        let outcome = claude.run(
            context: context, model: "haiku", override: nil,
            template: SuggestPromptTemplate.defaultText,
            homeDirectory: fakeHome, environment: ["PATH": bin.path]
        )
        XCTAssertEqual(outcome.reason, "timeout")
        XCTAssertNil(outcome.text)
        XCTAssertLessThan(
            Date().timeIntervalSince(started), claude.timeout + Shell.timeoutOverhead + 1
        )

        // SPEC §13.2: the caller falls back, and the card's status line says so.
        let suggester = Suggester(claude: claude)
        let expectation = expectation(description: "fallback")
        var result: SuggestionOutcome?
        suggester.suggest(
            for: context, source: .claude, model: nil,
            // Pinned at the fake: nothing in this suite may ever reach the real `claude`.
            claude: Suggester.ClaudeOptions(
                model: "haiku",
                binaryPath: bin.appendingPathComponent("claude").path,
                template: SuggestPromptTemplate.defaultText
            )
        ) {
            result = $0
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)
        XCTAssertEqual(result?.text, "Allow — runs `npm test`")
        XCTAssertEqual(result?.source, .heuristic)
        XCTAssertEqual(result?.note, "Claude unavailable → heuristic")
    }

    func testAMissingBinaryAndANonZeroExitAreBothFailures() throws {
        let fakeHome = try home("empty-home")
        let claude = ClaudeCLISuggester(
            home: LookoutHome(root: temporary.appendingPathComponent("lookout"))
        )
        let context = SuggestionContext(kind: .done)

        // Nothing to find at all → `run` never spawns anything.
        XCTAssertNil(
            ClaudeBinary.discover(
                home: fakeHome, environment: ["PATH": ""], fileManager: blind
            )
        )
        try XCTSkipIf(
            ClaudeBinary.fallbackPaths.contains { FileManager.default.isExecutableFile(atPath: $0) },
            "this Mac has a claude at one of the absolute fallback paths"
        )
        let empties = temporary.appendingPathComponent("no-bin")
        try FileManager.default.createDirectory(at: empties, withIntermediateDirectories: true)
        let missing = claude.run(
            context: context, model: "haiku", override: nil,
            template: SuggestPromptTemplate.defaultText,
            homeDirectory: fakeHome, environment: ["PATH": empties.path]
        )
        XCTAssertEqual(missing.reason, "no-binary")

        let bin = temporary.appendingPathComponent("angry-bin")
        try script("claude", in: bin, body: "#!/bin/sh\necho boom >&2\nexit 3\n")
        let failed = claude.run(
            context: context, model: "sonnet", override: nil,
            template: SuggestPromptTemplate.defaultText,
            homeDirectory: fakeHome, environment: ["PATH": bin.path]
        )
        XCTAssertEqual(failed.reason, "exit-3")
        XCTAssertNil(failed.text)

        let quiet = temporary.appendingPathComponent("quiet-bin")
        try script("claude", in: quiet, body: "#!/bin/sh\nexit 0\n")
        let empty = claude.run(
            context: context, model: "haiku", override: nil,
            template: SuggestPromptTemplate.defaultText,
            homeDirectory: fakeHome, environment: ["PATH": quiet.path]
        )
        XCTAssertEqual(empty.reason, "empty")
    }

    /// The happy path all the way through `Suggester`, so the card's contract is covered too.
    func testASuccessfulClaudeCallReachesTheCardWithNoNote() throws {
        let bin = temporary.appendingPathComponent("happy-bin")
        try script("claude", in: bin, body: "#!/bin/sh\necho 'Ja — kør den.'\n")

        let logHome = LookoutHome(root: temporary.appendingPathComponent("lookout"))
        let claude = ClaudeCLISuggester(home: logHome)
        // `run`'s discovery uses the real home unless told otherwise, so point the seam at the
        // fake directly: this test is about what `Suggester` does with a success.
        claude.runner = { binary, arguments, environment, directory, _ in
            _ = (binary, arguments, environment, directory)
            return Shell.Result(stdout: "Ja — kør den.\n", exitCode: 0, timedOut: false)
        }

        var context = SuggestionContext(kind: .question)
        context.question = "Kører vi 005 nu?"
        let suggester = Suggester(claude: claude)
        let expectation = expectation(description: "claude")
        var result: SuggestionOutcome?
        suggester.suggest(
            for: context, source: .claude, model: nil,
            claude: Suggester.ClaudeOptions(
                model: "haiku", binaryPath: bin.appendingPathComponent("claude").path,
                template: SuggestPromptTemplate.defaultText
            )
        ) {
            result = $0
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)
        XCTAssertEqual(result?.text, "Ja — kør den.")
        XCTAssertEqual(result?.source, .claude)
        XCTAssertNil(result?.note)

        // SPEC §13.2: one line in `suggest.log`, and not a word of the prompt or the reply.
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: logHome.suggestLog.path),
              Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let logged = try String(contentsOf: logHome.suggestLog, encoding: .utf8)
        XCTAssertTrue(logged.contains("source=claude"), logged)
        XCTAssertTrue(logged.contains("model=haiku"), logged)
        XCTAssertTrue(logged.contains("outcome=ok"), logged)
        XCTAssertTrue(logged.contains("duration_ms="), logged)
        XCTAssertFalse(logged.contains("kør"), logged)
        XCTAssertFalse(logged.contains("005"), logged)
    }

    // MARK: - The real binary (opt-in: it spends the subscription)

    /// The end-to-end path against the owner's own `claude`, exactly as the card calls it. Skipped
    /// unless `LOOKOUT_REAL_CLAUDE=1` is set, because every run costs a real request:
    ///
    ///     LOOKOUT_REAL_CLAUDE=1 swift test --filter testTheRealClaudeAnswers
    func testTheRealClaudeAnswersThroughTheRunner() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LOOKOUT_REAL_CLAUDE"] == "1",
            "set LOOKOUT_REAL_CLAUDE=1 to spend one request on the live path"
        )
        let binary = try XCTUnwrap(ClaudeBinary.discover(), "no claude on this Mac")

        var context = SuggestionContext(kind: .permission)
        context.project = "daily-notes"
        context.host = "Cursor"
        context.toolName = "Bash"
        context.command = "psql -f 005_add_index.sql"
        context.cwd = "/tmp"
        context.turns = [
            TranscriptTurn(role: "user", text: "Run the migrations for me"),
            TranscriptTurn(role: "assistant", text: "Starting with 004."),
        ]

        let claude = ClaudeCLISuggester(
            home: LookoutHome(root: temporary.appendingPathComponent("lookout"))
        )
        let outcome = claude.run(
            context: context, model: "haiku", override: nil,
            template: SuggestPromptTemplate.defaultText
        )
        print("REAL CLAUDE binary=\(binary)")
        print("REAL CLAUDE outcome=\(outcome.reason) duration_ms=\(outcome.durationMS)")
        print("REAL CLAUDE reply=\(outcome.text ?? "<none>")")

        XCTAssertEqual(outcome.reason, "ok")
        let text = try XCTUnwrap(outcome.text)
        XCTAssertFalse(text.isEmpty)
        XCTAssertLessThanOrEqual(text.count, ClaudeCLI.maxLength)
        XCTAssertLessThan(Double(outcome.durationMS) / 1000, ClaudeCLI.timeout)
    }

    // MARK: - Settings (SPEC §13.2)

    func testTheClaudeSettingsRoundTripAndRejectAModelThatIsNotOnTheList() throws {
        let suite = "io.github.lukenorgaard.beacon.tests.claude-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = Settings(defaults: defaults)
        XCTAssertEqual(settings.claudeModel, "haiku")
        XCTAssertNil(settings.claudeBinaryPath)
        XCTAssertEqual(settings.claudeOptions.model, "haiku")
        XCTAssertNil(settings.claudeOptions.binaryPath)

        settings.claudeModel = "opus"
        settings.claudeBinaryPath = "  /tmp/claude  "
        XCTAssertEqual(Settings(defaults: defaults).claudeModel, "opus")
        XCTAssertEqual(Settings(defaults: defaults).claudeBinaryPath, "/tmp/claude")

        settings.claudeModel = "gpt-5"
        XCTAssertEqual(settings.claudeModel, "haiku", "an unknown model falls back to the default")

        settings.claudeBinaryPath = "   "
        XCTAssertNil(Settings(defaults: defaults).claudeBinaryPath)

        XCTAssertEqual(SuggestionSource.claude.label, "Claude (subscription)")
        XCTAssertTrue(SuggestionSource.allCases.contains(.claude))
    }
}
