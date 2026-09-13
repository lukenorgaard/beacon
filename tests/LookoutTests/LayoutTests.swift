import SwiftUI
import XCTest
@testable import Lookout

/// The panel's height is computed, not inferred from SwiftUI, so these numbers are the contract
/// that keeps a long list from growing a window taller than the screen.
final class LayoutTests: XCTestCase {
    /// The shipped appearance — what these measurements are pinned against (SPEC §14).
    private let metrics = Theme.Metrics.standard

    func testListHeightGrowsPerRowAndThenCaps() {
        XCTAssertEqual(metrics.listHeight(rows: 0), metrics.emptyHeight)
        XCTAssertEqual(metrics.listHeight(rows: 1), metrics.rowHeight)
        XCTAssertEqual(
            metrics.listHeight(rows: 3),
            3 * metrics.rowHeight + 2 * metrics.rowGap
        )
        XCTAssertEqual(metrics.listHeight(rows: 400), metrics.listMaxHeight)
    }

    func testUsageHeightCapsToo() {
        XCTAssertEqual(metrics.usageHeight(cards: 0, extraLine: false), metrics.emptyHeight)
        XCTAssertEqual(
            metrics.usageHeight(cards: 3, extraLine: false),
            3 * metrics.usageCardHeight + 2 * metrics.usageCardGap
        )
        XCTAssertEqual(
            metrics.usageHeight(cards: 3, extraLine: true),
            3 * metrics.usageCardHeight + 2 * metrics.usageCardGap + 20
        )
        XCTAssertEqual(metrics.usageHeight(cards: 50, extraLine: true), metrics.listMaxHeight)
    }

    func testTotalHeightNeverExceedsASmallLaptopScreen() {
        let tallest = max(
            metrics.totalHeight(tab: .sessions, rows: 500, cards: 0, extraLine: false),
            metrics.totalHeight(tab: .usage, rows: 0, cards: 50, extraLine: true)
        )
        XCTAssertLessThan(tallest, 600)
        XCTAssertEqual(metrics.width, 360)
    }

    func testInteractiveElementsKeepTheirMinimumGap() {
        XCTAssertGreaterThanOrEqual(metrics.controlGap, 8)
        XCTAssertEqual(metrics.padding, 14)
        XCTAssertEqual(metrics.corner, 14)
    }

    func testEveryStateHasItsOwnAccentColour() {
        let colors = SessionState.allCases.map { Theme.color(for: $0).description }
        XCTAssertEqual(Set(colors).count, SessionState.allCases.count)
        XCTAssertNotEqual(
            Theme.color(for: .running).description,
            Theme.color(for: .working).description,
            "discovered sessions must read quieter than reported ones"
        )
    }

    func testHostChipsAndAgentGlyphs() {
        XCTAssertEqual(SessionHost.claudeDesktop.chip, "Desktop")
        XCTAssertEqual(SessionHost.iterm.chip, "iTerm")
        XCTAssertEqual(SessionHost.vscode.chip, "VS Code")
        XCTAssertEqual(SessionAgent.claude.glyph, "✦")
        XCTAssertEqual(SessionAgent.codex.glyph, "◇")
        XCTAssertFalse(SessionAgent.claude.glyphIsLetter)
        XCTAssertEqual(SessionAgent(raw: "opencode").glyph, "O")
        XCTAssertEqual(SessionAgent(raw: nil).name, "unknown")
        XCTAssertEqual(SessionAgent(raw: "  Gemini  ").name, "gemini")
    }
}
