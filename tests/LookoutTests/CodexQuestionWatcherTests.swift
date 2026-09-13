import AppKit
import SwiftUI
import XCTest
@testable import Lookout

/// Bug fix (2026-09-04): Codex asks a question in its TUI, but there is no hook for it — the
/// session sits reporting "Working · Bash" and "Needs you 0" while the user waits on a prompt
/// Lookout never mentions. This covers the four pieces that fix it: the pure parser
/// (`CodexQuestion.parse`), the pure per-cycle file check (`CodexQuestionCheck.run`), the pure
/// `AppState.apply()` decoration (`CodexQuestionDecoration`), and the card (Send disabled,
/// Copy & go/Open enabled, a hook-driven request always winning over the in-memory one).
final class CodexQuestionWatcherTests: XCTestCase {
    var suiteName = ""
    var defaults: UserDefaults!
    var settings: Lookout.Settings!
    var state: AppState!
    var home: LookoutHome!
    var temporary: URL?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        suiteName = "io.github.lukenorgaard.beacon.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = Lookout.Settings(defaults: defaults)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-codex-question-\(UUID().uuidString)")
        temporary = root
        home = LookoutHome(root: root)
        state = AppState(
            settings: settings,
            store: SessionStore(home: root),
            usage: UsageClient(),
            home: home
        )
        // `Notifier.notify` crashes the whole test binary outside a real app bundle — every test
        // here goes through the card (`state.attention`) instead, the same reasoning
        // `AppStateHoldTests`/`StaleBackgroundTests` already use.
        settings.notifyNeedsYou = false
        settings.notifyDone = false
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        temporary = nil
        state = nil
        settings = nil
        defaults = nil
        home = nil
        super.tearDown()
    }

    func question(callID: String = "call_1", text: String = "Which plan?") -> CodexQuestion {
        CodexQuestion(
            callID: callID,
            questions: [.init(id: "q", header: nil, question: text, options: ["A", "B"])],
            askedAt: Date()
        )
    }


    // MARK: - Building rollout lines

    /// One `response_item` line for a `request_user_input` call. `questions` is `(header, id,
    /// question, options)` tuples — building the JSON by hand (rather than round-tripping through
    /// `Encodable`) keeps every test's fixture readable at the call site.
    func questionCallLine(
        callID: String, timestamp: String? = "2026-09-04T08:00:00.000Z",
        questions: [(header: String?, id: String, question: String, options: [String]?)]
    ) -> String {
        let questionObjects = questions.map { q -> String in
            let header = q.header.map { "\"header\":\"\($0)\"," } ?? ""
            let options = q.options.map { list in
                "\"options\":[\(list.map { "{\"label\":\"\($0)\"}" }.joined(separator: ","))],"
            } ?? ""
            return "{\(header)\"id\":\"\(q.id)\",\(options)\"question\":\"\(q.question)\"}"
        }
        let arguments = "{\"questions\":[\(questionObjects.joined(separator: ","))]}"
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let ts = timestamp.map { "\"timestamp\":\"\($0)\"," } ?? ""
        return """
        {\(ts)"type":"response_item","payload":{"type":"function_call","id":"fc_x",\
        "name":"request_user_input","call_id":"\(callID)","arguments":"\(arguments)"}}
        """
    }

    private func outputLine(callID: String) -> String {
        """
        {"timestamp":"2026-09-04T08:05:00.000Z","type":"response_item",\
        "payload":{"type":"function_call_output","id":"fco_x","call_id":"\(callID)","output":"{}"}}
        """
    }

    private func unrelatedCallLine(callID: String = "call_other") -> String {
        """
        {"timestamp":"2026-09-04T08:03:00.000Z","type":"response_item",\
        "payload":{"type":"function_call","id":"fc_other","name":"shell","call_id":"\(callID)",\
        "arguments":"{\\"command\\":[\\"ls\\"]}"}}
        """
    }

    func tail(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    // MARK: - CodexQuestion.parse (pure)

    func testAnOpenQuestionWithOptionsIsParsed() {
        let data = tail([
            questionCallLine(
                callID: "call_1",
                questions: [(nil, "scope", "What should this cover?", ["A", "B"])]
            ),
        ])
        let question = CodexQuestion.parse(tailData: data)
        XCTAssertEqual(question?.callID, "call_1")
        XCTAssertEqual(question?.questions.count, 1)
        XCTAssertEqual(question?.questions.first?.question, "What should this cover?")
        XCTAssertEqual(question?.questions.first?.options, ["A", "B"])
        XCTAssertEqual(question?.askedAt, ISO8601.date("2026-09-04T08:00:00.000Z"))
    }

    func testAnAnsweredQuestionReturnsNil() {
        let data = tail([
            questionCallLine(callID: "call_1", questions: [(nil, "q", "Which one?", ["A", "B"])]),
            outputLine(callID: "call_1"),
        ])
        XCTAssertNil(CodexQuestion.parse(tailData: data))
    }

    func testSeveralQuestionsInOneCallAreAllParsed() {
        let data = tail([
            questionCallLine(callID: "call_1", questions: [
                (header: "Scope", id: "a", question: "What should this cover?", options: ["A", "B"]),
                (header: "Timing", id: "b", question: "When should it run?", options: ["Now", "Later"]),
            ]),
        ])
        let question = CodexQuestion.parse(tailData: data)
        XCTAssertEqual(question?.questions.count, 2)
        XCTAssertEqual(question?.questions[0].header, "Scope")
        XCTAssertEqual(question?.questions[0].question, "What should this cover?")
        XCTAssertEqual(question?.questions[1].header, "Timing")
        XCTAssertEqual(question?.questions[1].options, ["Now", "Later"])
        XCTAssertEqual(question?.firstQuestionText, "What should this cover?")
    }

    func testAFreeTextQuestionHasNoOptions() {
        // No `options` key at all — the shape a free-text question actually has on the wire.
        let data = tail([
            questionCallLine(callID: "call_1", questions: [(nil, "q", "Anything else?", nil)]),
        ])
        let question = CodexQuestion.parse(tailData: data)
        XCTAssertEqual(question?.questions.first?.options, [])
    }

    func testATruncatedLastLineIsSkippedNotCrashed() {
        let valid = questionCallLine(
            callID: "call_1", questions: [(nil, "q", "Which one?", ["A", "B"])]
        )
        let data = tail([valid]) + Data("\n".utf8) + Data(
            #"{"timestamp":"2026-09-04T08:01:00.000Z","type":"response_item","payload":{"#
                .utf8
        )
        let question = CodexQuestion.parse(tailData: data)
        XCTAssertEqual(question?.callID, "call_1", "the earlier, complete line still parses")
    }

    /// The real `tailReader` seeks to `size - maxBytes` and reads to the end, which lands mid-line
    /// as often as not — the parser must drop that leading fragment silently, not choke on it.
    func testA256KBTailCutMidLineDropsThePartialFirstLine() {
        let priorLine = questionCallLine(
            callID: "call_stale", questions: [(nil, "q", "An earlier question", ["A"])]
        )
        let openLine = questionCallLine(
            callID: "call_open", questions: [(nil, "q", "The real open question", ["A", "B"])]
        )
        let fullTail = priorLine + "\n" + openLine
        // Cut five bytes into the first line — exactly what a byte-offset seek into the real
        // file would do.
        let cutIndex = fullTail.index(fullTail.startIndex, offsetBy: 5)
        let simulated = String(fullTail[cutIndex...])

        let question = CodexQuestion.parse(tailData: Data(simulated.utf8))
        XCTAssertEqual(question?.callID, "call_open")
        XCTAssertEqual(question?.questions.first?.question, "The real open question")
    }

    func testAnUnrelatedNewerFunctionCallDoesNotHideAnOpenQuestion() {
        let data = tail([
            questionCallLine(callID: "call_1", questions: [(nil, "q", "Which one?", ["A", "B"])]),
            unrelatedCallLine(),
        ])
        let question = CodexQuestion.parse(tailData: data)
        XCTAssertEqual(question?.callID, "call_1", "only a request_user_input call ever counts")
    }

    func testTheNewestRequestUserInputCallWinsOverAnOlderOne() {
        let data = tail([
            questionCallLine(callID: "call_old", questions: [(nil, "q", "Old question", ["A"])]),
            questionCallLine(callID: "call_new", questions: [(nil, "q", "New question", ["B"])]),
        ])
        let question = CodexQuestion.parse(tailData: data)
        XCTAssertEqual(question?.callID, "call_new")
        XCTAssertEqual(question?.questions.first?.question, "New question")
    }

    func testTheNewestCallWinsEvenWhenAnOlderOneWasAlreadyAnswered() {
        let data = tail([
            questionCallLine(callID: "call_old", questions: [(nil, "q", "Old question", ["A"])]),
            outputLine(callID: "call_old"),
            questionCallLine(callID: "call_new", questions: [(nil, "q", "New question", ["B"])]),
        ])
        let question = CodexQuestion.parse(tailData: data)
        XCTAssertEqual(question?.callID, "call_new")
    }

    func testEmptyTailDataIsNil() {
        XCTAssertNil(CodexQuestion.parse(tailData: Data()))
    }

    // MARK: - Reading the real fixture end to end

    /// End to end through the *real* `stat`/tail-read pair (`CodexQuestionWatcher.defaultStatter`/
    /// `.defaultTailReader`), not just the parser alone — the same pipeline
    /// `CodexQuestionWatcher`'s own timer runs, against a real file on disk.
    func testTheFixtureRolloutParsesAsAnOpenTwoQuestionCall() throws {
        let candidate = CodexQuestionCandidate(
            sessionID: "s1", transcriptPath: Fixtures.codexRolloutQuestion.path,
            isNeedsYouByHook: false
        )
        let result = CodexQuestionCheck.run(
            candidates: [candidate], cache: [:],
            statter: CodexQuestionWatcher.defaultStatter,
            tailReader: CodexQuestionWatcher.defaultTailReader
        )

        let question = try XCTUnwrap(result.questions["s1"])
        XCTAssertEqual(question.callID, "call_open_001")
        XCTAssertEqual(question.questions.count, 2)
        XCTAssertEqual(question.questions[0].question, "What should the migration plan cover?")
        XCTAssertEqual(question.questions[0].options, ["Schema only", "Schema and data"])
        XCTAssertEqual(question.questions[1].question, "When should the migration run?")
        XCTAssertEqual(question.questions[1].options, [])

        // The cache now holds a real stat — a second look at the same, untouched file must skip
        // the tail read entirely (the same "inject a clock/file stat" rule, this time for real).
        var tailReads = 0
        let real = CodexQuestionCheck.run(
            candidates: [candidate], cache: result.cache,
            statter: CodexQuestionWatcher.defaultStatter,
            tailReader: { path, bytes in
                tailReads += 1
                return CodexQuestionWatcher.defaultTailReader(path, bytes)
            }
        )
        XCTAssertEqual(tailReads, 0, "an unchanged real file is never re-read")
        XCTAssertEqual(real.questions["s1"], question)
    }

    // MARK: - attentionRequest(session:)

    func testAttentionRequestCarriesTheFirstQuestionAndTheFullList() {
        let question = CodexQuestion(
            callID: "call_1",
            questions: [
                .init(id: "a", header: nil, question: "First?", options: ["X", "Y"]),
                .init(id: "b", header: nil, question: "Second?", options: []),
            ],
            askedAt: Date()
        )
        var session = Session()
        session.sessionID = "s1"
        session.agent = .codex
        session.cwd = "/tmp/acme"

        let request = question.attentionRequest(session: session)
        XCTAssertEqual(request.kind, .question)
        XCTAssertTrue(request.isCodexQuestion)
        XCTAssertEqual(request.question, "First?")
        XCTAssertEqual(request.options, ["X", "Y"])
        XCTAssertEqual(request.codexQuestions.count, 2)
        XCTAssertEqual(request.requestID, "call_1")
        XCTAssertEqual(request.sessionID, "s1")
        XCTAssertEqual(request.cwd, "/tmp/acme")
    }

    // MARK: - CodexQuestionDecoration (pure, AppState.apply()'s own rule)

    func codexSession(
        id: String = "s1", state: SessionState = .working, reason: String? = nil
    ) -> Session {
        var value = Session()
        value.sessionID = id
        value.project = id
        value.agent = .codex
        value.state = state
        value.reason = reason
        value.updatedAt = Date()
        return value
    }

    func testDecorateTurnsAWorkingCodexSessionIntoNeedsYouQuestion() {
        let question = CodexQuestion(
            callID: "call_1",
            questions: [.init(id: "q", header: nil, question: "Which plan?", options: ["A", "B"])],
            askedAt: nil
        )
        let decorated = CodexQuestionDecoration.decorate(
            codexSession(), questions: ["s1": question]
        )
        XCTAssertEqual(decorated.state, .needsYou)
        XCTAssertEqual(decorated.reason, "question")
        XCTAssertEqual(decorated.detail, "Which plan?")
        XCTAssertEqual(decorated.statusLabel, "Question for you")
    }

    func testDecorateShowsOnlyTheFirstQuestionWhenThereAreSeveral() {
        let question = CodexQuestion(
            callID: "call_1",
            questions: [
                .init(id: "a", header: nil, question: "First question?", options: []),
                .init(id: "b", header: nil, question: "Second question?", options: []),
            ],
            askedAt: nil
        )
        let decorated = CodexQuestionDecoration.decorate(
            codexSession(), questions: ["s1": question]
        )
        XCTAssertEqual(decorated.detail, "First question?")
    }

    func testDecorateTruncatesALongQuestion() {
        let long = String(repeating: "a", count: 200)
        let question = CodexQuestion(
            callID: "call_1",
            questions: [.init(id: "q", header: nil, question: long, options: [])],
            askedAt: nil
        )
        let decorated = CodexQuestionDecoration.decorate(
            codexSession(), questions: ["s1": question]
        )
        // `Session.truncate` appends the ellipsis after the cut (SPEC: it counts as part of the
        // result, not the limit) — the same contract every other truncated field on `Session`
        // already has, so this is `detailLimit + 1`, not `detailLimit`.
        XCTAssertLessThanOrEqual(
            decorated.detail?.count ?? 0, CodexQuestionDecoration.detailLimit + 1
        )
        XCTAssertTrue(decorated.detail?.hasSuffix("…") ?? false)
    }

    func testDecorateLeavesTheSessionAloneWithoutAMatchingQuestion() {
        let session = codexSession()
        XCTAssertEqual(CodexQuestionDecoration.decorate(session, questions: [:]), session)
        XCTAssertEqual(
            CodexQuestionDecoration.decorate(session, questions: ["other": .init(
                callID: "x", questions: [.init(id: "q", header: nil, question: "?", options: [])],
                askedAt: nil
            )]),
            session
        )
    }

    func testDecorateNeverTouchesANonCodexSession() {
        var session = codexSession()
        session.agent = .claude
        let question = CodexQuestion(
            callID: "call_1",
            questions: [.init(id: "q", header: nil, question: "Which plan?", options: [])],
            askedAt: nil
        )
        XCTAssertEqual(
            CodexQuestionDecoration.decorate(session, questions: ["s1": question]), session
        )
    }

    /// A real, hook-driven `needs_you` always wins — a permission already on screen must never
    /// be replaced by the question decoration, whatever `reason` it already carries.
    func testDecorateNeverOverridesAHookDrivenNeedsYou() {
        let permission = codexSession(state: .needsYou, reason: "permission")
        let question = CodexQuestion(
            callID: "call_1",
            questions: [.init(id: "q", header: nil, question: "Which plan?", options: [])],
            askedAt: nil
        )
        XCTAssertEqual(
            CodexQuestionDecoration.decorate(permission, questions: ["s1": question]), permission
        )
    }
}
