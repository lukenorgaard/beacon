import AppKit
import SwiftUI
import XCTest
@testable import Lookout

extension AttentionCardTests {
    // MARK: - §16.3 the editor companion

    /// The order §16.3 writes: socket first, companion second, Copy & go last.
    func testAFailedSendGoesToTheCompanionBeforeTheClipboard() throws {
        let (model, coordinator) = makeModel()
        coordinator.present(session())
        model.present(coordinator.current, request: try request())
        model.text = "Yes, go ahead"

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("untouched", forType: .string)

        var order: [String] = []
        var sentViaCompanion: [String] = []
        model.jumper = { _ in order.append("jump") }
        model.sender = { _, _, completion in
            order.append("socket")
            completion(.failed(reason: "socket closed"))
        }
        model.companionSender = { text, _, completion in
            order.append("companion")
            sentViaCompanion.append(text)
            completion(StubCompanion.match())
        }

        model.send()

        XCTAssertEqual(order, ["socket", "companion"], "no Copy & go once the companion took it")
        XCTAssertEqual(sentViaCompanion, ["Yes, go ahead"])
        XCTAssertEqual(model.status, "Sent via companion")
        XCTAssertFalse(model.statusIsError)
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string), "untouched",
            "the clipboard is only touched when the companion did not deliver"
        )
        XCTAssertNil(coordinator.current)
        XCTAssertFalse(model.isSending)

        // And it is logged as a message, not as a clipboard fallback (SPEC §11.4).
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: home.answersLog.path), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        let log = try String(contentsOf: home.answersLog, encoding: .utf8)
        XCTAssertTrue(log.contains("message · companion"), log)
    }

    /// No companion answers → the §11.4 fallback, word for word what it always was.
    func testACompanionThatDoesNotMatchStillFallsBackToCopyAndGo() throws {
        let (model, coordinator) = makeModel()
        coordinator.present(session())
        model.present(coordinator.current, request: try request())
        model.text = "Yes, go ahead"

        var order: [String] = []
        model.jumper = { _ in order.append("jump") }
        model.sender = { _, _, completion in
            order.append("socket")
            completion(.failed(reason: "socket closed"))
        }
        model.companionSender = { _, _, completion in
            order.append("companion")
            completion(nil)
        }

        model.send()
        XCTAssertEqual(order, ["socket", "companion", "jump"])
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Yes, go ahead")
        XCTAssertEqual(model.status, "Send failed (socket closed) → copied and opened Cursor")
        XCTAssertTrue(model.statusIsError)
        XCTAssertNil(coordinator.current)
    }

    /// SPEC §16.3: an agent with no socket and no `codex queue`-style channel of its own still
    /// gets Send once a companion can type into its terminal — so inside Cursor the button
    /// works, and it never touches the socket path.
    func testALiveCompanionTurnsSendOnForASessionWithNoKnownChannel() throws {
        let (model, coordinator) = makeModel()
        model.companionProbe = { session, completion in
            completion(EditorCompanion.app(for: session.host) != nil)
        }
        let agent = SessionAgent(raw: "gemini")
        coordinator.present(session(id: "s1", state: .needsYou, agent: agent))
        model.present(coordinator.current, request: try request(kind: "question"))
        model.text = "Run 004 first"

        XCTAssertTrue(model.companionAvailable)
        XCTAssertTrue(model.canSend)
        XCTAssertEqual(
            model.sendHelp, "Type it into the Cursor terminal through the companion (⌘↩)"
        )

        var socketCalls = 0
        model.sender = { _, _, completion in
            socketCalls += 1
            completion(.failed(reason: "unused"))
        }
        model.companionSender = { _, _, completion in completion(StubCompanion.match()) }

        model.send()
        XCTAssertEqual(socketCalls, 0, "no socket for this agent — nothing is attempted on it")
        XCTAssertEqual(model.status, "Sent via companion")
        XCTAssertNil(coordinator.current)
    }

    /// And when the companion is not installed either, the button is off exactly as §11.2 says.
    func testWithoutACompanionASessionWithNoKnownChannelStillOnlyHasCopyAndGo() throws {
        let (model, coordinator) = makeModel()
        let agent = SessionAgent(raw: "gemini")
        coordinator.present(session(id: "s1", state: .needsYou, agent: agent))
        model.present(coordinator.current, request: try request(kind: "question"))
        model.text = "Run 004 first"

        XCTAssertFalse(model.companionAvailable)
        XCTAssertFalse(model.canSend)
        XCTAssertEqual(model.sendHelp, "gemini has no messaging socket — use Copy & go")
    }

    /// A session outside the three editors never pays for a companion round trip.
    func testANonEditorHostSkipsTheCompanionEntirely() throws {
        let (model, coordinator) = makeModel()
        var terminalSession = session()
        terminalSession.host = .terminal
        coordinator.present(terminalSession)
        model.present(coordinator.current, request: try request())
        model.text = "Yes"

        var asked = false
        model.jumper = { _ in }
        model.sender = { _, _, completion in completion(.failed(reason: "socket closed")) }
        model.companionSender = { _, _, completion in asked = true; completion(nil) }

        model.send()
        XCTAssertFalse(asked, "Terminal.app has no companion to ask")
        XCTAssertEqual(model.status, "Send failed (socket closed) → copied and opened Terminal")
    }

    /// A socket that works is still the primary path — the companion is never consulted.
    func testASuccessfulSocketSendNeverAsksTheCompanion() throws {
        let (model, coordinator) = makeModel()
        coordinator.present(session())
        model.present(coordinator.current, request: try request())
        model.text = "Continue"

        var asked = false
        model.sender = { _, _, completion in completion(.sent(reply: nil)) }
        model.companionSender = { _, _, completion in asked = true; completion(nil) }

        model.send()
        XCTAssertFalse(asked)
        XCTAssertTrue(model.status?.hasPrefix("Sent · ") ?? false, "\(model.status ?? "nil")")
        XCTAssertNil(coordinator.current)
    }

    /// Bug fix (2026-09-04): the request behind a card can go bad without the card itself
    /// changing — the session's `request_id` clears or moves on, or the request simply ages out
    /// (see `RequestStore.request(for session:)`) — and `AttentionCardWindow.sync()` then hands
    /// `present(_:request:)` a `nil` in its place. The card must drop the ask immediately (it
    /// falls back to the plain state-file-only card `SuggestionContext` already builds for a
    /// `nil` request) without throwing away whatever the owner was mid-typing.
    func testARequestThatGoesInvalidDropsTheAskButKeepsTheTypedReply() throws {
        let (model, coordinator) = makeModel()
        coordinator.present(session())
        model.present(coordinator.current, request: try request())
        XCTAssertNotNil(model.request)
        XCTAssertTrue(model.canAnswerWithFile)

        model.text = "half-written reply"

        // Same card (same session id) — only the request went away.
        model.present(coordinator.current, request: nil)

        XCTAssertNil(model.request)
        XCTAssertFalse(model.canAnswerWithFile, "nothing left to answer with a file")
        XCTAssertEqual(
            model.text, "half-written reply", "typing must survive the request going away"
        )
        // Falls back to the plain needs-you card built from the session alone (SPEC §11.4):
        // `session().reason` is nil, so that is a permission ask, not a question.
        XCTAssertEqual(model.kind, .permission)
    }

    /// The exact shape of the reported bug, end to end: an `AskUserQuestion` request file is
    /// still sitting on disk six hours after it was answered in the terminal; the session moved
    /// on and finished; `RequestStore.request(for session:)` — what `AttentionCardWindow.sync()`
    /// actually calls — must refuse it, and the card built from that `nil` must be the plain
    /// done view, not the six-hour-old question.
    func testEndToEndAStaleOrphanedQuestionNeverReachesTheCardForAFinishedSession() throws {
        let requests = RequestStore(home: home)
        try FileManager.default.createDirectory(
            at: home.requests, withIntermediateDirectories: true
        )
        let stale = """
        {"session_id":"s1","request_id":"old-question","kind":"question",
         "question":"Which migration?","options":["004","005"],
         "created_at":"\(ISO8601.string(Date().addingTimeInterval(-6 * 3600)))"}
        """
        try Data(stale.utf8).write(
            to: home.requests.appendingPathComponent("claude-s1-old-question.json")
        )
        requests.start()
        let settled = Date().addingTimeInterval(1)
        while Date() < settled {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        // The session moved on: `done` now, and the reporter cleared its `request_id` — but the
        // orphaned file is still sitting in `requests/`.
        var finished = session(state: .done)
        finished.requestID = nil
        let found = requests.request(for: finished)
        XCTAssertNil(found, "a done session must never get the six-hour-old question back")

        let (model, coordinator) = makeModel()
        coordinator.present(finished)
        model.present(coordinator.current, request: found)
        XCTAssertNil(model.request)
        XCTAssertEqual(model.kind, .done)
    }

    func testSwitchingCardsResetsTheFieldButRefreshingTheSameOneDoesNot() throws {
        let (model, coordinator) = makeModel()
        coordinator.present(session(id: "a"))
        model.present(coordinator.current, request: nil)
        model.text = "half-written reply"

        // Same card, newer snapshot: the reply survives.
        model.present(coordinator.current, request: nil)
        XCTAssertEqual(model.text, "half-written reply")

        coordinator.dismissCurrent()
        coordinator.present(session(id: "b"))
        model.present(coordinator.current, request: nil)
        XCTAssertEqual(model.text, "")
        XCTAssertNil(model.status)
    }
}
