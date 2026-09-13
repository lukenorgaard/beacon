import Darwin
import Foundation
import XCTest
@testable import Lookout

/// SPEC §11.2 / §11.4: the two lines, in order, and what counts as a delivered message.
final class SessionMessengerTests: XCTestCase {
    var server: FakeSocketServer?
    private var homes: [LookoutHome] = []

    override func tearDown() {
        server?.stop()
        server = nil
        for home in homes { try? FileManager.default.removeItem(at: home.root) }
        homes = []
        super.tearDown()
    }

    private let token = SecretToken("tok-abc-123")

    func testTheAuthLineGoesFirstAndTheUserLineSecond() throws {
        let server = FakeSocketServer(behaviour: .reply(#"{"ok":true}"#))
        self.server = server
        try server.start()

        let result = SessionMessenger.send(
            text: "Yes, go ahead", socketPath: server.path, token: token
        )
        XCTAssertEqual(result, .sent(reply: #"{"ok":true}"#))

        let lines = server.receivedLines
        XCTAssertEqual(lines.count, 2, "exactly two lines, no more")

        let auth = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        )
        XCTAssertEqual(auth["type"] as? String, "auth")
        XCTAssertEqual(auth["token"] as? String, "tok-abc-123")

        let message = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any]
        )
        XCTAssertEqual(message["type"] as? String, "user")
        let inner = try XCTUnwrap(message["message"] as? [String: Any])
        XCTAssertEqual(inner["role"] as? String, "user")
        XCTAssertEqual(inner["content"] as? String, "Yes, go ahead")
    }

    /// SPEC §11.2: the message is queued when the session is busy, so silence is a success.
    func testSilenceCountsAsDelivered() throws {
        let server = FakeSocketServer(behaviour: .silent)
        self.server = server
        try server.start()

        let started = Date()
        let result = SessionMessenger.send(
            text: "Continue", socketPath: server.path, token: token, timeout: 0.4
        )
        XCTAssertEqual(result, .sent(reply: nil))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the read has a deadline")
        XCTAssertEqual(server.receivedLines.count, 2)
    }

    func testAServerThatHangsUpIsAFailure() throws {
        let server = FakeSocketServer(behaviour: .closeImmediately)
        self.server = server
        try server.start()

        let result = SessionMessenger.send(
            text: "Continue", socketPath: server.path, token: token, timeout: 0.5
        )
        XCTAssertFalse(result.isSuccess)
        XCTAssertNotNil(result.reason)
    }

    func testARefusedConnectionIsAFailure() {
        let result = SessionMessenger.send(
            text: "Continue",
            socketPath: "/tmp/lookout-no-such-socket-\(UUID().uuidString).sock",
            token: token,
            timeout: 0.5
        )
        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.reason?.contains("connect()") ?? false, "\(String(describing: result.reason))")

        // A path that could never fit in `sun_path` fails before any syscall.
        let long = "/tmp/" + String(repeating: "a", count: 200) + ".sock"
        XCTAssertEqual(
            SessionMessenger.send(text: "x", socketPath: long, token: token),
            .failed(reason: "socket path too long")
        )
        XCTAssertEqual(
            SessionMessenger.send(text: "x", socketPath: "", token: token),
            .failed(reason: "empty socket path")
        )
    }

    func testAnErrorReplyIsAFailureEvenThoughBothLinesWereAccepted() throws {
        let server = FakeSocketServer(behaviour: .reply(#"{"error":"unknown token"}"#))
        self.server = server
        try server.start()

        let result = SessionMessenger.send(
            text: "Continue", socketPath: server.path, token: token, timeout: 0.5
        )
        XCTAssertEqual(result, .failed(reason: "unknown token"))
        XCTAssertEqual(server.receivedLines.count, 2, "both lines still went out")
    }

    /// The ack line's real shape is unknown until a live session answers one (SPEC §11.2), so
    /// the rule is narrow: only an explicit error counts as one.
    func testWhatCountsAsAnErrorReply() {
        XCTAssertNil(SessionMessenger.errorText(in: #"{"ok":true}"#))
        XCTAssertNil(SessionMessenger.errorText(in: ""))
        XCTAssertNil(SessionMessenger.errorText(in: "queued"))
        XCTAssertNil(SessionMessenger.errorText(in: #"{"type":"ack","id":7}"#))
        XCTAssertEqual(SessionMessenger.errorText(in: #"{"ok":false}"#), "rejected")
        XCTAssertEqual(SessionMessenger.errorText(in: #"{"error":"nope"}"#), "nope")
        XCTAssertEqual(
            SessionMessenger.errorText(in: #"{"error":{"message":"bad token"}}"#), "bad token"
        )
        XCTAssertEqual(SessionMessenger.errorText(in: #"{"ok":false,"error":"bad"}"#), "bad")
    }

    // MARK: - The token never reaches the log (SPEC §11.4)

    func testTheTokenIsRedactedOutOfEverythingThatGetsLogged() {
        let secret = SecretToken("sk-messaging-abcdef")
        XCTAssertEqual(
            SessionMessenger.redact("auth sk-messaging-abcdef ok", token: secret),
            "auth <redacted> ok"
        )
        XCTAssertEqual(
            SessionMessenger.redact(#"{"type":"auth","token":"sk-messaging-abcdef"}"#, token: nil),
            #"{"type":"auth","token":"<redacted>"}"#
        )
        // The type itself refuses to print the secret.
        XCTAssertEqual("\(secret)", "<redacted>")
        XCTAssertEqual(String(describing: secret), "<redacted>")
        XCTAssertFalse("\(secret)".contains("sk-messaging"))
    }

    /// SPEC §11.2: Codex has no messaging socket, so Send is never even attempted for it.
    func testANonClaudeSessionIsRefusedWithoutTouchingASocket() throws {
        let home = LookoutHome(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-send-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: home.root) }

        var session = Session()
        session.sessionID = "s1"
        session.agent = .codex
        session.pid = 1
        let result = SessionMessenger.sendSynchronously(text: "x", session: session, home: home)
        XCTAssertEqual(result, .failed(reason: "no messaging socket for codex"))
        XCTAssertFalse(session.canSendMessage)

        // …and the failure is on the send log, with the session but no token.
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: home.sendLog.path), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        let log = (try? String(contentsOf: home.sendLog, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("outcome=failed"))
        XCTAssertTrue(log.contains("session=s1"))
    }

    // MARK: - Where the token comes from (SPEC §15.1)

    /// A throwaway `~/.lookout` for one test; nothing here ever touches the real one.
    private func temporaryHome() -> LookoutHome {
        let home = LookoutHome(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-token-\(UUID().uuidString)"))
        homes.append(home)
        return home
    }

    private func claudeSession(id: String, socket: String) -> Session {
        var session = Session()
        session.sessionID = id
        session.agent = .claude
        // This process: alive by definition, and its procargs carry no messaging token — the
        // only pid a test may point at.
        session.pid = getpid()
        session.messagingSocket = socket
        return session
    }

    private func authToken(_ server: FakeSocketServer) throws -> String? {
        let lines = server.receivedLines
        XCTAssertEqual(lines.count, 2)
        let auth = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        )
        return auth["token"] as? String
    }

    /// The token file wins, and the process environment is not even read when the socket is
    /// known too.
    func testTheTokenFileIsTheFirstSourceAndItsValueIsWhatGoesOnTheWire() throws {
        let home = temporaryHome()
        let server = FakeSocketServer(behaviour: .reply(#"{"ok":true}"#))
        self.server = server
        try server.start()

        XCTAssertTrue(home.ensure(home.tokens))
        let url = home.tokenFile(agent: .claude, sessionID: "s-file")
        XCTAssertTrue(url.path.hasSuffix("tokens/claude-s-file.token"), url.path)
        // Trailing whitespace is the reporter's newline, not part of the token.
        try "  tok-from-file\n".write(to: url, atomically: true, encoding: .utf8)

        var readTheProcess = false
        let result = SessionMessenger.sendSynchronously(
            text: "Continue",
            session: claudeSession(id: "s-file", socket: server.path),
            home: home,
            environment: { _ in
                readTheProcess = true
                return (nil, SecretToken("tok-from-procargs"))
            }
        )
        XCTAssertEqual(result, .sent(reply: #"{"ok":true}"#))
        XCTAssertFalse(
            readTheProcess,
            "the file had the token and the state file had the socket — nothing to ask procargs"
        )
        XCTAssertEqual(try authToken(server), "tok-from-file")
    }

    // MARK: - SPEC §17.12: the header

    func testFreeTextGetsTheHeaderAndSlashCommandsDoNot() {
        let framed = SessionMessenger.framed("go start on 09")
        XCTAssertTrue(framed.hasPrefix("[Beacon] This message was typed by your user in Beacon"))
        XCTAssertTrue(framed.hasSuffix("\n\ngo start on 09"))
        XCTAssertTrue(framed.contains("do not SendMessage anyone"))
        XCTAssertFalse(SessionMessenger.header.contains("\n"), "one line — it is a preamble, not a wall")
        XCTAssertEqual(SessionMessenger.framed("/rename Nova"), "/rename Nova")
        XCTAssertEqual(SessionMessenger.framed("/compact"), "/compact")
    }

    /// Bug fix, 2026-09-06: a leading space used to defeat `hasPrefix("/")` entirely, so a real
    /// slash command typed with one got the header wrapped around it (and the session then saw
    /// `[Lookout] …\n\n /rename Nova`, not a command at all).
    func testALeadingOrTrailingSpaceStillDetectsTheSlashCommand() {
        XCTAssertEqual(SessionMessenger.framed(" /rename Nova"), "/rename Nova")
        XCTAssertEqual(SessionMessenger.framed("  /compact  "), "/compact")
        XCTAssertEqual(SessionMessenger.framed("\t/compact\n"), "/compact")
    }

    /// Bug fix, 2026-09-06: `hasPrefix("/")` alone also matched a message that merely *starts*
    /// with a path — "/tmp/build.log has the answer" is free text about a file, not a command,
    /// and must still get the header (and the session must never see it as a bare "/tmp/…" line
    /// with no explanation of who sent it).
    func testAMessageThatMerelyStartsWithAPathStillGetsTheHeader() {
        for text in [
            "/tmp/build.log has the answer",
            "/Users/you/notes.md is where I left it",
            "/etc/hosts needs a line added",
        ] {
            let framed = SessionMessenger.framed(text)
            XCTAssertTrue(
                framed.hasPrefix("[Beacon] This message was typed by your user in Beacon"),
                "\(text) must get the header, not be read as a slash command"
            )
            XCTAssertTrue(framed.hasSuffix("\n\n" + text))
        }
    }

    func testIsSlashCommandMatchesTheCommandShapeOnly() {
        XCTAssertTrue(SessionMessenger.isSlashCommand("/compact"))
        XCTAssertTrue(SessionMessenger.isSlashCommand("/rename Nova"))
        XCTAssertTrue(SessionMessenger.isSlashCommand("/RENAME Nova"), "case-insensitive")
        XCTAssertTrue(SessionMessenger.isSlashCommand("/model-switch fast"))
        XCTAssertFalse(SessionMessenger.isSlashCommand("/tmp/build.log has the answer"))
        XCTAssertFalse(SessionMessenger.isSlashCommand("/Users/you/notes.md"))
        XCTAssertFalse(SessionMessenger.isSlashCommand("/123abc"), "must start with a letter")
        XCTAssertFalse(SessionMessenger.isSlashCommand("go start on 09"))
        XCTAssertFalse(SessionMessenger.isSlashCommand(""))
    }

    /// The header travels on the wire: the session-level path frames, the wire half does not
    /// (the wire tests above check exact content and stay as they are).
    func testTheHeaderIsOnTheWireForASessionSend() throws {
        let home = temporaryHome()
        let server = FakeSocketServer(behaviour: .reply(#"{"ok":true}"#))
        self.server = server
        try server.start()
        XCTAssertTrue(home.ensure(home.tokens))
        try "tok\n".write(
            to: home.tokenFile(agent: .claude, sessionID: "s-hdr"), atomically: true, encoding: .utf8
        )

        let result = SessionMessenger.sendSynchronously(
            text: "Continue with lane 2",
            session: claudeSession(id: "s-hdr", socket: server.path),
            home: home,
            environment: { _ in (nil, nil) }
        )
        XCTAssertEqual(result, .sent(reply: #"{"ok":true}"#))
        let lines = server.receivedLines
        XCTAssertEqual(lines.count, 2)
        let message = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any]
        )
        let inner = try XCTUnwrap(message["message"] as? [String: Any])
        XCTAssertEqual(inner["content"] as? String, SessionMessenger.header + "\n\nContinue with lane 2")
    }

    /// No file yet: the procargs fallback still sends (SPEC §15.1 keeps it).
    func testWithoutATokenFileTheProcessEnvironmentIsUsed() throws {
        let home = temporaryHome()
        let server = FakeSocketServer(behaviour: .reply(#"{"ok":true}"#))
        self.server = server
        try server.start()

        let result = SessionMessenger.sendSynchronously(
            text: "Continue",
            session: claudeSession(id: "s-proc", socket: server.path),
            home: home,
            environment: { _ in (nil, SecretToken("tok-from-procargs")) }
        )
        XCTAssertEqual(result, .sent(reply: #"{"ok":true}"#))
        XCTAssertEqual(try authToken(server), "tok-from-procargs")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: home.tokens.path),
            "reading a token must never create the directory it looks in"
        )
    }

    /// Neither source: the one reason that says *why*, and no connection attempt at all.
    func testWithNeitherSourceTheReasonNamesTheMissingTokenFile() throws {
        let home = temporaryHome()
        let server = FakeSocketServer(behaviour: .reply(#"{"ok":true}"#))
        self.server = server
        try server.start()

        let result = SessionMessenger.sendSynchronously(
            text: "Continue",
            session: claudeSession(id: "s-none", socket: server.path),
            home: home,
            environment: { _ in (nil, nil) }
        )
        XCTAssertEqual(
            result,
            .failed(reason: "no token file yet — the session has not reported since the upgrade")
        )
        XCTAssertEqual(result.reason, SessionMessenger.noTokenReason)
        XCTAssertTrue(server.receivedLines.isEmpty, "nothing was sent")
    }

    /// The resolution rule and the file reader on their own.
    func testTheTokenSourceOrderAndWhatCountsAsAToken() throws {
        let home = temporaryHome()
        XCTAssertEqual(
            SessionMessenger.resolve(file: SecretToken("f"), process: SecretToken("p")),
            SessionMessenger.ResolvedToken(token: SecretToken("f"), source: .file)
        )
        XCTAssertEqual(
            SessionMessenger.resolve(file: nil, process: SecretToken("p")),
            SessionMessenger.ResolvedToken(token: SecretToken("p"), source: .process)
        )
        // An empty file is not a token — it falls through to the process.
        XCTAssertEqual(
            SessionMessenger.resolve(file: SecretToken(""), process: SecretToken("p"))?.source,
            .process
        )
        XCTAssertNil(SessionMessenger.resolve(file: nil, process: nil))
        XCTAssertNil(SessionMessenger.resolve(file: SecretToken(""), process: SecretToken("")))

        var session = Session()
        session.agent = .claude
        session.sessionID = "s1"
        XCTAssertNil(SessionMessenger.tokenFile(for: session, home: home), "no file, no token")

        XCTAssertTrue(home.ensure(home.tokens))
        let url = home.tokenFile(agent: .claude, sessionID: "s1")
        try "\n\t \n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(SessionMessenger.tokenFile(for: session, home: home), "whitespace is empty")

        try "sk-live-token".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            SessionMessenger.tokenFile(for: session, home: home), SecretToken("sk-live-token")
        )
        // A blank session id has no file name of its own.
        var anonymous = session
        anonymous.sessionID = ""
        XCTAssertNil(SessionMessenger.tokenFile(for: anonymous, home: home))
    }

    func testADeadProcessIsRefusedBeforeAnyEnvironmentIsRead() {
        let home = LookoutHome(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-send-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: home.root) }

        var session = Session()
        session.sessionID = "s2"
        session.agent = .claude
        session.pid = Int32.max
        session.messagingSocket = "/tmp/cc-socks/never.sock"
        XCTAssertEqual(
            SessionMessenger.sendSynchronously(text: "x", session: session, home: home),
            .failed(reason: "session process is gone")
        )
    }
}
