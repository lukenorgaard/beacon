import AppKit
import SwiftUI
import XCTest
@testable import Lookout

/// SPEC §9.3: sub-agents per session — decoding, the header count, the row's secondary text,
/// the tooltip, and the fact that none of it changes the row's height.
final class SubagentTests: XCTestCase {
    /// The shipped appearance — what these measurements are pinned against (SPEC §14).
    private let metrics = Theme.Metrics.standard

    private let decoder = JSONDecoder()

    private func session(_ json: String) throws -> Session {
        try decoder.decode(Session.self, from: Data(json.utf8))
    }

    // MARK: - Decoding

    func testDecodesAFullSubagentList() throws {
        let value = try session("""
        {
          "session_id": "s1",
          "state": "working",
          "subagents": [
            {
              "id": "agent_7f21",
              "type": "general-purpose",
              "description": "Rewrite module three",
              "model": "sonnet",
              "started_at": "2026-09-02T04:18:00Z"
            },
            {"id": "agent_9c04", "type": "code-reviewer"}
          ]
        }
        """)

        XCTAssertEqual(value.subagents.count, 2)
        XCTAssertEqual(value.subagents[0].id, "agent_7f21")
        XCTAssertEqual(value.subagents[0].type, "general-purpose")
        XCTAssertEqual(value.subagents[0].model, "sonnet")
        XCTAssertEqual(value.subagents[0].description, "Rewrite module three")
        XCTAssertEqual(value.subagents[0].startedAt, ISO8601.date("2026-09-02T04:18:00Z"))
        XCTAssertNil(value.subagents[1].model, "an entry may carry nothing but an id and a type")
        XCTAssertNil(value.subagents[1].startedAt)
    }

    func testDecodingIsTolerant() throws {
        XCTAssertTrue(try session(#"{"session_id":"s1"}"#).subagents.isEmpty, "missing → empty")
        XCTAssertTrue(
            try session(#"{"session_id":"s1","subagents":[]}"#).subagents.isEmpty
        )
        XCTAssertTrue(
            try session(#"{"session_id":"s1","subagents":"three"}"#).subagents.isEmpty,
            "a wrong-shaped value must not take the session down"
        )
        XCTAssertTrue(
            try session(#"{"session_id":"s1","subagents":["a","b"]}"#).subagents.isEmpty
        )

        // Fields of the wrong type degrade one at a time.
        let odd = try session(#"{"session_id":"s1","subagents":[{"id":7,"model":null,"started_at":"nonsense"}]}"#)
        XCTAssertEqual(odd.subagents.count, 1)
        XCTAssertEqual(odd.subagents[0].id, "")
        XCTAssertEqual(odd.subagents[0].type, "")
        XCTAssertNil(odd.subagents[0].startedAt)
        XCTAssertEqual(odd.subagents[0].summary, "sub-agent")
    }

    func testSubagentsSurviveAnEncodeRoundTrip() throws {
        let original = try session("""
        {"session_id":"s1","state":"working","subagents":[
          {"id":"a1","type":"t","description":"d","model":"m","started_at":"2026-09-02T04:18:00Z"}
        ]}
        """)
        let again = try decoder.decode(Session.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(original, again)

        let none = try session(#"{"session_id":"s2","state":"idle"}"#)
        let noneAgain = try decoder.decode(Session.self, from: JSONEncoder().encode(none))
        XCTAssertEqual(none, noneAgain)
    }

    // MARK: - Header (SPEC §9.3, superseded by §12.3)

    /// §9.3 counted sub-agents next to the breakdown as a symbol; §12.3 gave header row 2 the
    /// panel's whole width and spelled the count out. `AgentsTabTests` owns the wording — this
    /// only pins the *count* the header is built from.
    func testHeaderSecondLineAppendsTheSubagentCount() throws {
        let sessions = try [
            #"{"session_id":"1","agent":"claude","state":"working","subagents":[{"id":"a"},{"id":"b"}]}"#,
            #"{"session_id":"2","agent":"claude","state":"idle"}"#,
            #"{"session_id":"3","agent":"codex","state":"done","subagents":[{"id":"c"}]}"#,
        ].map { try session($0) }

        XCTAssertEqual(Session.subagentCount(sessions), 3)
        XCTAssertEqual(Session.summary(sessions), "3 agents · 2 claude · 1 codex")
        XCTAssertEqual(Session.detail(sessions), "2 claude · 1 codex · 3 sub-agents")
    }

    func testHeaderSaysNothingAboutSubagentsWhenThereAreNone() throws {
        let sessions = try [
            #"{"session_id":"1","agent":"claude","state":"working"}"#,
            #"{"session_id":"2","agent":"codex","state":"idle","subagents":[]}"#,
        ].map { try session($0) }

        XCTAssertEqual(Session.subagentCount(sessions), 0)
        XCTAssertEqual(Session.detail(sessions), "1 claude · 1 codex")
        XCTAssertFalse(Session.detail(sessions).contains("sub-agent"))
        XCTAssertEqual(Session.detail([]), "")
    }

    func testASingleSubagentIsNotCalledOneSubagents() throws {
        let sessions = [try session(#"{"session_id":"1","agent":"claude","subagents":[{"id":"a"}]}"#)]
        XCTAssertEqual(Session.subagentCount(sessions), 1)
        XCTAssertEqual(Session.detail(sessions), "1 claude · 1 sub-agent")
    }

    // MARK: - Row text (SPEC §9.3)

    func testAWorkingSessionWithSubagentsSaysWhatTheyAreDoing() throws {
        let value = try session("""
        {"session_id":"s1","state":"working","title":"Document the sample command-line tool",
         "subagents":[
           {"id":"a","type":"general-purpose","description":"Translate module three"},
           {"id":"b","type":"code-reviewer","description":"Review the sample parser"}
         ]}
        """)
        XCTAssertEqual(value.statusLabel, "Working…")
        XCTAssertEqual(value.secondaryText, "2 agents · Translate module three")
    }

    func testTheFirstDescriptionIsTruncated() throws {
        let long = String(repeating: "a", count: 120)
        let value = try session("""
        {"session_id":"s1","state":"working","subagents":[{"id":"a","description":"\(long)"}]}
        """)
        let text = try XCTUnwrap(value.secondaryText)
        XCTAssertTrue(text.hasPrefix("1 agent · "))
        XCTAssertTrue(text.hasSuffix("…"))
        XCTAssertEqual(
            text.count, "1 agent · ".count + Session.subagentDescriptionLimit + 1
        )
        XCTAssertEqual(Session.truncate("short", to: 48), "short")
    }

    func testASubagentWithNoDescriptionStillCounts() throws {
        let value = try session("""
        {"session_id":"s1","state":"working","title":"Something",
         "subagents":[{"id":"a","type":"general-purpose"}]}
        """)
        XCTAssertEqual(value.secondaryText, "1 agent")
    }

    /// Only `working` swaps its secondary text; the other states keep saying what they said.
    func testOtherStatesKeepTheirOwnSecondaryText() throws {
        let done = try session("""
        {"session_id":"s1","state":"done","last_message":"All green.",
         "subagents":[{"id":"a","description":"Translate module three"}]}
        """)
        XCTAssertEqual(done.secondaryText, "All green.")

        let needs = try session("""
        {"session_id":"s2","state":"needs_you","detail":"Bash: rm -rf build",
         "subagents":[{"id":"a","description":"Translate module three"}]}
        """)
        XCTAssertEqual(needs.secondaryText, "rm -rf build")

        let working = try session(#"{"session_id":"s3","state":"working","title":"Plain"}"#)
        XCTAssertEqual(working.secondaryText, "Plain", "no sub-agents changes nothing")
    }

    func testTheTooltipListsTypeModelAndDescription() throws {
        let value = try session("""
        {"session_id":"s1","state":"working","cwd":"/Users/you/Desktop/docs-site","pid":42,
         "subagents":[
           {"id":"a","type":"general-purpose","model":"sonnet","description":"Translate module three"},
           {"id":"b","type":"code-reviewer","description":"Review the sample parser"}
         ]}
        """)
        let lines = value.tooltip.components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("general-purpose · sonnet · Translate module three"))
        XCTAssertTrue(lines.contains("code-reviewer · Review the sample parser"))
        XCTAssertTrue(lines.contains("/Users/you/Desktop/docs-site"))
        XCTAssertTrue(lines.contains("pid 42"))
    }

    // MARK: - The fixtures (SPEC §9.3)

    func testTheCheckedInFixturesCoverBothSides() throws {
        let devin = try decoder.decode(Session.self, from: Data(contentsOf:
            Fixtures.sessionsDirectory
                .appendingPathComponent("claude-3b6a2c19-88de-4d15-9c30-51e0f4a7b2c8.json")))
        XCTAssertEqual(devin.host, .devin)
        XCTAssertEqual(devin.state, .working)
        XCTAssertEqual(devin.subagents.count, 2)
        XCTAssertEqual(devin.subagents.map(\.type), ["general-purpose", "code-reviewer"])
        XCTAssertEqual(devin.subagents.map(\.model), ["sonnet", "opus"])
        XCTAssertTrue(devin.secondaryText?.hasPrefix("2 agents · ") ?? false)

        let cursor = try decoder.decode(Session.self, from: Data(contentsOf:
            Fixtures.sessionsDirectory
                .appendingPathComponent("claude-ab813983-4f21-4c0e-9a17-2f5b6c8d1e00.json")))
        XCTAssertEqual(cursor.host, .cursor)
        XCTAssertTrue(cursor.subagents.isEmpty)
    }

    // MARK: - Layout: the chip must not cost a single point of row height

    func testTheChipLeavesTheRowHeightAndItsAirAlone() throws {
        _ = NSApplication.shared

        func fit<V: View>(_ view: V) -> NSSize {
            let hosting = NSHostingView(rootView: view)
            hosting.layoutSubtreeIfNeeded()
            return hosting.fittingSize
        }

        let withSubagents = try decoder.decode(Session.self, from: Data(contentsOf:
            Fixtures.sessionsDirectory
                .appendingPathComponent("claude-3b6a2c19-88de-4d15-9c30-51e0f4a7b2c8.json")))
        let row = fit(
            SessionRow(session: withSubagents, isSeen: false, onTap: {})
                .frame(width: metrics.width - 16)
        )
        XCTAssertEqual(row.height, metrics.rowHeight, accuracy: 0.5)

        // Line 1 with all three chips still has to leave 4 pt of air above and below line 2.
        let titleLine = fit(
            HStack(spacing: 6) {
                Text("docs-site").font(metrics.rowTitle)
                HostChip(host: .devin)
                SubagentChip(count: 2)
                AgentGlyph(agent: .claude)
            }
        )
        let statusLine = fit(Text("Working… · 2 agents · Translate").font(metrics.rowSecondary))
        XCTAssertLessThanOrEqual(titleLine.height + 3 + statusLine.height, metrics.rowHeight - 8)

        // The chip is exactly as tall as the host chip it sits beside, so line 1 does not grow.
        let hostChip = fit(HostChip(host: .devin))
        let subagentChip = fit(SubagentChip(count: 2))
        XCTAssertEqual(subagentChip.height, hostChip.height, accuracy: 0.5)
        XCTAssertGreaterThan(subagentChip.width, 0)

        // Zero sub-agents draws nothing at all — no chip, no gap, no width.
        XCTAssertEqual(fit(SubagentChip(count: 0)).width, 0, accuracy: 0.5)
        XCTAssertEqual(fit(SubagentChip(count: 0)).height, 0, accuracy: 0.5)
    }

    /// Header line 2 grew by `· N sub-agents` (SPEC §9.3), which is enough to lose the width
    /// fight against the alarm pill beside it. Rendered at the header's fixed 360 × 56, that
    /// stacked `2 need you` onto three lines and overflowed the header. Line 2 truncates; the
    /// pill holds its width whatever it is offered.
    func testTheHeaderAlarmPillNeverWrapsHoweverNarrowItsSlotGets() {
        _ = NSApplication.shared

        func height(_ width: CGFloat) -> CGFloat {
            let hosting = NSHostingView(rootView: NeedsYouPill(count: 2).frame(width: width))
            hosting.layoutSubtreeIfNeeded()
            return hosting.fittingSize.height
        }

        let comfortable = height(200)
        XCTAssertLessThanOrEqual(comfortable, 24, "one line of 10 pt text plus 3 pt padding")
        // Squeezed to a fifth of the width it wants, it still has to be one line.
        XCTAssertEqual(height(40), comfortable, accuracy: 0.5)
        XCTAssertEqual(height(20), comfortable, accuracy: 0.5)

        // …and the header it lives in still fits its fixed height.
        let header = NSHostingView(
            rootView: HStack(spacing: metrics.controlGap) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("11 agents").font(metrics.header).lineLimit(1)
                    Text("9 claude · 2 codex · 14 sub-agents")
                        .font(metrics.rowSecondary).lineLimit(1).truncationMode(.tail)
                }
                .layoutPriority(1)
                Spacer(minLength: metrics.controlGap)
                NeedsYouPill(count: 2)
                IconButton(symbol: "pin.fill", help: "Pin", action: {})
                IconButton(symbol: "gearshape", help: "Settings", action: {})
            }
            .padding(.horizontal, metrics.padding)
            .frame(width: metrics.width)
        )
        header.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(header.fittingSize.height, metrics.headerHeight)
    }
}
