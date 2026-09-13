import AppKit
import SwiftUI
import XCTest
@testable import Lookout

extension CodexQuestionWatcherTests {
    // MARK: - Card request construction (item 3)

    private func makeCardModel() -> (AttentionCardModel, AttentionCoordinator) {
        let coordinator = AttentionCoordinator(settings: settings)
        let model = AttentionCardModel(
            settings: settings, coordinator: coordinator, suggester: Suggester(), home: home
        )
        model.jumper = { _ in }
        model.companionSender = { _, _, completion in completion(nil) }
        model.companionProbe = { _, completion in completion(false) }
        model.codexSender = { _, _, completion in
            completion(.failed(reason: "codex binary not found"))
        }
        return (model, coordinator)
    }

    private func codexQuestionSession(id: String = "s1") -> Session {
        var value = Session()
        value.sessionID = id
        value.agent = .codex
        value.state = .needsYou
        value.reason = "question"
        value.project = "acme-web"
        value.cwd = "/tmp/acme-web"
        value.host = .terminal
        value.detail = "Which plan?"
        value.stateSince = Date()
        return value
    }

    func testSendIsDisabledForACodexQuestionCardWithTheRightCaption() {
        let (model, coordinator) = makeCardModel()
        let session = codexQuestionSession()
        let request = question().attentionRequest(session: session)
        coordinator.present(session)
        model.present(coordinator.current, request: request)
        model.text = "Schema and data"

        XCTAssertTrue(model.isCodexQuestionCard)
        XCTAssertFalse(model.canSend, "Codex takes this answer only from its own prompt")
        XCTAssertTrue(model.canCopy)
        XCTAssertEqual(
            model.sendHelp,
            "Answer in the Codex terminal — Codex takes this answer only from its own prompt"
        )
        XCTAssertEqual(model.kind, .question)
    }

    func testClickingAnOptionFillsTheFieldForACodexQuestion() {
        let (model, coordinator) = makeCardModel()
        let session = codexQuestionSession()
        let request = question().attentionRequest(session: session)
        coordinator.present(session)
        model.present(coordinator.current, request: request)

        XCTAssertTrue(model.text.isEmpty)
        model.use(option: "A")
        XCTAssertEqual(model.text, "A")
    }

    func testCopyAndGoWorksForACodexQuestionCard() {
        let (model, coordinator) = makeCardModel()
        let session = codexQuestionSession()
        let request = question().attentionRequest(session: session)
        coordinator.present(session)
        model.present(coordinator.current, request: request)
        model.text = "Schema and data"

        var jumped = false
        model.jumper = { _ in jumped = true }
        model.copyAndGo()

        XCTAssertTrue(jumped)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Schema and data")
        XCTAssertNil(coordinator.current)
    }

    func testOpenJumpsAndDismissesTheCardForACodexQuestion() {
        let (model, coordinator) = makeCardModel()
        let session = codexQuestionSession()
        let request = question().attentionRequest(session: session)
        coordinator.present(session)
        model.present(coordinator.current, request: request)

        var jumped = false
        model.jumper = { _ in jumped = true }
        model.openSession()

        XCTAssertTrue(jumped)
        XCTAssertNil(coordinator.current)
    }

    /// A real Codex *permission* request must keep working exactly as before — only a genuine
    /// in-memory question disables Send.
    func testSendStaysOnForAnOrdinaryCodexPermissionCard() throws {
        let (model, coordinator) = makeCardModel()
        var session = codexQuestionSession()
        session.reason = "permission"
        var request = AttentionRequest()
        request.sessionID = "s1"
        request.kind = .permission
        request.toolName = "Bash"
        request.commandOrPath = "npm test"
        coordinator.present(session)
        model.present(coordinator.current, request: request)
        model.text = "Allow"

        XCTAssertFalse(model.isCodexQuestionCard)
        model.codexSender = { _, _, completion in completion(.sent) }
        XCTAssertTrue(model.canSend)
    }

    // MARK: - Layout: multiple questions stay readable at panel width

    private func layout<V: View>(_ view: V) -> NSSize {
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize
    }

    func testACardWithSeveralQuestionsStillFitsTheHeightCap() {
        let (model, coordinator) = makeCardModel()
        let session = codexQuestionSession()
        let multi = CodexQuestion(
            callID: "call_1",
            questions: [
                .init(id: "a", header: "Scope", question: "What should this cover?",
                      options: ["Schema only", "Schema and data", "Everything, staged"]),
                .init(id: "b", header: "Timing", question: "When should it run?",
                      options: ["Now", "Tonight", "Next maintenance window"]),
                .init(id: "c", header: nil, question: "Anything else to flag?", options: []),
            ],
            askedAt: Date()
        )
        coordinator.present(session)
        model.present(coordinator.current, request: multi.attentionRequest(session: session))

        let size = layout(AttentionCardView(model: model))
        XCTAssertEqual(size.width, settings.metrics.cardWidth, accuracy: 0.5)
        XCTAssertLessThanOrEqual(size.height, settings.metrics.cardMaxHeight)
    }
}
