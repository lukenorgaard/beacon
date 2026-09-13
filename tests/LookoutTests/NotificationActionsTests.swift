import AppKit
import UserNotifications
import XCTest
@testable import Lookout

/// A fake `UNUserNotificationCenter`: the one real method `NotificationActionRouter` needs from
/// it, recorded instead of performed (SPEC §17.1).
final class FakeNotificationCenter: NotificationRemoving {
    private(set) var removed: [[String]] = []

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removed.append(identifiers)
    }
}

/// SPEC §17.1: category registration (pure — building a `UNNotificationCategory` needs no bundle
/// and no live center) and response routing, driven entirely through `NotificationActionRouter`'s
/// own seams plus the fake center above.
final class NotificationActionsTests: XCTestCase {
    // MARK: - Category registration

    func testFourCategoriesAreRegisteredWithTheRightIdentifiers() {
        let categories = NotificationActions.categories()
        let identifiers = Set(categories.map(\.identifier))
        XCTAssertEqual(identifiers, [
            NotificationCategory.permission.rawValue,
            NotificationCategory.question.rawValue,
            NotificationCategory.codexQuestion.rawValue,
            NotificationCategory.done.rawValue,
        ])
    }

    func testPermissionOffersAllowDenyAndOpen() {
        let permission = NotificationActions.categories()
            .first { $0.identifier == NotificationCategory.permission.rawValue }
        let ids = permission?.actions.map(\.identifier) ?? []
        XCTAssertEqual(ids, [
            NotificationActionID.allow, NotificationActionID.deny, NotificationActionID.open,
        ])
        XCTAssertTrue(permission?.actions.first?.options.isEmpty ?? false, "Allow is plain")
        XCTAssertEqual(permission?.actions[1].options, [.destructive], "Deny reads as destructive")
    }

    /// question and done both get Open and a text-input Reply… (SPEC §17.1).
    func testQuestionAndDoneOfferOpenAndReply() {
        let categories = NotificationActions.categories()
        for identifier in [NotificationCategory.question.rawValue, NotificationCategory.done.rawValue] {
            let category = categories.first { $0.identifier == identifier }
            let ids = category?.actions.map(\.identifier) ?? []
            XCTAssertEqual(ids, [NotificationActionID.open, NotificationActionID.reply], identifier)
            XCTAssertTrue(
                category?.actions.last is UNTextInputNotificationAction,
                "\(identifier): Reply… takes typed text"
            )
        }
    }

    func testCategoryOfSessionPicksPermissionQuestionOrDoneAndNilOtherwise() {
        var permission = Session()
        permission.state = .needsYou
        permission.reason = "permission"
        XCTAssertEqual(NotificationCategory.of(session: permission), .permission)

        var question = permission
        question.reason = "question"
        XCTAssertEqual(NotificationCategory.of(session: question), .question)

        var done = Session()
        done.state = .done
        XCTAssertEqual(NotificationCategory.of(session: done), .done)

        var working = Session()
        working.state = .working
        XCTAssertNil(NotificationCategory.of(session: working))
    }

    // MARK: - Response routing (fake center)

    private func session(agent: SessionAgent = .claude, host: SessionHost = .cursor) -> Session {
        var value = Session()
        value.sessionID = "s1"
        value.state = .needsYou
        value.agent = agent
        value.project = "daily-notes"
        value.host = host
        value.pid = 1
        value.stateSince = Date()
        return value
    }

    private func request(waitsUntil: Date? = Date().addingTimeInterval(45)) throws -> AttentionRequest {
        var json = """
        {"session_id":"s1","request_id":"r1","kind":"permission","tool_name":"Bash",
         "command_or_path":"rm -rf build"
        """
        if let waitsUntil { json += ",\"waits_until\":\"\(ISO8601.string(waitsUntil))\"" }
        json += "}"
        return try XCTUnwrap(AttentionRequest.decode(Data(json.utf8), name: "claude-s1-r1"))
    }

    private func makeRouter(
        home: LookoutHome, center: FakeNotificationCenter, sessions: [Session],
        requests: RequestStore? = nil
    ) -> NotificationActionRouter {
        let router = NotificationActionRouter(
            requests: requests ?? RequestStore(home: home), home: home, center: center,
            sessionLookup: { id in sessions.first { $0.sessionID == id } }
        )
        // SPEC §17.7: no test may spawn a real `codex` process — the same "not installed" case
        // a real machine without Codex would see.
        router.codexSender = { _, _, completion in
            completion(.failed(reason: "codex binary not found"))
        }
        return router
    }

    private func makeHome() -> LookoutHome {
        LookoutHome(
            root: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("lookout-notif-\(UUID().uuidString)")
        )
    }

    /// Writes a request file for real and waits for `RequestStore`'s own directory watcher to
    /// load it — the same asynchronous path the app uses, not a shortcut around it.
    private func loadedRequestStore(home: LookoutHome, request: AttentionRequest) throws -> RequestStore {
        try FileManager.default.createDirectory(
            at: home.requests, withIntermediateDirectories: true
        )
        try JSONEncoder().encode(request).write(
            to: home.requests.appendingPathComponent("\(request.name).json")
        )
        let store = RequestStore(home: home)
        store.start()
        let deadline = Date().addingTimeInterval(3)
        while store.requests.isEmpty, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return store
    }


    /// SPEC §17.10: a Codex question gets Open only — a banner "Reply…" would go through
    /// `codex queue`, which starts a new turn instead of answering the prompt.
    func testCodexQuestionGetsItsOwnCategoryWithoutReply() {
        var question = Session()
        question.state = .needsYou
        question.reason = "question"
        question.agent = .codex
        XCTAssertEqual(NotificationCategory.of(session: question), .codexQuestion)
        let categories = NotificationActions.categories()
        let codex = categories.first { $0.identifier == NotificationCategory.codexQuestion.rawValue }
        XCTAssertEqual(codex?.actions.map(\.identifier), [NotificationActionID.open])
    }
    func testOpenJumpsAndClearsTheBanner() {
        let center = FakeNotificationCenter()
        let home = makeHome()
        let router = makeRouter(home: home, center: center, sessions: [session()])
        var jumped: Session?
        router.jumper = { jumped = $0 }

        router.handle(actionID: NotificationActionID.open, sessionID: "s1", text: nil) { _ in
            XCTFail("Open never opens the card")
        }

        XCTAssertEqual(jumped?.sessionID, "s1")
        XCTAssertEqual(center.removed, [["s1"]])
    }

    func testAllowWritesTheAnswerFileAndClearsTheBanner() throws {
        let center = FakeNotificationCenter()
        let home = makeHome()
        let request = try request()
        let requests = try loadedRequestStore(home: home, request: request)
        let router = makeRouter(home: home, center: center, sessions: [session()], requests: requests)

        var opened = false
        router.handle(actionID: NotificationActionID.allow, sessionID: "s1", text: nil) { _ in
            opened = true
        }

        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(
            atPath: AnswerWriter.url(for: request, in: home.answers).path
        ), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        XCTAssertFalse(opened, "a fresh, answerable request never falls back to opening the card")
        XCTAssertEqual(AnswerWriter.read(AnswerWriter.url(for: request, in: home.answers))?.decision, .allow)
        XCTAssertEqual(center.removed, [["s1"]])
    }

    /// The request genuinely loaded (unlike "no request at all" below) but `isAnswerable()`
    /// says no — the card, not the answer file, is what SPEC §17.1 wants for it.
    func testAllowOnAnExpiredRequestOpensTheCardInstead() throws {
        let center = FakeNotificationCenter()
        let home = makeHome()
        let expired = try request(waitsUntil: Date().addingTimeInterval(-5))
        let requests = try loadedRequestStore(home: home, request: expired)
        XCTAssertEqual(requests.request(for: "s1")?.requestID, "r1", "the file did load")

        let router = makeRouter(home: home, center: center, sessions: [session()], requests: requests)
        var opened: Session?
        router.handle(actionID: NotificationActionID.allow, sessionID: "s1", text: nil) {
            opened = $0
        }

        XCTAssertEqual(opened?.sessionID, "s1")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: home.answers.path),
            "an expired request must not leave an answer nobody reads"
        )
    }

    func testAllowWithNoRequestAtAllOpensTheCard() {
        let center = FakeNotificationCenter()
        let home = makeHome()
        let router = makeRouter(home: home, center: center, sessions: [session()])
        var opened: Session?
        router.handle(actionID: NotificationActionID.allow, sessionID: "s1", text: nil) {
            opened = $0
        }
        XCTAssertEqual(opened?.sessionID, "s1")
    }

    /// SPEC §17.1: Reply goes down the same channel order Send does — socket first — and logs
    /// under the `notification` channel so `answers.log` can tell it apart from a card reply.
    func testReplySendsOverTheSocketAndLogsUnderTheNotificationChannel() throws {
        let center = FakeNotificationCenter()
        let home = makeHome()
        let router = makeRouter(home: home, center: center, sessions: [session()])
        var sent: (String, Session)?
        router.sender = { text, session, completion in
            sent = (text, session)
            completion(.sent(reply: nil))
        }

        router.handle(actionID: NotificationActionID.reply, sessionID: "s1", text: "Go ahead") { _ in
            XCTFail("a successful send never opens the card")
        }

        XCTAssertEqual(sent?.0, "Go ahead")
        XCTAssertEqual(center.removed, [["s1"]])

        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: home.answersLog.path), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        let log = try String(contentsOf: home.answersLog, encoding: .utf8)
        XCTAssertTrue(log.contains("notification · sent"), log)
    }

    /// Socket fails, no companion (Terminal.app has none) → Copy & go, still under `notification`.
    func testReplyFallsBackToCopyAndGoWhenTheSocketFails() throws {
        let center = FakeNotificationCenter()
        let home = makeHome()
        var terminalSession = session()
        terminalSession.host = .terminal
        let router = makeRouter(home: home, center: center, sessions: [terminalSession])
        router.sender = { _, _, completion in completion(.failed(reason: "socket closed")) }
        var jumped: Session?
        router.jumper = { jumped = $0 }

        NSPasteboard.general.clearContents()
        router.handle(actionID: NotificationActionID.reply, sessionID: "s1", text: "Run it") { _ in }

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Run it")
        XCTAssertEqual(jumped?.sessionID, "s1")

        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: home.answersLog.path), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        let log = try String(contentsOf: home.answersLog, encoding: .utf8)
        XCTAssertTrue(log.contains("notification · send-failed"), log)
    }

    /// A session with no messaging socket (Codex) but a live companion still delivers, exactly
    /// as the card's own Send does (SPEC §16.3).
    /// SPEC §17.7: a Codex reply tries `codex queue` first — not the socket, which Codex never
    /// has — and only falls back to the companion when that command fails.
    func testReplyGoesToCodexQueueThenTheCompanionWhenThatFails() throws {
        let center = FakeNotificationCenter()
        let home = makeHome()
        let codexInCursor = session(agent: .codex, host: .cursor)
        let router = makeRouter(home: home, center: center, sessions: [codexInCursor])
        var socketCalls = 0
        router.sender = { _, _, completion in
            socketCalls += 1
            completion(.failed(reason: "unused"))
        }
        var queueText: String?
        router.codexSender = { text, _, completion in
            queueText = text
            completion(.failed(reason: "codex binary not found"))
        }
        var companionText: String?
        router.companionSender = { text, _, completion in
            companionText = text
            completion(StubCompanion.match())
        }

        router.handle(actionID: NotificationActionID.reply, sessionID: "s1", text: "004") { _ in }

        XCTAssertEqual(socketCalls, 0, "codex has no socket — nothing is attempted on it")
        XCTAssertEqual(queueText, "004", "codex queue is tried before the companion")
        XCTAssertEqual(companionText, "004")

        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: home.answersLog.path), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        let log = try String(contentsOf: home.answersLog, encoding: .utf8)
        XCTAssertTrue(log.contains("notification · companion"), log)
    }

    /// A `codex queue` reply that succeeds never touches the companion at all.
    func testReplyThroughCodexQueueNeverTouchesTheCompanionWhenItSucceeds() throws {
        let center = FakeNotificationCenter()
        let home = makeHome()
        let codexInCursor = session(agent: .codex, host: .cursor)
        let router = makeRouter(home: home, center: center, sessions: [codexInCursor])
        router.codexSender = { _, _, completion in completion(.sent) }
        router.companionSender = { _, _, completion in
            XCTFail("codex queue already delivered the reply")
            completion(nil)
        }

        router.handle(actionID: NotificationActionID.reply, sessionID: "s1", text: "004") { _ in }
    }

    func testAnUnknownActionIdentifierIsIgnored() {
        let center = FakeNotificationCenter()
        let home = makeHome()
        let router = makeRouter(home: home, center: center, sessions: [session()])
        router.jumper = { _ in XCTFail("nothing should happen") }
        router.handle(actionID: "com.apple.something.else", sessionID: "s1", text: nil) { _ in }
        // The banner is still cleared — "removed after an action" applies whatever the button.
        XCTAssertEqual(center.removed, [["s1"]])
    }

    func testAnUnknownSessionIsANoOp() {
        let center = FakeNotificationCenter()
        let home = makeHome()
        let router = makeRouter(home: home, center: center, sessions: [])
        router.handle(actionID: NotificationActionID.open, sessionID: "ghost", text: nil) { _ in }
        XCTAssertTrue(center.removed.isEmpty, "an unknown session clears nothing")
    }
}
