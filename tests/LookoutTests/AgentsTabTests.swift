import AppKit
import SwiftUI
import XCTest
@testable import Lookout

/// SPEC §12.3: the two-row header, the Agents tab, and the worktree chip.
final class AgentsTabTests: XCTestCase {
    /// The shipped appearance — what these measurements are pinned against (SPEC §14).
    private let metrics = Theme.Metrics.standard

    private let decoder = JSONDecoder()

    private func session(_ json: String) throws -> Session {
        try decoder.decode(Session.self, from: Data(json.utf8))
    }

    private func layout<V: View>(_ view: V) -> NSSize {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize
    }

    // MARK: - Header (SPEC §12.3)

    func testHeaderRowTwoSpellsOutTheSubagentCount() throws {
        let sessions = try [
            #"{"session_id":"1","agent":"claude","state":"working","subagents":[{"id":"a"},{"id":"b"}]}"#,
            #"{"session_id":"2","agent":"claude","state":"idle"}"#,
            #"{"session_id":"3","agent":"codex","state":"done","subagents":[{"id":"c"}]}"#,
        ].map { try session($0) }

        XCTAssertEqual(Session.summary(sessions), "3 agents · 2 claude · 1 codex")
        XCTAssertEqual(Session.detail(sessions), "2 claude · 1 codex · 3 sub-agents")
        XCTAssertFalse(Session.detail(sessions).contains("⑂"), "words, not a symbol")
    }

    func testOneSubagentIsNotCalledOneSubagents() throws {
        let sessions = [try session(#"{"session_id":"1","agent":"claude","subagents":[{"id":"a"}]}"#)]
        XCTAssertEqual(Session.detail(sessions), "1 claude · 1 sub-agent")
    }

    func testHeaderRowTwoSaysNothingAboutSubagentsWhenThereAreNone() throws {
        let sessions = try [
            #"{"session_id":"1","agent":"claude","state":"working"}"#,
            #"{"session_id":"2","agent":"codex","state":"idle","subagents":[]}"#,
        ].map { try session($0) }
        XCTAssertEqual(Session.detail(sessions), "1 claude · 1 codex")
        XCTAssertEqual(Session.detail([]), "")
    }

    /// Both rows are full width now, so the breakdown gets the whole panel and the alarm pill
    /// no longer fights it for room — but the two together still have to fit the fixed height.
    func testTheTwoHeaderRowsFitTheFixedHeaderHeight() {
        let header = layout(
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: metrics.controlGap) {
                    Circle().frame(width: 7, height: 7)
                    Text("13 agents").font(metrics.header).lineLimit(1)
                    Spacer(minLength: metrics.controlGap)
                    NeedsYouPill(count: 2)
                    IconButton(symbol: "pin.fill", help: "Pin", action: {})
                    IconButton(symbol: "gearshape", help: "Settings", action: {})
                }
                Text("12 claude · 1 codex · 27 sub-agents")
                    .font(metrics.rowSecondary).lineLimit(1).truncationMode(.tail)
            }
            .padding(.horizontal, metrics.padding)
            .frame(width: metrics.width)
        )
        XCTAssertLessThanOrEqual(header.height, metrics.headerHeight)
        XCTAssertGreaterThan(metrics.headerHeight, 56, "row 2 needs its own line now")
    }

    // MARK: - The Agents tab

    func testTheTabSitsBetweenSessionsAndUsage() {
        // SPEC §17.5 adds History between Agents and Usage; SPEC §18 adds Sentinel after Usage.
        XCTAssertEqual(
            PanelTab.allCases.map(\.rawValue),
            ["sessions", "agents", "history", "usage", "sentinel"]
        )
        XCTAssertEqual(PanelTab.agents.label, "Agents")
    }

    func testEveryLiveSubagentIsListedInParentThenStartOrder() throws {
        // The list arrives already sorted for display, so parent order is list order.
        let sessions = try [
            """
            {"session_id":"first","project":"alpha","state":"needs_you","subagents":[
              {"id":"a2","type":"code-reviewer","started_at":"2026-09-02T04:20:00Z"},
              {"id":"a1","type":"general-purpose","description":"Translate module three",
               "model":"sonnet","started_at":"2026-09-02T04:10:00Z"}
            ]}
            """,
            """
            {"session_id":"second","project":"beta","state":"working","subagents":[
              {"id":"b1","type":"planner","started_at":"2026-09-02T04:05:00Z"}
            ]}
            """,
            #"{"session_id":"third","project":"gamma","state":"idle"}"#,
        ].map { try session($0) }

        let live = Session.liveSubagents(sessions)
        XCTAssertEqual(live.map(\.subagent.id), ["a1", "a2", "b1"])
        XCTAssertEqual(live.map { $0.session.project }, ["alpha", "alpha", "beta"])
        XCTAssertEqual(live.map(\.id), ["first/a1", "first/a2", "second/b1"])

        // Row content (SPEC §12.3).
        XCTAssertEqual(live[0].headline, "Translate module three")
        XCTAssertEqual(live[0].chip, "Sonnet", "the model when there is one…")
        XCTAssertEqual(live[1].headline, "code-reviewer", "…the type when there is not")
        XCTAssertEqual(live[1].chip, "code-reviewer")
        XCTAssertTrue(live[0].hasElapsed)
        XCTAssertTrue(live[0].tooltip.contains("Session alpha"))
    }

    func testAnEntryWithNoStartTimeKeepsItsPlaceAndShowsNoElapsed() throws {
        let sessions = [try session("""
        {"session_id":"s","project":"alpha","subagents":[
          {"id":"a","type":"one"},
          {"id":"b","type":"two","started_at":"2026-09-02T04:10:00Z"}
        ]}
        """)]
        let live = Session.liveSubagents(sessions)
        // A known start time sorts ahead of an unknown one; the unknown keeps file order.
        XCTAssertEqual(live.map(\.subagent.id), ["b", "a"])
        XCTAssertFalse(live[1].hasElapsed)
        XCTAssertEqual(live[1].elapsed(), 0)
        XCTAssertEqual(live[1].headline, "one")
    }

    func testNoSubagentsAnywhereMeansAnEmptyList() throws {
        let sessions = [try session(#"{"session_id":"s","state":"idle"}"#)]
        XCTAssertTrue(Session.liveSubagents(sessions).isEmpty)
        XCTAssertTrue(Session.liveSubagents([]).isEmpty)
    }

    func testTheAgentsListAndItsRowsLayOutInsideTheirFixedHeights() throws {
        let sessions = [try session("""
        {"session_id":"s","project":"docs-site","host":"devin","model":"llama-3.3-70b",
         "provider":"local","subagents":[
           {"id":"a","type":"general-purpose","description":"Skriv tests til eksempelkoden",
            "model":"sonnet","started_at":"2026-09-02T04:18:00Z"}
         ]}
        """)]
        let entry = try XCTUnwrap(Session.liveSubagents(sessions).first)
        let row = layout(
            SubagentRow(entry: entry, onTap: {}).frame(width: metrics.width - 16)
        )
        XCTAssertEqual(row.height, metrics.agentRowHeight, accuracy: 0.5)

        XCTAssertEqual(metrics.agentListHeight(rows: 0), metrics.emptyHeight)
        XCTAssertEqual(metrics.agentListHeight(rows: 1), metrics.agentRowHeight)
        XCTAssertEqual(metrics.agentListHeight(rows: 400), metrics.listMaxHeight)
        XCTAssertLessThan(
            metrics.totalHeight(
                tab: .agents, rows: 0, cards: 0, extraLine: false, agents: 500
            ),
            600
        )
    }

    // MARK: - Worktrees (SPEC §12.3)

    func testTheWorktreeChipAppearsWithoutTouchingTheTitleOrTheJump() throws {
        let value = try session("""
        {"session_id":"s","state":"working","cwd":"/Users/you/Desktop/Acme/acme-web",
         "project":"acme-web","origin_cwd":"/Users/you/Desktop/Acme/acme-web",
         "active_cwd":"/Users/you/Desktop/Acme/_wt/wt-export-import",
         "worktree":"wt-export-import","pid":42}
        """)
        XCTAssertEqual(value.project, "acme-web", "the row keeps the main project")
        // 14 characters, so the project name beside it stays whole on a 360 pt row.
        XCTAssertEqual(value.worktreeChip, "⎇ wt-export-impo…")
        XCTAssertTrue(
            value.worktreeTooltip.contains("/Users/you/Desktop/Acme/_wt/wt-export-import")
        )
        XCTAssertTrue(
            value.tooltip.contains("Active: /Users/you/Desktop/Acme/_wt/wt-export-import")
        )

        let plain = try session(#"{"session_id":"s","cwd":"/tmp/x"}"#)
        XCTAssertNil(plain.worktreeChip)
        XCTAssertFalse(plain.tooltip.contains("Active:"))

        // A very long worktree name is cut, so line 1 cannot grow.
        let long = try session("""
        {"session_id":"s","worktree":"\(String(repeating: "w", count: 60))"}
        """)
        XCTAssertEqual(try XCTUnwrap(long.worktreeChip).count, Session.worktreeNameLimit + 3)
    }

    func testTheWorktreeChipIsExactlyAsTallAsTheHostChipBesideIt() {
        let host = layout(HostChip(host: .devin))
        let worktree = layout(WorktreeChip(text: "⎇ wt-export-import", help: "/tmp"))
        XCTAssertEqual(worktree.height, host.height, accuracy: 0.5)
        XCTAssertGreaterThan(worktree.width, 0)
    }

    func testTheFixtureThatCarriesAWorktreeStillLaysOutAtTheFixedRowHeight() throws {
        let value = try decoder.decode(Session.self, from: Data(contentsOf:
            Fixtures.sessionsDirectory
                .appendingPathComponent("claude-3b6a2c19-88de-4d15-9c30-51e0f4a7b2c8.json")))
        XCTAssertEqual(value.worktree, "wt-export-import")
        XCTAssertEqual(value.activeCwd, "/Users/you/Desktop/Acme/_wt/wt-export-import")
        XCTAssertEqual(value.originCwd, "/Users/you/Desktop/docs-site")
        XCTAssertEqual(value.subagents.compactMap(\.cwd).count, 2)

        let row = layout(
            SessionRow(session: value, isSeen: false, onTap: {})
                .frame(width: metrics.width - 16)
        )
        XCTAssertEqual(row.height, metrics.rowHeight, accuracy: 0.5)
    }
}
