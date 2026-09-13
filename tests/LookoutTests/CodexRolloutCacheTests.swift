import XCTest
@testable import Lookout

final class CodexRolloutCacheTests: XCTestCase {
    private var bytes = Data()
    private var modified = Date(timeIntervalSince1970: 1_800_000_000)
    private var headReads = 0
    private var tailReads = 0
    private let cache = CodexRolloutCache()

    private func line(_ type: String, _ payload: [String: Any]) -> Data {
        var data = try! JSONSerialization.data(withJSONObject: [
            "timestamp": ISO8601.string(modified), "type": type, "payload": payload,
        ])
        data.append(10)
        return data
    }

    private func start(_ id: String = "test-thread", model: String? = "gpt-6-astra") {
        bytes = line("session_meta", ["id": id, "cwd": "/fictional/voyager", "originator": "Codex Desktop"])
        if let model { bytes.append(line("turn_context", ["model": model])) }
    }

    private func prompt(_ text: String) {
        bytes.append(line("event_msg", ["type": "user_message", "message": text]))
    }

    private func output(_ count: Int) {
        bytes.append(line("response_item", [
            "type": "function_call_output", "call_id": "fixture-call", "output": String(repeating: "x", count: count),
        ]))
        bytes.append(line("event_msg", ["type": "task_started"]))
    }

    private var io: CodexRolloutDiscovery.IO {
        CodexRolloutDiscovery.IO(
            list: { _ in [.init(path: "/fixture.jsonl", modifiedAt: self.modified, size: self.bytes.count)] },
            head: { _, limit in
                self.headReads += 1
                return Data(self.bytes.prefix(limit))
            },
            tail: { _, limit in
                self.tailReads += 1
                XCTAssertLessThanOrEqual(limit, CodexRolloutCache.contextBytes)
                return Data(self.bytes.suffix(limit))
            }
        )
    }

    private func row() throws -> Session {
        try XCTUnwrap(CodexRolloutDiscovery.discover(now: modified, io: io, cache: cache).sessions.first)
    }

    func testLongToolOutputDoesNotErasePreviouslySeenNameOrModel() throws {
        start()
        prompt("Fix the checkout flow")
        let before = try row()
        output(CodexRolloutCache.contextBytes + 1024)
        modified.addTimeInterval(1)
        let after = try row()
        XCTAssertEqual(after.title, before.title)
        XCTAssertEqual(after.model, before.model)
        XCTAssertEqual(after.title, "Fix the checkout flow")
        XCTAssertEqual(after.state, .working)
    }

    func testColdStartLooksBeyondTheShortTailForContext() throws {
        start()
        prompt("Fix the checkout flow")
        output(CodexRolloutDiscovery.tailBytes + 1024)
        let session = try row()
        XCTAssertEqual(session.title, "Fix the checkout flow")
        XCTAssertEqual(session.model, "gpt-6-astra")
    }

    func testAChangedPromptAndModelReplaceCachedMetadata() throws {
        start()
        prompt("First task")
        _ = try row()
        bytes.append(line("turn_context", ["model": "gpt-5.6-sol"]))
        prompt("Second task")
        modified.addTimeInterval(1)
        let session = try row()
        XCTAssertEqual(session.title, "Second task")
        XCTAssertEqual(session.model, "gpt-5.6-sol")
    }

    func testAnUnchangedFileIsNotReadAgainButItsStateStillSettles() throws {
        start()
        bytes.append(line("event_msg", ["type": "task_complete"]))
        XCTAssertEqual(try row().state, .working)
        let reads = (headReads, tailReads)
        let settled = CodexRolloutDiscovery.discover(
            now: modified.addingTimeInterval(25), io: io, cache: cache
        )
        XCTAssertEqual(settled.sessions.first?.state, .done)
        XCTAssertEqual(headReads, reads.0)
        XCTAssertEqual(tailReads, reads.1)
    }

    func testTruncationDoesNotLeakOldMetadataIntoANewSession() throws {
        start()
        prompt("Original task")
        _ = try row()
        start("replacement", model: nil)
        modified.addTimeInterval(1)
        let session = try row()
        XCTAssertEqual(session.sessionID, "replacement")
        XCTAssertNil(session.title)
        XCTAssertNil(session.model)
    }

    func testExpiredFilesAreEvictedFromTheCache() throws {
        start()
        _ = try row()
        let reads = headReads
        cache.retain(paths: [])
        _ = try row()
        XCTAssertGreaterThan(headReads, reads)
    }

    func testTransientTailFailureKeepsKnownMetadataAndRetriesTheNextRead() throws {
        start()
        prompt("Original task")
        _ = try row()
        prompt("Updated task")
        modified.addTimeInterval(1)
        var failing = io
        failing.tail = { _, _ in nil }
        let retained = CodexRolloutDiscovery.discover(now: modified, io: failing, cache: cache)
        XCTAssertEqual(retained.sessions.first?.title, "Original task")
        XCTAssertEqual(try row().title, "Updated task")
    }
}
