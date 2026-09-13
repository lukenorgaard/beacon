import AppKit
import SwiftUI
import XCTest
@testable import Lookout

extension CodexQuestionWatcherTests {
    // MARK: - CodexQuestionCheck.run (pure, injected clock/stat — no timer, no real file)

    func stat(size: UInt64 = 100, modified: Date = Date(timeIntervalSince1970: 1_000))
        -> CodexRolloutStat {
        CodexRolloutStat(size: size, modified: modified)
    }

    func candidate(id: String = "s1", needsYouByHook: Bool = false) -> CodexQuestionCandidate {
        CodexQuestionCandidate(
            sessionID: id, transcriptPath: "/fake/\(id).jsonl", isNeedsYouByHook: needsYouByHook
        )
    }

    func testAFirstLookReadsTheTailAndPublishesTheQuestion() {
        let line = questionCallLine(callID: "call_1", questions: [(nil, "q", "Which plan?", ["A"])])
        var tailReads = 0
        let result = CodexQuestionCheck.run(
            candidates: [candidate()], cache: [:],
            statter: { _ in self.stat() },
            tailReader: { _, _ in tailReads += 1; return self.tail([line]) }
        )
        XCTAssertEqual(tailReads, 1)
        XCTAssertEqual(result.questions["s1"]?.callID, "call_1")
        XCTAssertEqual(result.cache["s1"]?.stat, stat())
    }

    /// The whole point of the cache: "skip files whose size+mtime are unchanged since the last
    /// look" — a second look at the same stat must never re-read the file.
    func testASecondLookAtAnUnchangedStatSkipsTheTailReadEntirely() {
        let line = questionCallLine(callID: "call_1", questions: [(nil, "q", "Which plan?", ["A"])])
        var tailReads = 0
        let statter: (String) -> CodexRolloutStat? = { _ in self.stat() }
        let tailReader: (String, Int) -> Data? = { _, _ in
            tailReads += 1
            return self.tail([line])
        }
        let first = CodexQuestionCheck.run(
            candidates: [candidate()], cache: [:], statter: statter, tailReader: tailReader
        )
        XCTAssertEqual(tailReads, 1)

        let second = CodexQuestionCheck.run(
            candidates: [candidate()], cache: first.cache, statter: statter, tailReader: tailReader
        )
        XCTAssertEqual(tailReads, 1, "the stat did not move — no second read")
        XCTAssertEqual(second.questions["s1"], first.questions["s1"], "the cached answer is reused")
    }

    func testAChangedStatTriggersAFreshTailRead() {
        let older = questionCallLine(callID: "call_old", questions: [(nil, "q", "Old", ["A"])])
        let newer = questionCallLine(callID: "call_new", questions: [(nil, "q", "New", ["B"])])
        var tailReads = 0
        var currentStat = stat(size: 100, modified: Date(timeIntervalSince1970: 1_000))
        var currentLine = older
        let statter: (String) -> CodexRolloutStat? = { _ in currentStat }
        let tailReader: (String, Int) -> Data? = { _, _ in
            tailReads += 1
            return self.tail([currentLine])
        }
        let first = CodexQuestionCheck.run(
            candidates: [candidate()], cache: [:], statter: statter, tailReader: tailReader
        )
        XCTAssertEqual(first.questions["s1"]?.callID, "call_old")

        currentStat = stat(size: 140, modified: Date(timeIntervalSince1970: 1_010))
        currentLine = newer
        let second = CodexQuestionCheck.run(
            candidates: [candidate()], cache: first.cache, statter: statter, tailReader: tailReader
        )
        XCTAssertEqual(tailReads, 2)
        XCTAssertEqual(second.questions["s1"]?.callID, "call_new")
    }

    /// The cheap skip: a candidate the hook already marked `needs_you` is not even stat-ed.
    func testANeedsYouByHookCandidateIsSkippedEntirely() {
        var statCalls = 0
        var tailReads = 0
        let result = CodexQuestionCheck.run(
            candidates: [candidate(needsYouByHook: true)], cache: [:],
            statter: { _ in statCalls += 1; return self.stat() },
            tailReader: { _, _ in tailReads += 1; return nil }
        )
        XCTAssertEqual(statCalls, 0)
        XCTAssertEqual(tailReads, 0)
        XCTAssertTrue(result.questions.isEmpty)
    }

    func testAMissingFileDropsItsCacheEntryAndItsQuestion() {
        let line = questionCallLine(callID: "call_1", questions: [(nil, "q", "Which plan?", ["A"])])
        let first = CodexQuestionCheck.run(
            candidates: [candidate()], cache: [:],
            statter: { _ in self.stat() }, tailReader: { _, _ in self.tail([line]) }
        )
        XCTAssertNotNil(first.questions["s1"])

        let second = CodexQuestionCheck.run(
            candidates: [candidate()], cache: first.cache,
            statter: { _ in nil }, tailReader: { _, _ in nil }
        )
        XCTAssertNil(second.questions["s1"])
        XCTAssertNil(second.cache["s1"])
    }

    /// A session that stopped being a candidate at all (it ended, or stopped being Codex) drops
    /// out of the cache too, rather than being kept forever.
    func testACandidateThatIsNoLongerLiveIsForgotten() {
        let line = questionCallLine(callID: "call_1", questions: [(nil, "q", "Which plan?", ["A"])])
        let first = CodexQuestionCheck.run(
            candidates: [candidate(id: "s1")], cache: [:],
            statter: { _ in self.stat() }, tailReader: { _, _ in self.tail([line]) }
        )
        XCTAssertNotNil(first.cache["s1"])

        let second = CodexQuestionCheck.run(
            candidates: [candidate(id: "s2")], cache: first.cache,
            statter: { _ in self.stat() }, tailReader: { _, _ in self.tail([line]) }
        )
        XCTAssertNil(second.cache["s1"], "s1 is no longer a candidate at all")
    }

    // MARK: - AppState wiring: decoration, counts, sort, notify-once, the card

    func testAnOpenQuestionDecoratesTheSessionSortsAboveWorkingAndCountsAsNeedsYou() {
        state.codexQuestions.publish(["s1": question(text: "Which plan should we use?")])
        state.apply([codexSession(id: "s1"), codexSession(id: "s2")])

        XCTAssertEqual(
            state.allSessions.map(\.id), ["s1", "s2"], "the open question sorts to the top"
        )
        let decorated = try! XCTUnwrap(state.allSessions.first { $0.id == "s1" })
        XCTAssertEqual(decorated.state, .needsYou)
        XCTAssertEqual(decorated.reason, "question")
        XCTAssertEqual(decorated.detail, "Which plan should we use?")
        XCTAssertEqual(state.needsYouCount, 1)
        XCTAssertEqual(state.workingCount, 1, "the decorated session no longer counts as working")
        XCTAssertEqual(state.statusColor, .systemRed)
    }

    func testTheDecorationIsRemovedOnceTheWatcherNoLongerSeesAnOpenQuestion() {
        state.codexQuestions.publish(["s1": question()])
        state.apply([codexSession(id: "s1")])
        XCTAssertEqual(state.allSessions.first?.state, .needsYou)

        // The answer landed in the TUI — the watcher's next look finds nothing open.
        state.codexQuestions.publish([:])
        state.apply([codexSession(id: "s1")])
        XCTAssertEqual(
            state.allSessions.first?.state, .working, "the hook-driven state shows again"
        )
    }

    func testANewQuestionOpensACardOnceAndOnlyReopensWhenTheCallIDChanges() {
        state.codexQuestions.publish(["s1": question(callID: "call_1")])
        state.apply([codexSession(id: "s1")])
        XCTAssertEqual(state.attention.current?.id, "s1")

        state.attention.dismissCurrent()
        state.apply([codexSession(id: "s1")]) // same open question, next tick
        XCTAssertNil(state.attention.current, "the same open question must not reopen the card")

        state.codexQuestions.publish(["s1": question(callID: "call_2", text: "A new question")])
        state.apply([codexSession(id: "s1")])
        XCTAssertEqual(
            state.attention.current?.id, "s1", "a genuinely new question reopens the card"
        )
    }

    /// SPEC bug fix 2026-09-04, item 3's own rule: a real, hook-driven request for the session
    /// always wins over the in-memory Codex question — the exact composition
    /// `AttentionCardWindow.sync()` uses.
    func testAHookDrivenRequestAlwaysWinsOverTheInMemoryCodexQuestion() throws {
        let requests = RequestStore(home: home)
        try FileManager.default.createDirectory(
            at: home.requests, withIntermediateDirectories: true
        )
        let json = """
        {"session_id":"s1","request_id":"r1","kind":"permission","tool_name":"Bash",
         "command_or_path":"rm -rf build"}
        """
        try Data(json.utf8).write(to: home.requests.appendingPathComponent("codex-s1-r1.json"))
        requests.start()
        let deadline = Date().addingTimeInterval(2)
        while requests.requests.isEmpty, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        var session = codexSession(id: "s1", state: .needsYou, reason: "question")
        session.requestID = "r1"
        state.codexQuestions.publish(["s1": question()])

        // The exact `??` `AttentionCardWindow.sync()` uses.
        let resolved = requests.request(for: session) ?? state.codexQuestionRequest(for: session)
        XCTAssertEqual(resolved?.kind, .permission, "the real, hook-driven request wins")
        XCTAssertEqual(resolved?.commandOrPath, "rm -rf build")

        // And with no hook-driven request at all, the fallback carries the question through.
        var noHookRequest = session
        noHookRequest.requestID = nil
        let fallback = requests.request(for: noHookRequest)
            ?? state.codexQuestionRequest(for: noHookRequest)
        XCTAssertEqual(fallback?.isCodexQuestion, true)
    }
}
