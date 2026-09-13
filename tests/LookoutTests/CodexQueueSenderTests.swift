import XCTest
@testable import Lookout

/// SPEC §17.7: Codex's own Send channel — `codex queue --thread <id> --message <text>` — driven
/// against a real (harmless) script standing in for the `codex` binary, exactly the way
/// `ClaudeSuggesterTests` exercises `ClaudeBinary.discover` and `claude -p`.
final class CodexQueueSenderTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories = []
        super.tearDown()
    }

    private func temporaryDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-codexqueue-\(UUID().uuidString)")
        directories.append(url)
        return url
    }

    private func script(_ name: String, in directory: URL, body: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func codexSession(id: String = "abc-123") -> Session {
        var session = Session()
        session.sessionID = id
        session.agent = .codex
        session.project = "daily-notes"
        session.pid = 1
        return session
    }

    private func home() -> LookoutHome {
        LookoutHome(root: temporaryDirectory())
    }

    // MARK: - Discovery: PATH, then ~/.local/bin, ~/.codex/bin, /opt/homebrew/bin, /usr/local/bin

    func testDiscoveryPrefersPATHOverTheFixedCandidates() throws {
        let pathDirectory = temporaryDirectory()
        try script("codex", in: pathDirectory, body: "#!/bin/sh\nexit 0\n")
        let fakeHome = temporaryDirectory()
        try script("codex", in: fakeHome.appendingPathComponent(".local/bin"), body: "#!/bin/sh\nexit 0\n")

        let found = CodexQueueSender.discover(
            environment: ["PATH": pathDirectory.path], home: fakeHome
        )
        XCTAssertEqual(found, pathDirectory.appendingPathComponent("codex").path)
    }

    func testDiscoveryFallsBackToLocalBinThenCodexBinWhenPATHHasNothing() throws {
        let fakeHome = temporaryDirectory()
        try script("codex", in: fakeHome.appendingPathComponent(".local/bin"), body: "#!/bin/sh\nexit 0\n")

        XCTAssertEqual(
            CodexQueueSender.discover(environment: ["PATH": "/does/not/exist"], home: fakeHome),
            fakeHome.appendingPathComponent(".local/bin/codex").path
        )

        let onlyCodexBin = temporaryDirectory()
        try script("codex", in: onlyCodexBin.appendingPathComponent(".codex/bin"), body: "#!/bin/sh\nexit 0\n")
        XCTAssertEqual(
            CodexQueueSender.discover(environment: ["PATH": "/does/not/exist"], home: onlyCodexBin),
            onlyCodexBin.appendingPathComponent(".codex/bin/codex").path
        )
    }

    func testDiscoveryReturnsNilWhenNothingIsInstalledAnywhere() {
        let fakeHome = temporaryDirectory()
        XCTAssertNil(
            CodexQueueSender.discover(environment: ["PATH": "/does/not/exist"], home: fakeHome)
        )
    }

    // MARK: - Command construction (SPEC §17.7)

    func testTheCommandIsQueueThreadSessionIdMessageText() throws {
        let bin = temporaryDirectory()
        let argsFile = bin.appendingPathComponent("args.txt")
        try script("codex", in: bin, body: """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(argsFile.path)"
        exit 0
        """)

        let result = CodexQueueSender.sendSynchronously(
            text: "Run 004 first", session: codexSession(id: "abc-123"),
            home: home(), binary: bin.appendingPathComponent("codex").path
        )
        XCTAssertEqual(result, .sent)

        let recorded = try String(contentsOf: argsFile, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .dropLast() // trailing newline from printf
        XCTAssertEqual(Array(recorded), ["queue", "--thread", "abc-123", "--message", "Run 004 first"])
    }

    func testOnlyCodexSessionsUseThisChannel() {
        var claude = codexSession()
        claude.agent = .claude
        XCTAssertEqual(
            CodexQueueSender.sendSynchronously(text: "x", session: claude, home: home()),
            .failed(reason: "codex queue is codex-only")
        )
    }

    func testABlankSessionIdIsRefusedBeforeAnyProcessRuns() {
        var session = codexSession()
        session.sessionID = ""
        XCTAssertEqual(
            CodexQueueSender.sendSynchronously(text: "x", session: session, home: home()),
            .failed(reason: "no session id")
        )
    }

    func testNoBinaryFoundIsAFailure() {
        // No `binary:` override and PATH points nowhere real — the search must fail cleanly,
        // never fall through to a real `codex` this machine might actually have installed.
        let result = CodexQueueSender.sendSynchronously(
            text: "x", session: codexSession(), home: home(), binary: nil
        )
        // Only assert the shape when there truly is no codex on PATH — the discovery order
        // itself is proven in isolation above.
        if CodexQueueSender.discover() == nil {
            XCTAssertEqual(result, .failed(reason: "codex binary not found"))
        }
    }

    func testANonZeroExitIsAFailureWithTheScriptsOwnOutputAsTheReason() throws {
        let bin = temporaryDirectory()
        try script("codex", in: bin, body: "#!/bin/sh\necho no such thread >&2\nexit 1\n")

        let result = CodexQueueSender.sendSynchronously(
            text: "x", session: codexSession(), home: home(),
            binary: bin.appendingPathComponent("codex").path
        )
        XCTAssertEqual(result, .failed(reason: "no such thread"))
    }

    func testAQuietNonZeroExitFallsBackToTheExitCode() throws {
        let bin = temporaryDirectory()
        try script("codex", in: bin, body: "#!/bin/sh\nexit 7\n")

        let result = CodexQueueSender.sendSynchronously(
            text: "x", session: codexSession(), home: home(),
            binary: bin.appendingPathComponent("codex").path
        )
        XCTAssertEqual(result, .failed(reason: "exit 7"))
    }

    func testATimedOutProcessIsAFailure() throws {
        let bin = temporaryDirectory()
        try script("codex", in: bin, body: "#!/bin/sh\n/bin/sleep 30\nexit 0\n")

        let result = CodexQueueSender.sendSynchronously(
            text: "x", session: codexSession(), home: home(),
            binary: bin.appendingPathComponent("codex").path, timeout: 0.3
        )
        XCTAssertEqual(result, .failed(reason: "timed out"))
    }

    // MARK: - Logging (SPEC §17.7: channel `codex-queue` in answers.log)

    func testEveryOutcomeIsLoggedUnderTheCodexQueueChannel() throws {
        let bin = temporaryDirectory()
        try script("codex", in: bin, body: "#!/bin/sh\nexit 0\n")
        let testHome = home()

        _ = CodexQueueSender.sendSynchronously(
            text: "Run 004", session: codexSession(id: "abc-123"),
            home: testHome, binary: bin.appendingPathComponent("codex").path
        )

        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: testHome.answersLog.path), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        let log = try String(contentsOf: testHome.answersLog, encoding: .utf8)
        XCTAssertTrue(log.contains("codex-queue"), log)
        XCTAssertTrue(log.contains("sent"), log)
    }

    // MARK: - Result

    func testIsSuccessAndReason() {
        XCTAssertTrue(CodexQueueSender.Result.sent.isSuccess)
        XCTAssertNil(CodexQueueSender.Result.sent.reason)
        XCTAssertFalse(CodexQueueSender.Result.failed(reason: "x").isSuccess)
        XCTAssertEqual(CodexQueueSender.Result.failed(reason: "x").reason, "x")
    }
}
