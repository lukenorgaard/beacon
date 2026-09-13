import AppKit
import SwiftUI
import XCTest
@testable import Lookout

// MARK: - Context per session (SPEC §19.2, §19.4)

extension PanelRenderTests {
    /// SPEC §19.4: the panel's own 360 pt at both text sizes — the width the chip has to survive,
    /// not the wider panel the large preset also grows to.
    private var contextAppearances: [(name: String, appearance: Appearance)] {
        [
            ("100", Appearance(scale: 1.00, panelWidth: 360, listMaxHeight: 480, density: .standard)),
            ("125", Appearance(scale: 1.25, panelWidth: 360, listMaxHeight: 480, density: .standard)),
        ]
    }

    /// SPEC §19.2: line 2's chip, under the threshold (muted) and over it (red, with its dot),
    /// at 360 pt and both text sizes. The row keeps its fixed height either way — a chip that
    /// pushed the row taller would break the list's height maths.
    func testASessionRowWithAContextChipRendersUnderAndOverTheThreshold() throws {
        let base = try fixture("claude-ab813983-4f21-4c0e-9a17-2f5b6c8d1e00.json")
        let cases: [(name: String, tokens: Int, over: Bool)] = [
            ("under", 236_000, false),   // 24 % of Sonnet's 1M
            ("over", 620_000, true),     // 62 %
        ]

        for (name, appearance) in contextAppearances {
            settings.appearance = appearance
            let usedMetrics = settings.metrics
            for (label, tokens, over) in cases {
                var session = base
                session.contextTokens = tokens
                session.contextAt = Date().addingTimeInterval(-12)
                let gauge = try XCTUnwrap(session.contextGauge(windows: .standard))
                XCTAssertEqual(
                    gauge.isOverThreshold(settings.contextWarnFraction), over,
                    "\(label): the fixture must land on the side of the threshold it is named for"
                )

                let row = render(
                    SessionRow(
                        session: session, isSeen: false,
                        contextWindows: settings.contextWindows,
                        contextWarnFraction: settings.contextWarnFraction,
                        onTap: {}
                    )
                    .frame(width: usedMetrics.width - 2 * usedMetrics.listInset)
                    .padding(8)
                    .background(Theme.windowBackground)
                    .environment(\.metrics, usedMetrics)
                    .environment(\.colorScheme, .dark),
                    named: "row-context-\(label)-\(name)"
                )
                XCTAssertEqual(
                    row.height, usedMetrics.rowHeight + 16, accuracy: 0.5,
                    "\(label): the chip must not change the row's fixed height"
                )
            }
        }
    }

    /// SPEC §19.4: "the chip yields before the title does". A session name far longer than the
    /// row is wide still shows at least its first `contextNameFloor` characters, and the chip is
    /// either drawn whole or not at all — never clipped mid-glyph.
    func testALongSessionNameKeepsItsFirstTwelveCharactersBesideTheChip() throws {
        let longName = "Document the sample command-line tool and keep every example consistent"
        for (name, appearance) in contextAppearances {
            settings.appearance = appearance
            let usedMetrics = settings.metrics

            var session = try fixture("claude-ab813983-4f21-4c0e-9a17-2f5b6c8d1e00.json")
            session.title = longName
            session.desktopTitle = nil
            session.contextTokens = 620_000
            session.contextAt = Date().addingTimeInterval(-12)
            let shown = try XCTUnwrap(session.displayName)
            XCTAssertTrue(shown.hasPrefix(String(longName.prefix(20))))

            let gauge = try XCTUnwrap(session.contextGauge(windows: .standard))
            let over = gauge.isOverThreshold(settings.contextWarnFraction)
            XCTAssertTrue(over, "the long-name row is the red one")
            XCTAssertTrue(
                usedMetrics.contextChipFits(name: shown, chip: gauge.percentText, dot: over),
                "at 360 pt the chip and twelve characters of the name both fit — the chip stays"
            )

            // The floor itself: the kept head of the name, the gap and the chip inside the line.
            let head = String(shown.prefix(Theme.Metrics.contextNameFloor))
            let needed = usedMetrics.textWidth(head, font: usedMetrics.rowSecondaryNSFont)
                + usedMetrics.controlGap
                + usedMetrics.contextChipWidth(gauge.percentText, dot: over)
            XCTAssertLessThanOrEqual(
                needed, usedMetrics.rowTextWidth(),
                "twelve characters of the name plus the whole chip must fit line 2"
            )

            let row = render(
                SessionRow(
                    session: session, isSeen: false,
                    contextWindows: settings.contextWindows,
                    contextWarnFraction: settings.contextWarnFraction,
                    onTap: {}
                )
                .frame(width: usedMetrics.width - 2 * usedMetrics.listInset)
                .padding(8)
                .background(Theme.windowBackground)
                .environment(\.metrics, usedMetrics)
                .environment(\.colorScheme, .dark),
                named: "row-context-long-name-\(name)"
            )
            XCTAssertEqual(row.height, usedMetrics.rowHeight + 16, accuracy: 0.5)
        }
    }

    /// A whole list at 360 pt with a mixed set — one Codex row measured against its own reported
    /// window, one Claude row over the threshold, one with nothing measured at all — so the
    /// three states can be compared in one picture.
    func testAListOfRowsWithAndWithoutContextChipsRenders() throws {
        let sessions = try fixtureSessions().map { session -> Session in
            var copy = session
            switch copy.agent {
            case .codex:
                copy.contextTokens = 122_000
                copy.contextWindow = 258_400
            default:
                if copy.state == .working {
                    copy.contextTokens = 780_000
                } else if copy.state == .needsYou {
                    copy.contextTokens = 210_000
                }
            }
            copy.contextAt = Date().addingTimeInterval(-42)
            return copy
        }
        XCTAssertGreaterThan(
            sessions.filter { $0.contextTokens != nil }.count, 2, "a mixed list, not a uniform one"
        )

        for (name, appearance) in contextAppearances {
            settings.appearance = appearance
            let usedMetrics = settings.metrics
            let windows = settings.contextWindows
            let warn = settings.contextWarnFraction
            render(
                VStack(spacing: usedMetrics.rowGap) {
                    ForEach(Session.sorted(sessions)) { session in
                        SessionRow(
                            session: session, isSeen: false,
                            contextWindows: windows, contextWarnFraction: warn, onTap: {}
                        )
                    }
                }
                .padding(.horizontal, usedMetrics.listInset)
                .padding(.vertical, usedMetrics.rowGap)
                .frame(width: usedMetrics.width)
                .background(Theme.windowBackground)
                .environment(\.metrics, usedMetrics)
                .environment(\.colorScheme, .dark),
                named: "rows-context-\(name)"
            )

            for session in sessions {
                let row = layout(
                    SessionRow(
                        session: session, isSeen: false,
                        contextWindows: settings.contextWindows,
                        contextWarnFraction: settings.contextWarnFraction,
                        onTap: {}
                    )
                    .frame(width: usedMetrics.width - 2 * usedMetrics.listInset)
                    .environment(\.metrics, usedMetrics)
                )
                XCTAssertEqual(row.height, usedMetrics.rowHeight, accuracy: 0.5, session.project)
            }
        }
    }

    /// SPEC §19.2/§19.4: the narrow-panel end of the rule — the chip is dropped outright, and
    /// the session name gets the whole line rather than being cut down to make room for it.
    func testTheChipIsDroppedRatherThanClippedOnTheNarrowestPanel() throws {
        settings.appearance = Appearance(
            scale: 1.40, panelWidth: 320, listMaxHeight: 480, density: .compact
        )
        let usedMetrics = settings.metrics

        var session = try fixture("claude-ab813983-4f21-4c0e-9a17-2f5b6c8d1e00.json")
        session.title = "Document the sample command-line tool and keep every example consistent"
        session.desktopTitle = nil
        session.contextTokens = 620_000
        session.contextAt = Date().addingTimeInterval(-12)
        let gauge = try XCTUnwrap(session.contextGauge(windows: .standard))
        XCTAssertFalse(
            usedMetrics.contextChipFits(
                name: session.displayName, chip: gauge.percentText, dot: true
            ),
            "320 pt at 140 % has no room for both — the chip is the half that goes"
        )

        let row = render(
            SessionRow(
                session: session, isSeen: false,
                contextWindows: settings.contextWindows,
                contextWarnFraction: settings.contextWarnFraction,
                onTap: {}
            )
            .frame(width: usedMetrics.width - 2 * usedMetrics.listInset)
            .padding(8)
            .background(Theme.windowBackground)
            .environment(\.metrics, usedMetrics)
            .environment(\.colorScheme, .dark),
            named: "row-context-dropped-320"
        )
        XCTAssertEqual(row.height, usedMetrics.rowHeight + 16, accuracy: 0.5)
    }

    /// SPEC §19.2/§19.3: the two new Settings controls — the threshold stepper and the window
    /// table — laid out inside the settings window, with nothing overlapping the pricing rows
    /// they sit under.
    func testTheSettingsUsageSectionRendersWithTheContextWindowTable() {
        settings.settingsTab = .general
        let view = SettingsView(
            settings: settings, usage: state.usage, hotKeys: hotKeys, home: temporaryHome
        )
        // The whole General form, unconstrained: the window itself scrolls, and the section
        // these controls live in is well below its 600 pt fold.
        let size = render(
            view.tabForm
                .frame(width: SettingsView.formWidth)
                .background(Theme.windowBackground),
            named: "settings-context-windows"
        )
        XCTAssertEqual(size.width, SettingsView.formWidth, accuracy: 1)
        XCTAssertEqual(settings.contextWarnPercent, 40)
        XCTAssertEqual(ContextWindows.orderedModelKeys.count, 6, "six editable rows")
    }
}
