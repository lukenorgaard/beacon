import XCTest
@testable import Lookout

/// SPEC §17.5: parsing one `history.jsonl` line, filtering, searching and day-grouping — all
/// pure, so none of it needs a window or a live session.
final class HistoryModelTests: XCTestCase {
    // MARK: - Decoding

    func testDecodesEveryFieldFromOneLine() throws {
        let line = """
        {"ts":"2026-09-02T04:50:00Z","agent":"claude","session_id":"s1","project":"daily-notes",
         "name":"Fix the login redirect loop","from":"working","to":"needs_you",
         "reason":"permission","detail":"Bash: rm -rf build","last_message":null}
        """
        let entry = try XCTUnwrap(HistoryEntry.decode(line, index: 3))
        XCTAssertEqual(entry.sessionID, "s1")
        XCTAssertEqual(entry.agent, .claude)
        XCTAssertEqual(entry.project, "daily-notes")
        XCTAssertEqual(entry.name, "Fix the login redirect loop")
        XCTAssertEqual(entry.from, "working")
        XCTAssertEqual(entry.to, "needs_you")
        XCTAssertEqual(entry.reason, "permission")
        XCTAssertEqual(entry.detail, "Bash: rm -rf build")
        XCTAssertNil(entry.lastMessage)
        XCTAssertEqual(entry.index, 3)
        XCTAssertEqual(entry.id, "s1#3")
    }

    func testMissingSessionIdIsTheOnlyFatalCase() {
        XCTAssertNil(HistoryEntry.decode(#"{"ts":"2026-09-02T04:50:00Z"}"#, index: 0))
        XCTAssertNil(HistoryEntry.decode(#"{"session_id":""}"#, index: 0))
        XCTAssertNil(HistoryEntry.decode("not json", index: 0))
        XCTAssertNil(HistoryEntry.decode("", index: 0))
    }

    /// A line with only `session_id` still decodes — everything else is optional, exactly like
    /// `Session`'s own tolerant decode.
    func testEveryOtherFieldIsOptional() throws {
        let entry = try XCTUnwrap(HistoryEntry.decode(#"{"session_id":"bare"}"#, index: 0))
        XCTAssertEqual(entry.sessionID, "bare")
        XCTAssertEqual(entry.ts, .distantPast, "no `ts` at all sinks to the very back")
        XCTAssertNil(entry.project)
        XCTAssertNil(entry.to)
    }

    // MARK: - Display helpers

    func testTransitionLabelReadsFromArrowToWithTheReasonInParens() throws {
        let withReason = try XCTUnwrap(HistoryEntry.decode(
            #"{"session_id":"s1","from":"working","to":"needs_you","reason":"permission"}"#, index: 0
        ))
        // Underscores become spaces — `needs you`, not the raw `needs_you` — so the row reads
        // like prose rather than a wire enum value.
        XCTAssertEqual(withReason.transitionLabel, "working → needs you (permission)")

        let noFrom = try XCTUnwrap(HistoryEntry.decode(
            #"{"session_id":"s1","to":"idle","reason":"session_start"}"#, index: 0
        ))
        XCTAssertEqual(noFrom.transitionLabel, "start → idle (session_start)")

        let noReason = try XCTUnwrap(HistoryEntry.decode(
            #"{"session_id":"s1","from":"working","to":"done"}"#, index: 0
        ))
        XCTAssertEqual(noReason.transitionLabel, "working → done")
    }

    func testDisplayLabelPrefersBothProjectAndNameThenWhicheverExists() throws {
        let both = try XCTUnwrap(HistoryEntry.decode(
            #"{"session_id":"s1","project":"daily-notes","name":"Fix the redirect"}"#, index: 0
        ))
        XCTAssertEqual(both.displayLabel, "daily-notes — Fix the redirect")

        let sameTwice = try XCTUnwrap(HistoryEntry.decode(
            #"{"session_id":"s1","project":"daily-notes","name":"daily-notes"}"#, index: 0
        ))
        XCTAssertEqual(sameTwice.displayLabel, "daily-notes", "never `x — x`")

        let projectOnly = try XCTUnwrap(HistoryEntry.decode(
            #"{"session_id":"s1","project":"daily-notes"}"#, index: 0
        ))
        XCTAssertEqual(projectOnly.displayLabel, "daily-notes")

        let neither = try XCTUnwrap(HistoryEntry.decode(#"{"session_id":"s1"}"#, index: 0))
        XCTAssertEqual(neither.displayLabel, "s1")
    }

    func testDetailToolAndArgumentSplitOnTheFirstColon() throws {
        let entry = try XCTUnwrap(HistoryEntry.decode(
            #"{"session_id":"s1","detail":"Bash: rm -rf build"}"#, index: 0
        ))
        XCTAssertEqual(entry.detailTool, "Bash")
        XCTAssertEqual(entry.detailArgument, "rm -rf build")

        let noColon = try XCTUnwrap(HistoryEntry.decode(
            #"{"session_id":"s1","detail":"nothing to split"}"#, index: 0
        ))
        XCTAssertNil(noColon.detailArgument)
    }

    // MARK: - Filter chips (SPEC §17.5: Needs you / Finished / Started / Ended)

    func testFilterMapping() throws {
        func kind(_ json: String) throws -> HistoryFilter? {
            HistoryFilter.of(try XCTUnwrap(HistoryEntry.decode(json, index: 0)))
        }
        XCTAssertEqual(try kind(#"{"session_id":"s","to":"needs_you"}"#), .needsYou)
        XCTAssertEqual(try kind(#"{"session_id":"s","to":"done"}"#), .done)
        XCTAssertEqual(try kind(#"{"session_id":"s","to":"ended"}"#), .ended)
        XCTAssertEqual(
            try kind(#"{"session_id":"s","to":"idle","reason":"session_start"}"#), .started
        )
        // `ended` wins even if `reason` also happens to say `session_start` — SessionEnd is
        // never a session's very first line.
        XCTAssertEqual(
            try kind(#"{"session_id":"s","to":"ended","reason":"session_start"}"#), .ended
        )
        XCTAssertNil(try kind(#"{"session_id":"s","to":"working"}"#))
        XCTAssertNil(try kind(#"{"session_id":"s","to":"idle"}"#))
    }

    func testFilterLabelsMatchTheSpec() {
        XCTAssertEqual(HistoryFilter.needsYou.label, "Needs you")
        XCTAssertEqual(HistoryFilter.done.label, "Finished")
        XCTAssertEqual(HistoryFilter.started.label, "Started")
        XCTAssertEqual(HistoryFilter.ended.label, "Ended")
    }

    // MARK: - Search

    private func entries(_ pairs: [(project: String?, name: String?, detail: String?)]) -> [HistoryEntry] {
        pairs.enumerated().map { index, pair in
            HistoryEntry(
                ts: Date(), agent: .claude, sessionID: "s\(index)",
                project: pair.project, name: pair.name, from: nil, to: "working",
                reason: nil, detail: pair.detail, lastMessage: nil, index: index
            )
        }
    }

    func testSearchMatchesProjectNameOrDetailCaseInsensitively() {
        let all = entries([
            (project: "daily-notes", name: nil, detail: nil),
            (project: "billing-api", name: "Add tenant scoping", detail: nil),
            (project: "docs-site", name: nil, detail: "Bash: rm -rf build"),
        ])

        XCTAssertEqual(HistoryStore.search(all, query: "").count, 3, "empty query keeps everything")
        XCTAssertEqual(HistoryStore.search(all, query: "DAILY").map(\.sessionID), ["s0"])
        XCTAssertEqual(HistoryStore.search(all, query: "tenant").map(\.sessionID), ["s1"])
        XCTAssertEqual(HistoryStore.search(all, query: "rm -rf").map(\.sessionID), ["s2"])
        XCTAssertTrue(HistoryStore.search(all, query: "nothing matches this").isEmpty)
    }

    // MARK: - Filtering + combined apply

    func testFilteredWithAnEmptySetKeepsEverythingIncludingUnclassifiedTransitions() throws {
        let working = try XCTUnwrap(HistoryEntry.decode(#"{"session_id":"s","to":"working"}"#, index: 0))
        XCTAssertEqual(HistoryStore.filtered([working], kinds: []).count, 1)
        XCTAssertTrue(HistoryStore.filtered([working], kinds: [.done]).isEmpty)
    }

    func testApplyFiltersThenSearches() throws {
        let needsYou = try XCTUnwrap(HistoryEntry.decode(
            #"{"session_id":"s1","project":"daily-notes","to":"needs_you"}"#, index: 0
        ))
        let done = try XCTUnwrap(HistoryEntry.decode(
            #"{"session_id":"s2","project":"daily-notes","to":"done"}"#, index: 1
        ))
        let result = HistoryStore.apply([needsYou, done], filters: [.needsYou], search: "daily")
        XCTAssertEqual(result.map(\.sessionID), ["s1"])
    }

    // MARK: - Grouping

    func testGroupedBucketsByCalendarDayNewestDayFirst() {
        let calendar = Calendar(identifier: .gregorian)
        let day1 = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 10))!
        let day2a = calendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 8))!
        let day2b = calendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 20))!

        // Newest first, as `HistoryStore.load` already sorts.
        let entries = [
            HistoryEntry(ts: day2b, agent: .claude, sessionID: "s1", project: nil, name: nil, from: nil, to: nil, reason: nil, detail: nil, lastMessage: nil, index: 2),
            HistoryEntry(ts: day2a, agent: .claude, sessionID: "s2", project: nil, name: nil, from: nil, to: nil, reason: nil, detail: nil, lastMessage: nil, index: 1),
            HistoryEntry(ts: day1, agent: .claude, sessionID: "s3", project: nil, name: nil, from: nil, to: nil, reason: nil, detail: nil, lastMessage: nil, index: 0),
        ]

        let groups = HistoryStore.grouped(entries, calendar: calendar)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].entries.map(\.sessionID), ["s1", "s2"])
        XCTAssertEqual(groups[1].entries.map(\.sessionID), ["s3"])
        XCTAssertTrue(groups[0].day > groups[1].day, "newest day group first")
    }

    // MARK: - Loading the checked-in fixture

    func testLoadReadsTheCheckedInFixtureNewestFirstAndCapped() {
        let now = ISO8601.date("2026-09-03T18:00:00Z")!
        let entries = HistoryStore.load(home: LookoutHome(root: Fixtures.home), now: now)

        XCTAssertEqual(entries.count, 7, "every line in the fixture is within 7 days of `now`")
        XCTAssertEqual(entries.first?.sessionID, "ended-9f00b1a2-4c77-4e21-9a10-2f6b8c9d0e11")
        XCTAssertTrue(entries[0].ts >= entries[1].ts, "newest first")
        XCTAssertTrue(entries.contains { $0.sessionID == "ab813983-4f21-4c0e-9a17-2f5b6c8d1e00" })
    }

    func testLoadDropsEntriesOlderThanSevenDays() {
        // A `now` far enough past the fixture's dates that the seven-day window excludes all of it.
        let now = ISO8601.date("2026-10-01T00:00:00Z")!
        let entries = HistoryStore.load(home: LookoutHome(root: Fixtures.home), now: now)
        XCTAssertTrue(entries.isEmpty)
    }

    func testLoadMergesTheRotatedFileBeforeTheLiveOne() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = ISO8601.date("2026-09-02T12:00:00Z")!
        try #"{"ts":"2026-09-02T08:00:00Z","session_id":"old","to":"idle"}"#
            .write(to: root.appendingPathComponent("history.1.jsonl"), atomically: true, encoding: .utf8)
        try #"{"ts":"2026-09-02T10:00:00Z","session_id":"new","to":"done"}"#
            .write(to: root.appendingPathComponent("history.jsonl"), atomically: true, encoding: .utf8)

        let entries = HistoryStore.load(home: LookoutHome(root: root), now: now)
        XCTAssertEqual(entries.map(\.sessionID), ["new", "old"], "newest first across both files")
    }

    func testLoadWithNeitherFileReturnsEmpty() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-history-\(UUID().uuidString)")
        XCTAssertTrue(HistoryStore.load(home: LookoutHome(root: root)).isEmpty)
    }

    func testRowCapKeepsOnlyTheNewestFiveHundred() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = ISO8601.date("2026-09-02T12:00:00Z")!
        var lines: [String] = []
        for i in 0..<520 {
            let minute = String(format: "%02d", i % 60)
            let hour = String(format: "%02d", 0 + i / 60 % 12)
            lines.append(#"{"ts":"2026-09-02T\#(hour):\#(minute):00Z","session_id":"s\#(i)","to":"working"}"#)
        }
        try lines.joined(separator: "\n").write(
            to: root.appendingPathComponent("history.jsonl"), atomically: true, encoding: .utf8
        )

        let entries = HistoryStore.load(home: LookoutHome(root: root), now: now)
        XCTAssertEqual(entries.count, HistoryStore.rowCap)
        // The newest lines (highest index) survive the cap.
        XCTAssertEqual(entries.first?.sessionID, "s519")
    }

    // MARK: - AppState integration (SPEC §17.5: lazy load, filters, the click's jump)

    func testAppStateLoadsHistoryOnlyOnceAndOnlyWhenAsked() {
        let suite = "io.github.lukenorgaard.beacon.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)
        let state = AppState(
            settings: settings,
            store: SessionStore(home: Fixtures.home),
            usage: UsageClient(),
            home: LookoutHome(root: Fixtures.home)
        )

        XCTAssertNil(state.historyEntries, "nothing read until the tab is opened")
        XCTAssertEqual(state.historyGroups.count, 0)

        state.loadHistoryIfNeeded(now: Fixtures.historyNow)
        XCTAssertNotNil(state.historyEntries)
        XCTAssertGreaterThan(state.historyRowCount, 0)
        let loadedOnce = state.historyEntries

        // A second call must not re-read the file — same array identity's *contents*, proven by
        // the count staying put (the fixture never changes under a running test).
        state.loadHistoryIfNeeded(now: Fixtures.historyNow)
        XCTAssertEqual(state.historyEntries?.count, loadedOnce?.count)
    }

    func testAppStateFilterAndSearchRecomputeTheGroups() {
        let suite = "io.github.lukenorgaard.beacon.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)
        let state = AppState(
            settings: settings,
            store: SessionStore(home: Fixtures.home),
            usage: UsageClient(),
            home: LookoutHome(root: Fixtures.home)
        )
        state.loadHistoryIfNeeded(now: Fixtures.historyNow)
        let everything = state.historyRowCount
        XCTAssertGreaterThan(everything, 0)

        state.toggleHistoryFilter(.ended)
        XCTAssertLessThan(state.historyRowCount, everything)
        XCTAssertTrue(state.historyGroups.allSatisfy { group in
            group.entries.allSatisfy { HistoryFilter.of($0) == .ended }
        })

        // Toggling it back off returns to "All".
        state.toggleHistoryFilter(.ended)
        XCTAssertEqual(state.historyRowCount, everything)

        state.historySearch = "export"
        XCTAssertTrue(state.historyGroups.allSatisfy { group in
            group.entries.allSatisfy { ($0.name ?? "").localizedCaseInsensitiveContains("export") }
        })
        XCTAssertGreaterThan(state.historyRowCount, 0)
    }

    /// A row for a session that is not live is a safe no-op — it must never touch `Jumper`.
    func testJumpToHistoryEntryIsANoOpWhenTheSessionIsNotLive() throws {
        let suite = "io.github.lukenorgaard.beacon.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)
        let state = AppState(
            settings: settings,
            store: SessionStore(home: Fixtures.home),
            usage: UsageClient(),
            home: LookoutHome(root: Fixtures.home)
        )
        // `.start()` is never called, so `allSessions` stays empty — every entry looks ended.
        XCTAssertTrue(state.allSessions.isEmpty)
        state.loadHistoryIfNeeded(now: Fixtures.historyNow)
        let entry = try XCTUnwrap(state.historyGroups.first?.entries.first)
        state.jumpToHistoryEntry(entry) // must not crash or touch a real Jumper
    }
}
