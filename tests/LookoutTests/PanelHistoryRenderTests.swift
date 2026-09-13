import AppKit
import SwiftUI
import XCTest
@testable import Lookout

// MARK: - History, cost chip, Codex usage, wrapping presets (SPEC §17.5, §17.6, §17.7)

extension PanelRenderTests {
    /// The two ends of SPEC §14's appearance range every new render is checked at.
    private var renderAppearances: [(name: String, appearance: Appearance)] {
        [
            ("100", Appearance.standard),
            ("125", Appearance(scale: 1.25, panelWidth: 460, listMaxHeight: 480, density: .comfortable)),
        ]
    }

    /// SPEC §17.5: the History tab, populated from the checked-in fixture — a day header, both
    /// live and ended rows, at both appearances.
    func testTheHistoryTabRenders() throws {
        for (name, appearance) in renderAppearances {
            settings.appearance = appearance
            state.tab = .history
            // Explicit rather than relying on `HistoryView.onAppear`, which a bare
            // `NSHostingView` never on screen may not fire (SPEC §17.5's own lazy load is
            // exercised for real in `HistoryModelTests`).
            state.loadHistoryIfNeeded(now: Fixtures.historyNow)
            XCTAssertGreaterThan(state.historyRowCount, 0, "the fixture has rows to show")

            let size = render(
                PanelView(state: state, settings: settings, onTogglePin: {}, onOpenSettings: {}),
                named: "panel-history-\(name)"
            )
            let usedMetrics = settings.metrics
            XCTAssertEqual(size.width, usedMetrics.width, accuracy: 0.5)
            XCTAssertGreaterThan(size.height, usedMetrics.headerHeight + usedMetrics.tabsHeight)
        }
    }

    /// SPEC §17.7: the Usage tab with the Codex section on screen. The checked-in fixture is the
    /// common, degraded real-machine shape — `secondary`/`limit_name` both null — so this also
    /// proves the 5-hour bar renders alone without crashing.
    func testTheUsageTabWithACodexSectionRenders() throws {
        for (name, appearance) in renderAppearances {
            settings.appearance = appearance
            state.tab = .usage
            state.refreshCodexUsage()
            XCTAssertNotNil(state.codexUsage, "tests/fixtures/codex-usage.json must have parsed")
            XCTAssertNil(state.codexUsage?.secondary, "the fixture is the null-secondary case")

            let size = render(
                PanelView(state: state, settings: settings, onTogglePin: {}, onOpenSettings: {}),
                named: "panel-usage-codex-\(name)"
            )
            XCTAssertEqual(size.width, settings.metrics.width, accuracy: 0.5)
        }
    }

    /// SPEC §17.6: a session row with a cost chip on line 3's right side.
    func testASessionRowWithACostChipRenders() throws {
        var session = try fixture("claude-ab813983-4f21-4c0e-9a17-2f5b6c8d1e00.json")
        session.tokens = [
            "claude-sonnet-5": TokenBucket(
                inTokens: 820_000, outTokens: 210_000, cacheRead: 40_000, cacheWrite: 12_000
            ),
        ]
        let cost = try XCTUnwrap(session.cost(pricing: .standard))
        XCTAssertGreaterThan(cost, 0)

        for (name, appearance) in renderAppearances {
            settings.appearance = appearance
            let usedMetrics = settings.metrics
            let row = render(
                SessionRow(session: session, isSeen: false, pricing: .standard, onTap: {})
                    .frame(width: usedMetrics.width - 16)
                    .padding(8)
                    .background(Theme.windowBackground)
                    .environment(\.metrics, usedMetrics)
                    .environment(\.colorScheme, .dark),
                named: "row-cost-chip-\(name)"
            )
            XCTAssertGreaterThan(row.height, usedMetrics.rowHeight, "the row plus its 8 pt padding")
        }
    }

    /// SPEC §17.4 / the presets ScrollView→FlowLayout fix: five presets, enough to force a
    /// second line — the third button must never render clipped mid-word again.
    func testACardWithFivePresetsWraps() throws {
        let fivePresets = [
            AnswerPreset(text: "Go ahead", keyBinding: 1),
            AnswerPreset(text: "Skip it, continue with the next task", keyBinding: 2),
            AnswerPreset(text: "Commit what you have and stop", keyBinding: 3),
            AnswerPreset(text: "Ask me again in the terminal", keyBinding: 4),
            AnswerPreset(text: "Run the full test suite first", keyBinding: 5),
        ]
        settings.answerPresets = fivePresets
        defer { settings.answerPresets = AnswerPresetsDefaults.values }

        for (name, appearance) in renderAppearances {
            settings.appearance = appearance
            let coordinator = AttentionCoordinator(settings: settings)
            let model = AttentionCardModel(
                settings: settings, coordinator: coordinator,
                suggester: Suggester(), home: LookoutHome(root: Fixtures.home)
            )
            let session = try fixture("claude-ab813983-4f21-4c0e-9a17-2f5b6c8d1e00.json")
            coordinator.present(session)
            model.present(coordinator.current, request: nil)

            let size = render(AttentionCardView(model: model), named: "card-5-presets-\(name)")
            XCTAssertEqual(size.width, settings.metrics.cardWidth, accuracy: 0.5)
            XCTAssertLessThanOrEqual(size.height, settings.metrics.cardMaxHeight)

            // The fifth preset still fills the field whole — nothing was clipped or dropped by
            // wrapping onto a second (or third) line.
            model.use(preset: fivePresets[4])
            XCTAssertEqual(model.text, "Run the full test suite first")
        }
    }
}
