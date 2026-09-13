import AppKit
import SwiftUI
import XCTest
@testable import Lookout

extension PanelRenderTests {
    /// Rows and cards have fixed heights, so the real question is whether their content fits
    /// inside them. Measure the pieces unconstrained and check there is air left over.
    func testRowContentFitsInsideTheFixedRowHeightWithRoomToSpare() {
        let titleLine = layout(
            HStack(spacing: 6) {
                Text("daily-notes").font(metrics.rowTitle)
                HostChip(host: .cursor)
                AgentGlyph(agent: .claude)
            }
        )
        // SPEC §15.3: the session's own name is a line of its own between the two.
        let nameLine = layout(Text("Fix the login redirect loop").font(metrics.rowSecondary))
        let statusLine = layout(
            Text("Needs permission · Bash").font(metrics.rowSecondary)
        )
        let content = titleLine.height + 3 + nameLine.height + 3 + statusLine.height
        XCTAssertLessThanOrEqual(
            content, metrics.rowHeight - 8,
            "a row must keep at least 4 pt of air above and below its three lines"
        )
    }

    /// SPEC §9.5: the model chip replaces the agent glyph, so it must not be taller than the
    /// glyph was — the row height is fixed and line 1 has to keep fitting inside it.
    func testTheModelChipIsNoTallerThanTheGlyphItReplaces() {
        let chip = layout(
            ModelChip(text: "Llama · Local", color: Theme.familyLocal, help: "llama-3.3-70b")
        )
        let host = layout(HostChip(host: .cursor))
        XCTAssertEqual(chip.height, host.height, accuracy: 0.5, "one rhythm on line 1")

        let titleLine = layout(
            HStack(spacing: 6) {
                Text("docs-site").font(metrics.rowTitle)
                HostChip(host: .devin)
                SubagentChip(count: 2)
                ModelChip(text: "Llama · Local", color: Theme.familyLocal, help: "llama-3.3-70b")
            }
        )
        let nameLine = layout(
            Text("Document the sample command-line tool").font(metrics.rowSecondary)
        )
        let statusLine = layout(Text("Working…").font(metrics.rowSecondary))
        XCTAssertLessThanOrEqual(
            titleLine.height + 3 + nameLine.height + 3 + statusLine.height,
            metrics.rowHeight - 8,
            "a row with a model chip keeps at least 4 pt of air above and below"
        )
    }

    /// Every fixture row lays out at exactly the fixed height, tint and chip included.
    func testEveryFixtureRowKeepsTheFixedRowHeight() throws {
        let names = try FileManager.default
            .contentsOfDirectory(atPath: Fixtures.sessionsDirectory.path)
            .filter { $0.hasSuffix(".json") }
        for name in names {
            let session = try JSONDecoder().decode(
                Session.self,
                from: Data(contentsOf: Fixtures.sessionsDirectory.appendingPathComponent(name))
            )
            let row = layout(
                SessionRow(session: session, isSeen: false, onTap: {})
                    .frame(width: metrics.width - 16)
            )
            XCTAssertEqual(row.height, metrics.rowHeight, accuracy: 0.5, name)
        }
    }

    /// The legend is one row of five swatches (SPEC §9.5); it has to fit the settings form's
    /// content width, or the last label is silently clipped.
    func testTheFamilyLegendFitsOnOneRowInTheSettingsForm() {
        let legend = layout(FamilyLegend())
        XCTAssertLessThanOrEqual(
            legend.width, 360,
            "460 pt form minus the grouped section's insets — the five labels must fit"
        )
        XCTAssertLessThan(legend.height, 24, "one row, not two")
    }

    func testUsageCardContentFitsInsideTheFixedCardHeight() {
        let labelLine = layout(
            HStack { Text("Session (5h)").font(metrics.rowTitle); Text("83%").font(metrics.bigNumeral) }
        )
        let resetLine = layout(Text("resets in 2h 41m").font(metrics.rowSecondary))
        let content = labelLine.height + 6 + 6 + 6 + resetLine.height + 20  // + 10 pt padding twice
        XCTAssertLessThanOrEqual(content, metrics.usageCardHeight)
    }
}
