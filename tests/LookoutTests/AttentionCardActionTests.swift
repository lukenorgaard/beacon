import AppKit
import SwiftUI
import XCTest
@testable import Lookout

extension AttentionCardTests {
    // MARK: - Actions (SPEC §11.4)

    func makeModel() -> (AttentionCardModel, AttentionCoordinator) {
        let coordinator = AttentionCoordinator(settings: settings)
        let model = AttentionCardModel(
            settings: settings, coordinator: coordinator, suggester: Suggester(), home: home
        )
        model.jumper = { _ in }
        // SPEC §16.3: no test may reach a real editor window. The companion answers "no match"
        // unless the test says otherwise, which is the machine-with-no-companion case.
        model.companionSender = { _, _, completion in completion(nil) }
        model.companionProbe = { _, completion in completion(false) }
        // SPEC §17.7: no test may spawn a real `codex` process. Failing here is what "the
        // binary is not installed" looks like — the same case as a real machine without Codex.
        model.codexSender = { _, _, completion in
            completion(.failed(reason: "codex binary not found"))
        }
        return (model, coordinator)
    }

    func testAllowWritesTheAnswerFileAndSaysSo() throws {
        let (model, coordinator) = makeModel()
        let request = try request()
        coordinator.present(session())
        model.present(coordinator.current, request: request)

        XCTAssertTrue(model.canAnswerWithFile)
        XCTAssertFalse(model.isExpired)
        model.answer(.allow)

        let url = AnswerWriter.url(for: request, in: home.answers)
        let deadline = Date().addingTimeInterval(3)
        while model.answered == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(model.answered, .allow)
        XCTAssertEqual(model.status, "Answered · allow")
        XCTAssertEqual(AnswerWriter.read(url)?.decision, .allow)
        // The card stays until the session leaves needs_you (SPEC §11.4).
        XCTAssertEqual(coordinator.current?.id, "s1")
    }

    func testAnExpiredRequestOffersTheTerminalInsteadOfAllowAndDeny() throws {
        let (model, coordinator) = makeModel()
        coordinator.present(session())
        model.present(
            coordinator.current, request: try request(waitsUntil: Date().addingTimeInterval(-1))
        )

        XCTAssertTrue(model.isExpired)
        XCTAssertFalse(model.canAnswerWithFile)

        model.answer(.allow)
        XCTAssertTrue(model.statusIsError)
        XCTAssertEqual(model.status, "Answer in the terminal — the request already timed out")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: home.answers.path),
            "an expired request must not leave an answer nobody reads"
        )
    }

    func testUseSuggestionFillsTheFieldAndNeverSends() throws {
        let (model, coordinator) = makeModel()
        coordinator.present(session())
        model.present(coordinator.current, request: try request())

        // The heuristic answers synchronously, so it is already there.
        XCTAssertEqual(model.suggestion, "Allow — runs `rm -rf build`")
        XCTAssertTrue(model.text.isEmpty)

        model.useSuggestion()
        XCTAssertEqual(model.text, "Allow — runs `rm -rf build`")
        XCTAssertNil(model.status, "filling the field is not an action")
        XCTAssertEqual(coordinator.current?.id, "s1", "nothing was sent, nothing was dismissed")

        // An option button does the same thing.
        model.use(option: "Run 004 first")
        XCTAssertEqual(model.text, "Run 004 first")
    }

    func testAFailedSendCopiesAndJumpsInstead() throws {
        let (model, coordinator) = makeModel()
        coordinator.present(session())
        model.present(coordinator.current, request: try request())
        model.text = "Yes, go ahead"

        var jumped = false
        model.jumper = { _ in jumped = true }
        model.sender = { _, _, completion in completion(.failed(reason: "socket closed")) }

        XCTAssertTrue(model.canSend)
        model.send()

        XCTAssertTrue(jumped, "a failed Send falls back to Copy & go (SPEC §11.4)")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Yes, go ahead")
        XCTAssertEqual(model.status, "Send failed (socket closed) → copied and opened Cursor")
        XCTAssertTrue(model.statusIsError)
        XCTAssertNil(coordinator.current, "the card is done with either way")
    }

    /// SPEC §15.1: a `question` is a dialog waiting in the terminal, so a failed Send says what
    /// to do with what it just copied. A permission prompt needs no such note.
    func testAFailedSendOnAQuestionSaysWhatToDoWithTheCopy() throws {
        let (model, coordinator) = makeModel()
        coordinator.present(session())
        model.present(coordinator.current, request: try request(kind: "question"))
        model.text = "Run 004 first"
        model.jumper = { _ in }
        model.sender = { _, _, completion in completion(.failed(reason: "socket closed")) }

        model.send()
        XCTAssertEqual(
            model.status,
            "Send failed (socket closed) → copied and opened Cursor — paste it into the question there"
        )
        XCTAssertTrue(model.statusIsError)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Run 004 first")
        XCTAssertNil(coordinator.current, "Copy & go still happened automatically")

        // The note is per request kind, and nothing else about the line changed.
        XCTAssertEqual(
            AttentionCardModel.failureStatus(reason: "x", target: "Cursor", kind: .permission),
            "Send failed (x) → copied and opened Cursor"
        )
        XCTAssertEqual(
            AttentionCardModel.failureStatus(reason: "x", target: "Cursor", kind: nil),
            "Send failed (x) → copied and opened Cursor"
        )
    }

    /// A `question` that *does* send says exactly what any other one says (SPEC §15.1).
    func testASuccessfulSendOnAQuestionStillJustSaysSent() throws {
        let (model, coordinator) = makeModel()
        coordinator.present(session())
        model.present(coordinator.current, request: try request(kind: "question"))
        model.text = "004"
        model.sender = { _, _, completion in completion(.sent(reply: nil)) }

        model.send()
        XCTAssertFalse(model.statusIsError)
        XCTAssertEqual(model.status, "Sent · \(AttentionCardModel.clock(Date()))")
        XCTAssertNil(coordinator.current)
    }

    func testASuccessfulSendSaysSentAndClosesTheCard() throws {
        let (model, coordinator) = makeModel()
        coordinator.present(session())
        model.present(coordinator.current, request: try request())
        model.text = "Continue"
        model.sender = { _, _, completion in completion(.sent(reply: nil)) }

        model.send()
        XCTAssertFalse(model.statusIsError)
        XCTAssertTrue(model.status?.hasPrefix("Sent · ") ?? false, "\(model.status ?? "nil")")
        XCTAssertNil(coordinator.current)

        // Every action lands in answers.log (SPEC §11.4).
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: home.answersLog.path), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        let log = try String(contentsOf: home.answersLog, encoding: .utf8)
        XCTAssertTrue(log.contains("daily-notes/s1 · message · sent · \"Continue\""), log)
    }

    /// SPEC §17.7 gives Codex its own channel (`codex queue`), so it no longer belongs in this
    /// case — an agent Lookout has never heard of, with no socket, no `codex queue` and no
    /// companion, is what "Send is off" actually looks like now.
    func testSendIsOffForAnAgentWithNoDeliveryChannelButCopyAndGoIsNot() throws {
        let (model, coordinator) = makeModel()
        let agent = SessionAgent(raw: "gemini")
        coordinator.present(session(id: "s1", state: .needsYou, agent: agent))
        model.present(coordinator.current, request: try request(kind: "question"))
        model.text = "Run 004 first"

        XCTAssertFalse(model.canSend)
        XCTAssertTrue(model.canCopy)
        XCTAssertEqual(model.sendHelp, "gemini has no messaging socket — use Copy & go")

        model.copyAndGo()
        XCTAssertEqual(model.status, "Copied and opened Cursor")
        XCTAssertNil(coordinator.current)
    }

    /// SPEC §17.7: Codex has no messaging socket at all, but `codex queue` is its own Send
    /// channel — Send works even with no companion installed, unlike every other socket-less host.
    func testCodexSendsThroughCodexQueueWithoutASocketOrACompanion() throws {
        let (model, coordinator) = makeModel()
        coordinator.present(session(id: "s1", state: .needsYou, agent: .codex))
        model.present(coordinator.current, request: try request(kind: "question"))
        model.text = "Run 004 first"

        XCTAssertFalse(model.companionAvailable)
        XCTAssertTrue(model.canSend, "codex queue is its own channel — no companion required")
        XCTAssertEqual(model.sendHelp, "Send via `codex queue` without moving focus (⌘↩)")

        var queueCalls = 0
        model.codexSender = { text, session, completion in
            queueCalls += 1
            XCTAssertEqual(text, "Run 004 first")
            XCTAssertEqual(session.agent, .codex)
            completion(.sent)
        }

        model.send()
        XCTAssertEqual(queueCalls, 1)
        XCTAssertFalse(model.statusIsError)
        XCTAssertTrue(model.status?.hasPrefix("Sent · ") ?? false, "\(model.status ?? "nil")")
        XCTAssertNil(coordinator.current)
    }

    /// A failed `codex queue` falls back to the companion, then Copy & go — the same chain a
    /// failed socket Send already uses.
    func testAFailedCodexQueueFallsBackToTheCompanionThenCopyAndGo() throws {
        let (model, coordinator) = makeModel()
        coordinator.present(session(id: "s1", state: .needsYou, agent: .codex))
        model.present(coordinator.current, request: try request(kind: "question"))
        model.text = "Run 004 first"

        model.codexSender = { _, _, completion in
            completion(.failed(reason: "codex binary not found"))
        }
        model.companionSender = { _, _, completion in completion(StubCompanion.match()) }

        model.send()
        XCTAssertEqual(model.status, "Sent via companion")
        XCTAssertFalse(model.statusIsError)
        XCTAssertNil(coordinator.current)
    }
}
