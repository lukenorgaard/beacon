import XCTest
@testable import Lookout

/// SPEC §11.3: the request/answer contract between the reporter and the card.
final class AttentionRequestTests: XCTestCase {
    private var temporary: URL?

    override func tearDown() {
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        temporary = nil
        super.tearDown()
    }

    private func makeHome() throws -> LookoutHome {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-answers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporary = url
        return LookoutHome(root: url)
    }

    private func decode(_ json: String, name: String = "claude-s1-abcd1234") throws -> AttentionRequest {
        try XCTUnwrap(AttentionRequest.decode(Data(json.utf8), name: name))
    }

    // MARK: - Decoding

    func testDecodesAPermissionRequest() throws {
        let request = try decode("""
        {
          "schema": 1, "agent": "claude", "session_id": "s1", "request_id": "abcd1234",
          "kind": "permission", "tool_name": "Bash", "summary": "rm -rf build",
          "command_or_path": "rm -rf build && npm run build",
          "cwd": "/Users/you/Desktop/x",
          "created_at": "2026-09-02T04:50:00Z", "waits_until": "2026-09-02T04:50:45Z"
        }
        """)
        XCTAssertEqual(request.kind, .permission)
        XCTAssertEqual(request.agent, .claude)
        XCTAssertEqual(request.toolName, "Bash")
        XCTAssertEqual(request.commandText, "rm -rf build && npm run build")
        XCTAssertEqual(request.headline, "Bash · rm -rf build")
        XCTAssertEqual(request.name, "claude-s1-abcd1234")
        XCTAssertEqual(request.id, "claude-s1-abcd1234")
        XCTAssertEqual(request.waitsUntil, ISO8601.date("2026-09-02T04:50:45Z"))
    }

    func testDecodesAQuestionWithEitherShapeOfOptions() throws {
        let plain = try decode("""
        {"session_id":"s1","kind":"question","question":"Which one?",
         "options":["First","Second","  "]}
        """)
        XCTAssertEqual(plain.kind, .question)
        XCTAssertEqual(plain.options, ["First", "Second"])
        XCTAssertEqual(plain.headline, "Which one?")

        // An AskUserQuestion payload hands its options over as objects.
        let objects = try decode("""
        {"session_id":"s1","kind":"question","summary":"Pick",
         "options":[{"label":"First","description":"…"},{"label":"Second"}]}
        """)
        XCTAssertEqual(objects.options, ["First", "Second"])
        XCTAssertEqual(objects.headline, "Pick")
    }

    func testDecodingIsTolerantAndNeverThrowsOnRubbish() throws {
        let bare = try decode(#"{"session_id":"s1"}"#)
        XCTAssertEqual(bare.kind, .permission, "a missing kind is a permission request")
        XCTAssertTrue(bare.options.isEmpty)
        XCTAssertNil(bare.waitsUntil)
        XCTAssertNil(bare.commandText)
        XCTAssertEqual(bare.headline, "Permission")

        let odd = try decode("""
        {"session_id":"s1","kind":"nonsense","options":"three","waits_until":"never",
         "tool_name":null,"schema":"one"}
        """)
        XCTAssertEqual(odd.kind, .permission)
        XCTAssertTrue(odd.options.isEmpty)
        XCTAssertNil(odd.waitsUntil)
        XCTAssertEqual(odd.schema, 1)

        // No `session_id` at all is the one thing that is not a request.
        XCTAssertNil(AttentionRequest.decode(Data(#"{"kind":"permission"}"#.utf8), name: "x"))
        XCTAssertNil(AttentionRequest.decode(Data("not json".utf8), name: "x"))
    }

    func testRoundTripsThroughAnEncode() throws {
        let original = try decode("""
        {"session_id":"s1","request_id":"r1","kind":"question","question":"Q",
         "options":["a","b"],"cwd":"/tmp","created_at":"2026-09-02T04:50:00Z"}
        """)
        var again = try XCTUnwrap(
            AttentionRequest.decode(try JSONEncoder().encode(original), name: original.name)
        )
        again.name = original.name
        XCTAssertEqual(original, again)
    }

    // MARK: - Expiry (SPEC §11.4)

    func testExpiryDecidesWhetherAllowAndDenyExist() throws {
        let now = ISO8601.date("2026-09-02T04:50:30Z")!
        var request = try decode("""
        {"session_id":"s1","kind":"permission","waits_until":"2026-09-02T04:50:45Z"}
        """)
        XCTAssertFalse(request.isExpired(now: now))
        XCTAssertTrue(request.isAnswerable(now: now))
        XCTAssertEqual(request.secondsLeft(now: now), 15)

        // One second past the deadline the terminal has taken the prompt back.
        let after = ISO8601.date("2026-09-02T04:50:46Z")!
        XCTAssertTrue(request.isExpired(now: after))
        XCTAssertFalse(request.isAnswerable(now: after))
        XCTAssertEqual(request.secondsLeft(now: after), 0)

        // `wait_seconds: 0` means the reporter never waited at all.
        request.waitsUntil = ISO8601.date("2026-09-02T04:50:30Z")
        XCTAssertTrue(request.isExpired(now: now), "the boundary counts as expired")

        // A question never waits, so it can never expire — but it is never file-answerable.
        let question = try decode(#"{"session_id":"s1","kind":"question"}"#)
        XCTAssertFalse(question.isExpired(now: now))
        XCTAssertFalse(question.isAnswerable(now: now))
    }

    // MARK: - The answer file (SPEC §11.3)

    func testAnswerRoundTripsThroughTheFileTheReporterPollsFor() throws {
        let home = try makeHome()
        let request = try decode(
            #"{"session_id":"s1","request_id":"abcd1234","kind":"permission"}"#,
            name: "claude-s1-abcd1234"
        )
        let when = ISO8601.date("2026-09-02T04:50:31Z")!
        let url = try AnswerWriter.write(.allow, for: request, in: home.answers, at: when)

        // Same name as the request, under `answers/` (SPEC §11.3).
        XCTAssertEqual(url.lastPathComponent, "claude-s1-abcd1234.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "answers")

        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(raw["decision"] as? String, "allow")
        XCTAssertEqual(raw["answered_at"] as? String, "2026-09-02T04:50:31Z")
        XCTAssertEqual(raw.keys.count, 2, "the reporter reads exactly these two keys")

        let read = try XCTUnwrap(AnswerWriter.read(url))
        XCTAssertEqual(read.decision, .allow)
        XCTAssertEqual(read.answeredAt, when)

        // A second answer replaces the first rather than failing.
        _ = try AnswerWriter.write(.deny, for: request, in: home.answers, at: when)
        XCTAssertEqual(AnswerWriter.read(url)?.decision, .deny)

        // Nothing is left behind by the atomic write.
        let left = try FileManager.default.contentsOfDirectory(atPath: home.answers.path)
        XCTAssertEqual(left, ["claude-s1-abcd1234.json"])
    }

    func testAnAnswerWithNoFileNameIsRefused() throws {
        let home = try makeHome()
        var request = try decode(#"{"session_id":"s1"}"#)
        request.name = ""
        XCTAssertThrowsError(try AnswerWriter.write(.allow, for: request, in: home.answers)) {
            XCTAssertEqual($0 as? AnswerWriter.WriteError, .noName)
        }
    }

    // MARK: - answers.log (SPEC §11.4)

    func testTheAuditLineCarriesTheFactsAndOnlySixtyCharacters() throws {
        var session = Session()
        session.sessionID = "s1"
        session.project = "daily-notes"
        let long = String(repeating: "x", count: 200)

        let line = AnswerAudit.line(
            session: session, channel: .message, outcome: "sent", text: "one\ntwo"
        )
        XCTAssertEqual(line, "daily-notes/s1 · message · sent · \"one two\"")

        let capped = AnswerAudit.line(
            session: session, channel: .clipboard, outcome: "copied", text: long
        )
        XCTAssertTrue(capped.contains("\"\(String(repeating: "x", count: 60))\""))
        XCTAssertFalse(capped.contains(String(repeating: "x", count: 61)))

        // Written to `answers.log`, one line, with a timestamp in front.
        let home = try makeHome()
        LogFile.appendNow(line, to: home.answersLog)
        LogFile.appendNow(capped, to: home.answersLog)
        let contents = try String(contentsOf: home.answersLog, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix(line))
        XCTAssertNotNil(ISO8601.date(String(lines[0].prefix(20))))
    }

    // MARK: - config.json (SPEC §11.4)

    func testWaitSecondsIsMergedIntoWhateverElseIsInTheConfig() throws {
        let home = try makeHome()
        let url = home.config
        try Data(#"{"other_key":"kept","wait_seconds":10,"nested":{"a":1}}"#.utf8).write(to: url)

        XCTAssertTrue(LookoutConfig.write(waitSeconds: 45, to: url))
        let merged = LookoutConfig.read(from: url)
        XCTAssertEqual(merged["wait_seconds"] as? Int, 45)
        XCTAssertEqual(merged["other_key"] as? String, "kept")
        XCTAssertNotNil(merged["nested"] as? [String: Any], "a key we know nothing about survives")
        XCTAssertEqual(LookoutConfig.waitSeconds(in: url), 45)
    }

    func testTheConfigIsCreatedWhenThereIsNoneAndClampedToTheRange() throws {
        let home = try makeHome()
        let url = home.root.appendingPathComponent("fresh/config.json")
        XCTAssertTrue(LookoutConfig.write(waitSeconds: 500, to: url))
        XCTAssertEqual(LookoutConfig.waitSeconds(in: url), 110)

        XCTAssertTrue(LookoutConfig.write(waitSeconds: -5, to: url))
        XCTAssertEqual(LookoutConfig.waitSeconds(in: url), 0, "0 = do not wait (SPEC §11.3)")

        XCTAssertEqual(LookoutConfig.defaultWaitSeconds, 45)
        XCTAssertEqual(LookoutConfig.clamp(45), 45)
    }

    func testAMalformedConfigIsReplacedRatherThanLeftBroken() throws {
        let home = try makeHome()
        try Data("{ not json".utf8).write(to: home.config)
        XCTAssertTrue(LookoutConfig.write(waitSeconds: 30, to: home.config))
        XCTAssertEqual(LookoutConfig.waitSeconds(in: home.config), 30)
    }

    // MARK: - The store (SPEC §11.3)

    func testTheStoreReadsTheCheckedInRequestFixtures() throws {
        let store = RequestStore(home: LookoutHome(root: Fixtures.home))
        store.start()

        let deadline = Date().addingTimeInterval(5)
        while store.requests.count < 2, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(store.requests.count, 2)

        let permission = try XCTUnwrap(
            store.request(for: "ab813983-4f21-4c0e-9a17-2f5b6c8d1e00")
        )
        XCTAssertEqual(permission.kind, .permission)
        XCTAssertEqual(permission.toolName, "Bash")
        XCTAssertFalse(permission.isExpired(), "the fixture must stay answerable")

        let question = try XCTUnwrap(
            store.request(for: "7c1f0a52-9d34-4b88-b0a1-3e9d7c22aa10")
        )
        XCTAssertEqual(question.kind, .question)
        XCTAssertEqual(question.options.count, 3)

        // Nothing in a fixtures folder is ever written to or deleted.
        let names = try FileManager.default
            .contentsOfDirectory(atPath: Fixtures.requestsDirectory.path)
            .filter { $0.hasSuffix(".json") }
        XCTAssertEqual(names.count, 2)
    }
}
