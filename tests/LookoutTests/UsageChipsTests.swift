import XCTest
@testable import Lookout

/// The header chips: the text the fit decisions measure must be the text that is drawn, the
/// Codex chip must be recognisable as Codex, and the glow must follow the loudest number.
final class UsageChipsTests: XCTestCase {

    private func claude(session: Double?, weekly: Double?) -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        var limits: [UsageLimit] = []
        if let session {
            limits.append(UsageLimit(
                kind: "session", group: "", percent: session, severity: "normal",
                resetsAt: nil, modelName: nil, isActive: true
            ))
        }
        if let weekly {
            limits.append(UsageLimit(
                kind: "weekly_all", group: "", percent: weekly, severity: "normal",
                resetsAt: nil, modelName: nil, isActive: true
            ))
        }
        snapshot.limits = limits
        return snapshot
    }

    private func codex(primary: Double?, secondary: Double?) -> CodexUsageSnapshot {
        var snapshot = CodexUsageSnapshot()
        if let primary {
            var window = CodexUsageWindow()
            window.usedPercent = primary
            snapshot.primary = window
        }
        if let secondary {
            var window = CodexUsageWindow()
            window.usedPercent = secondary
            snapshot.secondary = window
        }
        return snapshot
    }

    func testClaudeTextIsSessionThenWeekly() {
        XCTAssertEqual(UsageChips.claudeText(claude(session: 69.4, weekly: 17)), "69% · 17%")
        XCTAssertEqual(UsageChips.claudeText(claude(session: nil, weekly: 17)), "17%")
        XCTAssertNil(UsageChips.claudeText(claude(session: nil, weekly: nil)))
    }

    /// The glyph is part of the measured text on purpose: what is measured is what is drawn.
    func testCodexTextCarriesTheCodexGlyph() {
        XCTAssertEqual(UsageChips.codexText(codex(primary: 1, secondary: 64)), "◇ 1% · 64%")
        XCTAssertEqual(UsageChips.codexText(codex(primary: 1, secondary: nil)), "◇ 1%")
        XCTAssertNil(UsageChips.codexText(codex(primary: nil, secondary: nil)))
    }

    func testTheGlowFollowsTheLoudestNumber() {
        XCTAssertEqual(UsageChips.glow(for: [12, 40]), .ok)
        XCTAssertEqual(UsageChips.glow(for: [12, 80]), .warn)
        XCTAssertEqual(UsageChips.glow(for: [95, 10]), .critical)
        XCTAssertEqual(UsageChips.glow(for: []), .ok)
    }

    /// Two chips are wider than one, and the width the strip is asked to fit is the chips',
    /// not a bare string's — a chip has padding and an outline a string does not.
    func testChipWidthIncludesPaddingAndGrowsWithASecondChip() {
        let metrics = Theme.Metrics.standard
        let one = metrics.usageChipsWidth(texts: ["69% · 17%"])
        let bare = metrics.textWidth("69% · 17%", font: metrics.numeralNSFont)
        XCTAssertGreaterThan(one, bare)
        XCTAssertEqual(one, bare + 2 * metrics.usageChipInset, accuracy: 0.5)
        let two = metrics.usageChipsWidth(texts: ["69% · 17%", "◇ 1% · 64%"])
        XCTAssertGreaterThan(two, one + metrics.controlGap)
        XCTAssertEqual(metrics.usageChipsWidth(texts: []), 0)
    }
}
