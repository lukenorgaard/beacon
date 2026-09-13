import XCTest
@testable import Lookout

/// Codex Desktop sessions have no process and, where hooks were never trusted,
/// the panel showed no Codex at all. The rollout file alone has to be enough for a row.
final class CodexRolloutDiscoveryTests: XCTestCase {

    private let now = ISO8601.date("2026-09-10T11:00:00Z")!

    private func line(_ timestamp: String, _ type: String, _ payload: [String: Any]) -> String {
        let object: [String: Any] = ["timestamp": timestamp, "type": type, "payload": payload]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func meta(
        id: String, cwd: String = "/Users/you/Desktop/voyager", originator: String = "Codex Desktop",
        threadSource: String = "user", parent: String? = nil, nickname: String? = nil
    ) -> String {
        var payload: [String: Any] = [
            "id": id, "session_id": id, "timestamp": "2026-09-10T10:00:00.743Z",
            "cwd": cwd, "originator": originator, "cli_version": "0.153.4",
            "thread_source": threadSource, "model_provider": "openai",
        ]
        if let parent {
            payload["source"] = ["subagent": ["thread_spawn": [
                "parent_thread_id": parent, "depth": 1, "agent_nickname": nickname ?? "Kuhn",
            ]]]
        } else {
            payload["source"] = "vscode"
        }
        return line("2026-09-10T10:00:00.750Z", "session_meta", payload)
    }

    private func body(lastKind: String, agentText: String = "Done — 3 files changed.") -> String {
        var lines = [
            line("2026-09-10T10:00:01Z", "turn_context", ["turn_id": "t1", "model": "gpt-6-astra"]),
            line("2026-09-10T10:00:02Z", "event_msg", ["type": "user_message", "message": "Fix the header layout on the product page please"]),
            line("2026-09-10T10:00:03Z", "event_msg", ["type": "token_count", "rate_limits": [
                "limit_name": NSNull(), "plan_type": "pro",
                "primary": ["used_percent": 1.0, "window_minutes": 10080, "resets_at": 1789512198],
                "secondary": NSNull(),
            ]]),
            line("2026-09-10T10:00:04Z", "response_item", ["type": "function_call", "name": "shell_command", "call_id": "c1", "arguments": "{}"]),
        ]
        if lastKind == "agent_message" {
            lines.append(line("2026-09-10T10:00:05Z", "response_item", [
                "type": "agent_message", "content": [["type": "output_text", "text": agentText]],
            ]))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func io(files: [(String, Date, String)]) -> CodexRolloutDiscovery.IO {
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.0, $0.2) })
        return CodexRolloutDiscovery.IO(
            list: { _ in files.map { .init(path: $0.0, modifiedAt: $0.1, size: $0.2.utf8.count) } },
            head: { path, _ in byPath[path].map { Data($0.utf8) } },
            tail: { path, _ in byPath[path].map { Data($0.utf8) } }
        )
    }

    // MARK: - Parsing

    func testTheFirstLineNamesTheSessionAndItsHost() {
        let parsed = CodexRolloutDiscovery.meta(head: Data(meta(id: "01a0874e").utf8))
        XCTAssertEqual(parsed?.id, "01a0874e")
        XCTAssertEqual(parsed?.cwd, "/Users/you/Desktop/voyager")
        XCTAssertEqual(parsed?.originator, "Codex Desktop")
        XCTAssertEqual(parsed?.isSubagent, false)
        XCTAssertEqual(parsed?.startedAt, ISO8601.date("2026-09-10T10:00:00.743Z"))
    }

    /// The parent id sits under `source.subagent.thread_spawn` in the files Codex 0.153 writes.
    func testASubagentKnowsItsParentAndNickname() {
        let parsed = CodexRolloutDiscovery.meta(head: Data(meta(id: "child", parent: "01a0874e", nickname: "Herschel").utf8))
        XCTAssertEqual(parsed?.isSubagent, true)
        XCTAssertEqual(parsed?.parentThreadID, "01a0874e")
        XCTAssertEqual(parsed?.agentNickname, "Herschel")
    }

    func testAnythingButSessionMetaIsNotAMeta() {
        XCTAssertNil(CodexRolloutDiscovery.meta(head: Data("not json\n".utf8)))
        XCTAssertNil(CodexRolloutDiscovery.meta(head: Data(line("2026-09-10T10:00:01Z", "turn_context", ["model": "x"]).utf8)))
        XCTAssertNil(CodexRolloutDiscovery.meta(head: Data()))
    }

    func testTheTailYieldsModelMessagesToolAndRateLimits() {
        let look = CodexRolloutDiscovery.look(tail: Data(body(lastKind: "agent_message").utf8))
        XCTAssertEqual(look.model, "gpt-6-astra")
        XCTAssertEqual(look.lastUserMessage, "Fix the header layout on the product page please")
        XCTAssertEqual(look.lastAgentMessage, "Done — 3 files changed.")
        XCTAssertEqual(look.lastToolName, "shell_command")
        XCTAssertEqual(look.lastKind, "agent_message")
        XCTAssertEqual(look.usage?.planType, "pro")
        XCTAssertEqual(look.usage?.primary?.usedPercent, 1.0)
        XCTAssertEqual(look.usage?.primary?.windowMinutes, 10080)
        XCTAssertNil(look.usage?.secondary)
    }

    /// A tail read from the middle of the file opens on half a line, and its last line may be
    /// mid-write. Neither is an error.
    func testAPartialFirstLineAndAnUnfinishedLastLineAreSkipped() {
        let clean = body(lastKind: "function_call")
        let mangled = "gs\":{}}}\n" + clean + "{\"timestamp\":\"2026-09-10T10:00:06Z\",\"type\":\"resp"
        let look = CodexRolloutDiscovery.look(tail: Data(mangled.utf8))
        XCTAssertEqual(look.lastToolName, "shell_command")
        XCTAssertEqual(look.lastKind, "function_call")
    }

    // MARK: - State

    func testAFreshlyWrittenRolloutIsWorkingAndNamesTheTool() {
        let look = CodexRolloutDiscovery.look(tail: Data(body(lastKind: "function_call").utf8))
        let rollout = CodexRolloutDiscovery.Rollout(path: "/r", modifiedAt: now.addingTimeInterval(-3), size: 1)
        let session = CodexRolloutDiscovery.session(
            meta: CodexRolloutDiscovery.meta(head: Data(meta(id: "s1").utf8))!, look: look, rollout: rollout, now: now
        )
        XCTAssertEqual(session.state, .working)
        XCTAssertEqual(session.detail, "shell_command")
        XCTAssertEqual(session.agent, .codex)
        XCTAssertEqual(session.host, .codexApp)
        XCTAssertEqual(session.project, "voyager")
        XCTAssertEqual(session.model, "gpt-6-astra")
        XCTAssertEqual(session.title, "Fix the header layout on the product page please")
        XCTAssertEqual(session.transcriptPath, "/r", "the question watcher keys on this")
        XCTAssertTrue(session.isDiscovered)
        XCTAssertNil(session.pid, "no process to check; liveness is the file's age")
    }

    /// The final agent message precedes the next tool call by milliseconds mid-turn, so it has
    /// to sit still for `settleWindow` before the row says done.
    func testAFinalAgentMessageBecomesDoneOnlyOnceItHasSettled() {
        let look = CodexRolloutDiscovery.look(tail: Data(body(lastKind: "agent_message").utf8))
        let fresh = CodexRolloutDiscovery.state(look: look, modifiedAt: now.addingTimeInterval(-5), now: now)
        let settled = CodexRolloutDiscovery.state(look: look, modifiedAt: now.addingTimeInterval(-25), now: now)
        XCTAssertEqual(fresh, .working)
        XCTAssertEqual(settled, .done)
    }

    func testAQuietRolloutIsIdleUntilItAgesOutEntirely() {
        let look = CodexRolloutDiscovery.look(tail: Data(body(lastKind: "function_call").utf8))
        XCTAssertEqual(CodexRolloutDiscovery.state(look: look, modifiedAt: now.addingTimeInterval(-600), now: now), .idle)
    }

    // MARK: - Discovery

    func testSubagentsFoldIntoTheirParentAndTheNewestLimitsWin() {
        let parent = meta(id: "P") + "\n" + body(lastKind: "function_call")
        let child = meta(id: "C1", parent: "P", nickname: "Avicenna") + "\n" + body(lastKind: "function_call")
        let found = CodexRolloutDiscovery.discover(now: now, io: io(files: [
            ("/p.jsonl", now.addingTimeInterval(-40), parent),
            ("/c1.jsonl", now.addingTimeInterval(-2), child),
        ]))
        XCTAssertEqual(found.sessions.count, 1, "the sub-agent is not a row of its own")
        XCTAssertEqual(found.sessions.first?.sessionID, "P")
        XCTAssertEqual(found.sessions.first?.subagents.map(\.type), ["Avicenna"])
        XCTAssertEqual(found.sessions.first?.subagents.first?.model, "gpt-6-astra")
        XCTAssertEqual(found.usage?.planType, "pro")
    }

    /// Codex writes a rollout for its own sub-agents and internal review passes too. Eleven of
    /// the fifteen live files on one measured machine were those, and every one had become a row.
    func testOnlyUserStartedThreadsBecomeRows() {
        let parent = meta(id: "P") + "\n" + body(lastKind: "function_call")
        let orphan = meta(id: "C1", parent: "gone", nickname: "Kuhn") + "\n" + body(lastKind: "function_call")
        let review = meta(id: "G1", threadSource: "guardian_review") + "\n" + body(lastKind: "function_call")
        let found = CodexRolloutDiscovery.discover(now: now, io: io(files: [
            ("/p.jsonl", now, parent), ("/c1.jsonl", now, orphan), ("/g1.jsonl", now, review),
        ]))
        XCTAssertEqual(found.sessions.map(\.sessionID), ["P"])
        XCTAssertTrue(found.sessions.first?.subagents.isEmpty ?? false,
                      "a sub-agent whose parent is not live is dropped, not promoted")
    }

    func testAThreadSourceOfUserOrNoneIsTheOnlyMainThread() {
        func main(_ source: String?) -> Bool {
            var m = CodexRolloutDiscovery.Meta(); m.threadSource = source; return m.isMainThread
        }
        XCTAssertTrue(main("user"))
        XCTAssertTrue(main(nil), "the CLI's own rollouts carry no thread_source")
        XCTAssertFalse(main("subagent"))
        XCTAssertFalse(main("guardian_review"))
    }

    /// The hook-written state file is the richer record; the rollout row only fills the gap.
    func testAHookStateFileForTheSameIDWinsOverTheRolloutRow() {
        let rolloutRow = CodexRolloutDiscovery.discover(now: now, io: io(files: [
            ("/p.jsonl", now, meta(id: "P") + "\n" + body(lastKind: "function_call")),
        ])).sessions
        var fromHook = Session()
        fromHook.sessionID = "P"
        fromHook.agent = .codex
        fromHook.state = .needsYou
        fromHook.pid = 4242
        let merged = Session.merge(files: [fromHook], discovered: rolloutRow)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.state, .needsYou)
        XCTAssertEqual(merged.first?.pid, 4242)
    }
}
