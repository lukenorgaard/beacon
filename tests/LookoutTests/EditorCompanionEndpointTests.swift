import Darwin
import Foundation
import XCTest
@testable import Lookout

extension EditorCompanionTests {
    // MARK: - Against the fake server (SPEC §16.2's endpoints)

    private func startServer(terminals: [[String: Any]]) throws -> FakeCompanionServer {
        let server = FakeCompanionServer()
        server.terminals = terminals
        try server.start()
        self.server = server
        return server
    }

    func testTerminalsAreListedFromEveryLiveWindowAndCarryTheBearerToken() throws {
        let server = try startServer(terminals: [
            EditorCompanionTests.terminal(index: 0, name: "zsh", pid: 8001),
            EditorCompanionTests.terminal(index: 1, name: "claude", pid: 8002, active: true),
            EditorCompanionTests.terminal(index: 2, name: "no pid yet", pid: nil),
        ])
        try writeInstance(app: "cursor", pid: 4242, port: server.port, token: server.token)

        let listed = client().terminals(for: "cursor")
        XCTAssertEqual(listed.map(\.terminal.index), [0, 1, 2])
        XCTAssertEqual(listed[1].terminal.name, "claude")
        XCTAssertEqual(listed[1].terminal.processId, 8002)
        XCTAssertTrue(listed[1].terminal.isActive)
        XCTAssertNil(listed[2].terminal.processId, "an unawaited pid decodes to nil, not 0")
        XCTAssertEqual(listed[0].terminal.cwd, "/Users/you/Acme/repo")

        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(server.requests[0].method, "GET")
        XCTAssertEqual(server.requests[0].path, "/terminals")
        XCTAssertEqual(server.requests[0].authorization, "Bearer \(server.token)")
    }

    func testAWrongTokenIsRejectedByTheServerAndYieldsNothing() throws {
        let server = try startServer(terminals: [
            EditorCompanionTests.terminal(index: 0, name: "claude", pid: 8002),
        ])
        try writeInstance(
            app: "cursor", pid: 4242, port: server.port,
            token: "ffffffffffffffffffffffffffffffff"
        )

        XCTAssertTrue(client().terminals(for: "cursor").isEmpty, "401 means no terminals")
        XCTAssertNil(client().focus(app: "cursor", shellPid: 8002, agentCommand: "claude"))
    }

    func testFocusPostsTheProcessIdAndSucceeds() throws {
        let server = try startServer(terminals: [
            EditorCompanionTests.terminal(index: 0, name: "zsh", pid: 8001),
            EditorCompanionTests.terminal(index: 1, name: "claude", pid: 8002),
        ])
        try writeInstance(app: "cursor", pid: 4242, port: server.port, token: server.token)

        let match = client().focus(app: "cursor", shellPid: 8002, agentCommand: "claude")
        XCTAssertEqual(match?.terminal.index, 1)
        XCTAssertEqual(match?.rule, .pid)

        let post = server.requests.last
        XCTAssertEqual(post?.method, "POST")
        XCTAssertEqual(post?.path, "/focus")
        XCTAssertEqual(post?.authorization, "Bearer \(server.token)")
        let body = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: Data((post?.body ?? "").utf8)))
                as? [String: Any]
        )
        XCTAssertEqual(body["processId"] as? Int, 8002)
        XCTAssertEqual(body.count, 1, "/focus takes the pid and nothing else")
    }

    func testSendPostsProcessIdTextAndNewline() throws {
        let server = try startServer(terminals: [
            EditorCompanionTests.terminal(index: 3, name: "claude", pid: 8002),
        ])
        try writeInstance(app: "devin", pid: 4242, port: server.port, token: server.token)

        let match = client().send(
            app: "devin", shellPid: 8002, agentCommand: "claude", text: "/rename Nimbus fase 0"
        )
        XCTAssertEqual(match?.terminal.index, 3)

        let post = try XCTUnwrap(server.requests.last)
        XCTAssertEqual(post.path, "/send")
        let body = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: Data(post.body.utf8))) as? [String: Any]
        )
        XCTAssertEqual(body["processId"] as? Int, 8002)
        XCTAssertEqual(body["text"] as? String, "/rename Nimbus fase 0")
        XCTAssertEqual(body["newline"] as? Bool, true)
    }

    /// §16.2: the terminal went away between the listing and the call. That is a no-match, so
    /// the caller falls back exactly as if there had been no companion at all.
    func testA404FromTheEndpointIsTreatedAsNoMatch() throws {
        let server = try startServer(terminals: [
            EditorCompanionTests.terminal(index: 0, name: "claude", pid: 8002),
        ])
        try writeInstance(app: "cursor", pid: 4242, port: server.port, token: server.token)

        // The listing succeeds and the pid matches; the POST is what 404s.
        server.forcedStatus = 404
        XCTAssertNil(client().focus(app: "cursor", shellPid: 8002, agentCommand: "claude"))
        XCTAssertNil(
            client().send(app: "cursor", shellPid: 8002, agentCommand: "claude", text: "hi")
        )
    }

    func testNothingIsAttemptedWhenNoTerminalMatches() throws {
        let server = try startServer(terminals: [
            EditorCompanionTests.terminal(index: 0, name: "zsh", pid: 8001),
        ])
        try writeInstance(app: "cursor", pid: 4242, port: server.port, token: server.token)

        XCTAssertNil(client().focus(app: "cursor", shellPid: 9999, agentCommand: "claude"))
        XCTAssertEqual(
            server.requests.map(\.path), ["/terminals"],
            "no match means no POST — the window jump takes over instead"
        )
    }

    /// A companion file pointing at a port nobody is listening on must fail fast and quietly.
    func testADeadPortFailsWithoutThrowingOrHanging() throws {
        try writeInstance(app: "cursor", pid: 4242, port: 1, token: "0123456789abcdef01234567")
        let started = Date()
        XCTAssertNil(client().focus(app: "cursor", shellPid: 1, agentCommand: "claude"))
        XCTAssertLessThan(Date().timeIntervalSince(started), EditorCompanion.timeout + 1)
    }

    func testTheHostToAppMappingCoversExactlyTheThreeEditors() {
        XCTAssertEqual(EditorCompanion.app(for: .cursor), "cursor")
        XCTAssertEqual(EditorCompanion.app(for: .devin), "devin")
        XCTAssertEqual(EditorCompanion.app(for: .vscode), "vscode")
        for host in [SessionHost.terminal, .iterm, .claudeDesktop, .codexApp, .unknown] {
            XCTAssertNil(EditorCompanion.app(for: host), "\(host)")
        }
        XCTAssertEqual(EditorCompanion.host(for: "devin"), .devin)
        XCTAssertNil(EditorCompanion.host(for: "emacs"))
    }

    // MARK: - The HTTP client itself

    func testATokenThatCouldForgeAHeaderIsRefusedBeforeASocketOpens() {
        XCTAssertFalse(LocalHTTP.isHeaderSafe(SecretToken("abc\r\nX-Evil: 1")))
        XCTAssertFalse(LocalHTTP.isHeaderSafe(SecretToken("abc def01234")))
        XCTAssertFalse(LocalHTTP.isHeaderSafe(SecretToken("short")))
        XCTAssertFalse(LocalHTTP.isHeaderSafe(SecretToken(String(repeating: "a", count: 257))))
        XCTAssertTrue(LocalHTTP.isHeaderSafe(SecretToken("0123456789abcdef0123456789abcdef")))

        XCTAssertEqual(
            LocalHTTP.request(
                port: 9, method: "GET", path: "/ping",
                token: SecretToken("bad\r\ntoken"), timeout: 0.2
            ),
            .failure(.unusableToken)
        )
    }

    func testTheResponseParserTakesStatusAndBody() {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n[]".utf8)
        XCTAssertEqual(LocalHTTP.parse(raw)?.status, 200)
        XCTAssertEqual(LocalHTTP.parse(raw)?.body, Data("[]".utf8))
        XCTAssertNil(LocalHTTP.parse(Data("garbage".utf8)))
        XCTAssertNil(LocalHTTP.parse(Data("NOTHTTP 200 OK\r\n\r\n".utf8)))
        XCTAssertEqual(
            LocalHTTP.parse(Data("HTTP/1.1 404 Not Found\r\n\r\n{}".utf8))?.status, 404
        )
    }

    // MARK: - The setup row's states (SPEC §16.3)

    func testTheRowIsGreenAmberOrGrey() {
        XCTAssertEqual(CompanionState.state(appPresent: true, companionLive: true), .live)
        XCTAssertEqual(CompanionState.state(appPresent: true, companionLive: false), .installable)
        XCTAssertEqual(CompanionState.state(appPresent: false, companionLive: false), .absent)
        XCTAssertEqual(
            CompanionState.state(appPresent: false, companionLive: true), .absent,
            "no app, no row — a stale live flag can never turn it green"
        )

        XCTAssertEqual(CompanionState.summary([.absent, .installable, .live]), .live)
        XCTAssertEqual(CompanionState.summary([.absent, .installable]), .installable)
        XCTAssertEqual(CompanionState.summary([.absent, .absent]), .absent)
        XCTAssertEqual(CompanionState.summary([]), .absent)

        XCTAssertEqual(CompanionState.installable.message, "Install, then reload the editor window.")
        XCTAssertTrue(CompanionState.installable.canInstall)
        XCTAssertTrue(CompanionState.live.canInstall, "green still offers a reinstall")
        XCTAssertFalse(CompanionState.absent.canInstall)
    }

    func testTheInstallerProbesApplicationsAndTheLiveCompanionFiles() throws {
        let applications = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(
            at: applications.appendingPathComponent("Cursor.app"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: applications.appendingPathComponent("Devin.app"),
            withIntermediateDirectories: true
        )

        let stub = StubCompanion()
        stub.live = ["cursor"]
        let installer = CompanionInstaller(
            resources: nil, applications: applications, companion: stub
        )
        let statuses = installer.probe()
        installer.apply(statuses)

        XCTAssertEqual(statuses.map(\.app), EditorApp.allCases)
        XCTAssertEqual(statuses[0].state, .live, "Cursor is installed and answering")
        XCTAssertEqual(statuses[1].state, .installable, "Devin is installed but silent")
        XCTAssertEqual(statuses[2].state, .absent, "no VS Code on this Mac")
        XCTAssertEqual(installer.summary, .live)
    }

    func testAnInstallWithoutTheBundledScriptSaysSoInsteadOfRunningAnything() {
        let installer = CompanionInstaller(
            resources: nil, applications: root, companion: StubCompanion()
        )
        XCTAssertEqual(installer.missingBundledFiles, BundleLayout.companionFiles)
        XCTAssertFalse(installer.canInstall)

        var outcome: CompanionInstaller.Outcome?
        installer.install(.cursor) { outcome = $0 }
        XCTAssertEqual(outcome?.succeeded, false)
        XCTAssertEqual(outcome?.app, .cursor)
        XCTAssertNil(installer.busy)
    }

    /// SPEC §16.3: 5 s is not enough to unpack a vsix and rewrite an extension index.
    func testTheInstallBudgetIsAMinute() {
        XCTAssertEqual(CompanionInstaller.installTimeout, 60)
        XCTAssertGreaterThan(CompanionInstaller.installTimeout, HookInstaller.installTimeout)
        XCTAssertEqual(
            BundleLayout.companionFiles,
            ["companion/lookout-companion.vsix", "companion/install-companion.sh"]
        )
        XCTAssertFalse(
            BundleLayout.bundledFiles.contains(BundleLayout.companionScript),
            "a build with no companion must still be able to install the hooks"
        )
    }

    func testTheInstallOutcomeNamesTheAppAndTheReloadStep() {
        let ok = Shell.Result(stdout: "    Cursor: ok\n", exitCode: 0, timedOut: false)
        XCTAssertEqual(
            CompanionInstaller.summarise(ok, app: .cursor),
            "Cursor: installed. Reload the window (⌘⇧P → Reload Window)."
        )
        let failed = Shell.Result(stdout: "Devin: FAILED (exit 1)\n", exitCode: 1, timedOut: false)
        XCTAssertEqual(
            CompanionInstaller.summarise(failed, app: .devin), "Devin: Devin: FAILED (exit 1)"
        )
        let timedOut = Shell.Result(stdout: "", exitCode: -1, timedOut: true)
        XCTAssertEqual(
            CompanionInstaller.summarise(timedOut, app: .vscode),
            "VS Code: timed out after 60 s."
        )
    }
}
