import XCTest
@testable import Lookout

/// SPEC §11.2: the heuristic's exact wording, and the two Ollama JSON shapes.
final class SuggesterTests: XCTestCase {
    // MARK: - Heuristic

    func testTheHeuristicSaysWhatTheSpecSaysItSays() {
        var permission = SuggestionContext(kind: .permission)
        permission.toolName = "Bash"
        permission.command = "rm -rf build"
        XCTAssertEqual(Heuristic.suggestion(for: permission), "Allow — runs `rm -rf build`")

        // No command: the tool name is all there is.
        permission.command = nil
        XCTAssertEqual(Heuristic.suggestion(for: permission), "Allow — runs Bash")
        permission.toolName = nil
        XCTAssertEqual(Heuristic.suggestion(for: permission), "Allow")

        var question = SuggestionContext(kind: .question)
        question.options = ["Run 004 first", "Run 005 first"]
        XCTAssertEqual(Heuristic.suggestion(for: question), "Run 004 first")
        question.options = []
        XCTAssertEqual(Heuristic.suggestion(for: question), "Yes, go ahead")

        XCTAssertEqual(
            Heuristic.suggestion(for: SuggestionContext(kind: .done)),
            "Continue with the next step"
        )
    }

    func testALongCommandIsCutSoTheSuggestionStaysOneLine() {
        var permission = SuggestionContext(kind: .permission)
        permission.command = String(repeating: "a", count: 400)
        let suggestion = Heuristic.suggestion(for: permission)
        XCTAssertLessThan(suggestion.count, 120)
        XCTAssertTrue(suggestion.hasSuffix("…`"))
    }

    // MARK: - The context the card builds

    func testTheContextComesFromTheRequestFirstAndTheSessionSecond() throws {
        var session = Session()
        session.sessionID = "s1"
        session.project = "daily-notes"
        session.state = .needsYou
        session.detail = "Bash: rm -rf build"

        // No request file yet: the state file alone still names the tool and the argument.
        let fromSession = SuggestionContext(session: session, request: nil)
        XCTAssertEqual(fromSession.kind, .permission)
        XCTAssertEqual(fromSession.toolName, "Bash")
        XCTAssertEqual(fromSession.command, "rm -rf build")

        let request = try XCTUnwrap(AttentionRequest.decode(Data("""
        {"session_id":"s1","kind":"question","question":"Which migration?",
         "options":["004","005"]}
        """.utf8), name: "claude-s1-r1"))
        let fromRequest = SuggestionContext(session: session, request: request)
        XCTAssertEqual(fromRequest.kind, .question)
        XCTAssertEqual(fromRequest.question, "Which migration?")
        XCTAssertEqual(fromRequest.options, ["004", "005"])

        // A finished session asks nothing; the card offers the next instruction.
        session.state = .done
        session.lastMessage = "All green."
        let done = SuggestionContext(session: session, request: nil)
        XCTAssertEqual(done.kind, .done)
        XCTAssertTrue(done.promptText.contains("All green."))
        XCTAssertTrue(done.promptText.contains("daily-notes"))
    }

    // MARK: - Ollama

    func testTagsAreParsedAndTheSmallestQwenWins() {
        let data = Data("""
        {"models":[
          {"name":"llama3.3:70b","details":{"parameter_size":"70.6B"}},
          {"name":"qwen3.5:14b","details":{"parameter_size":"14.8B"}},
          {"name":"qwen3.5:4b","details":{"parameter_size":"4.0B"}},
          {"name":"nomic-embed-text:latest"}
        ]}
        """.utf8)
        let models = Ollama.parseTags(data)
        XCTAssertEqual(models.map(\.name), [
            "llama3.3:70b", "qwen3.5:14b", "qwen3.5:4b", "nomic-embed-text:latest",
        ])
        XCTAssertEqual(models[2].parameterSize, "4.0B")
        XCTAssertEqual(Ollama.defaultModel(models), "qwen3.5:4b")

        // No qwen3.5 at all: the smallest model of any family.
        let others = models.filter { !$0.name.hasPrefix("qwen3.5") }
        XCTAssertEqual(Ollama.defaultModel(others), "llama3.3:70b")
        XCTAssertNil(Ollama.defaultModel([]))
        XCTAssertTrue(Ollama.parseTags(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(Ollama.parseTags(Data("{}".utf8)).isEmpty)
    }

    func testASizeIsReadFromTheTagWhenTheDetailsAreMissing() {
        let models = Ollama.parseTags(Data("""
        {"models":[{"name":"qwen3.5:7b"},{"name":"qwen3.5:1.5b"},{"name":"qwen3.5:600m"}]}
        """.utf8))
        XCTAssertEqual(Ollama.defaultModel(models), "qwen3.5:600m")
        XCTAssertEqual(OllamaModel.billions("4.0B"), 4)
        XCTAssertEqual(OllamaModel.billions("600m"), 0.6)
        XCTAssertNil(OllamaModel.billions("latest"))
        XCTAssertNil(OllamaModel.billions(nil))
    }

    func testTheChatResponseIsParsedAndCleaned() {
        XCTAssertEqual(
            Ollama.parseChat(Data(#"{"message":{"role":"assistant","content":"  Allow it.\n"}}"#.utf8)),
            "Allow it."
        )
        // A reasoning model's thinking is not part of the answer.
        XCTAssertEqual(
            Ollama.parseChat(Data("""
            {"message":{"content":"<think>the user wants…</think>\\nYes, run it."}}
            """.utf8)),
            "Yes, run it."
        )
        // A model that quotes itself.
        XCTAssertEqual(
            Ollama.parseChat(Data(#"{"message":{"content":"\"Go ahead\""}}"#.utf8)),
            "Go ahead"
        )
        // `/api/generate`'s shape works too.
        XCTAssertEqual(Ollama.parseChat(Data(#"{"response":"Sure"}"#.utf8)), "Sure")
        XCTAssertNil(Ollama.parseChat(Data("not json".utf8)))
        XCTAssertNil(Ollama.parseChat(Data(#"{"error":"model not found"}"#.utf8)))
    }

    func testAnOverlongAnswerIsCutToThreeHundredCharacters() {
        let long = String(repeating: "a", count: 900)
        let cleaned = Ollama.clean(long)
        XCTAssertEqual(cleaned.count, Ollama.maxLength)
        XCTAssertEqual(Ollama.maxLength, 300)
    }

    func testTheRequestsAreShapedTheWayTheSpecDescribes() throws {
        let tags = Ollama.tagsRequest()
        XCTAssertEqual(tags.httpMethod, "GET")
        XCTAssertEqual(tags.url?.absoluteString, "http://localhost:11434/api/tags")
        XCTAssertEqual(tags.timeoutInterval, 8)

        var context = SuggestionContext(kind: .permission)
        context.toolName = "Bash"
        context.command = "rm -rf build"
        let chat = try XCTUnwrap(Ollama.chatRequest(model: "qwen3.5:4b", context: context))
        XCTAssertEqual(chat.httpMethod, "POST")
        XCTAssertEqual(chat.url?.absoluteString, "http://localhost:11434/api/chat")
        XCTAssertEqual(chat.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(chat.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(body["model"] as? String, "qwen3.5:4b")
        XCTAssertEqual(body["stream"] as? Bool, false)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"], "system")
        XCTAssertEqual(
            messages[0]["content"],
            "You are helping a developer answer a coding agent's request. "
                + "Reply with only the one-line answer the developer should send."
        )
        XCTAssertEqual(messages[1]["role"], "user")
        XCTAssertTrue(messages[1]["content"]?.contains("rm -rf build") ?? false)
    }

    /// `.off` yields nothing at all; `.heuristic` answers without touching the network.
    func testTheSuggesterHonoursItsSource() {
        let suggester = Suggester()
        var context = SuggestionContext(kind: .permission)
        context.command = "npm test"

        var off = SuggestionOutcome(text: "unset", source: .heuristic, note: nil)
        suggester.suggest(for: context, source: .off, model: nil) { off = $0 }
        XCTAssertNil(off.text)
        XCTAssertEqual(off.source, .off)

        var heuristic: SuggestionOutcome?
        suggester.suggest(for: context, source: .heuristic, model: nil) { heuristic = $0 }
        XCTAssertEqual(heuristic?.text, "Allow — runs `npm test`")
        XCTAssertEqual(heuristic?.source, .heuristic)
        XCTAssertNil(heuristic?.note)
    }
}
