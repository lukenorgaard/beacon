import AppKit
import SwiftUI
import XCTest
@testable import Lookout

// MARK: - Appearance (SPEC §14)

extension PanelRenderTests {
    /// SPEC §14's two ends of the range, laid out for real: the panel at the **Large** preset
    /// and at the smallest appearance there is. Every fixed-height thing — row, header, usage
    /// card — has to hold its content at both, or the scale is a promise the panel cannot keep.
    func testThePanelHoldsTogetherAtTheLargeAppearance() throws {
        try assertEverythingFits(
            Appearance(scale: 1.25, panelWidth: 460, listMaxHeight: 480, density: .comfortable),
            named: "scale-125-w460"
        )
    }

    func testThePanelHoldsTogetherAtTheSmallestAppearance() throws {
        try assertEverythingFits(
            Appearance(scale: 0.85, panelWidth: 320, listMaxHeight: 320, density: .compact),
            named: "scale-085-w320"
        )
    }

    /// SPEC §17.3: the filter chip row wraps to a second line rather than truncating a label or
    /// running past the panel's edge, at both ends of SPEC §14's scale range.
    func testTheFilterRowWrapsWithoutTruncationAtTheSmallestAppearance() throws {
        try assertFilterRowWraps(
            Appearance(scale: 0.85, panelWidth: 320, listMaxHeight: 320, density: .compact),
            named: "filter-row-085-w320"
        )
    }

    func testTheFilterRowWrapsWithoutTruncationAtTheLargeAppearance() throws {
        try assertFilterRowWraps(
            Appearance(scale: 1.25, panelWidth: 460, listMaxHeight: 480, density: .comfortable),
            named: "filter-row-125-w460"
        )
    }

    /// Renders the row alone at the panel's full width and proves every chip kept its whole
    /// label (nothing is shorter than its own unconstrained size — `fixedSize` never shrinks,
    /// `FlowLayout` only ever moves a chip that does not fit to the next line) and that the row
    /// itself is tall enough to be more than one line, which is what "wrapped" looks like from
    /// the outside.
    private func assertFilterRowWraps(_ appearance: Appearance, named name: String) throws {
        settings.appearance = appearance
        let metrics = settings.metrics
        let width = metrics.width - 2 * metrics.padding

        let row = render(
            SessionFilterRow(state: state, settings: settings).frame(width: width),
            named: name
        )
        XCTAssertLessThanOrEqual(row.width, width, "the row never runs past the panel's edge")

        let singleChip = layout(FilterChip(title: "Needs you", count: 3, selected: false) {})
        XCTAssertGreaterThan(
            row.height, singleChip.height,
            "six items at this width must wrap to more than one line, not squeeze onto one"
        )

        // Every chip label at its natural, unconstrained width — proof `FlowLayout` wrapped
        // rather than truncated: nothing here is `.lineLimit`-clipped or narrower than it wants.
        for filter in StateFilter.allCases {
            let chip = layout(FilterChip(title: filter.label, count: 0, selected: false) {})
            XCTAssertGreaterThan(chip.width, 0)
            XCTAssertLessThanOrEqual(
                chip.width, width, "\(filter.label): even alone it must fit the panel's width"
            )
        }
    }

    /// Renders the panel, the rows and the card at one appearance (a PNG each under
    /// `LOOKOUT_RENDER_DIR`) and asserts nothing overflows the height it was given.
    private func assertEverythingFits(_ appearance: Appearance, named name: String) throws {
        settings.appearance = appearance
        let metrics = settings.metrics
        XCTAssertEqual(metrics.width, appearance.panelWidth)

        // 1. The panel window itself.
        let panel = render(
            PanelView(state: state, settings: settings, onTogglePin: {}, onOpenSettings: {}),
            named: "panel-\(name)"
        )
        XCTAssertEqual(panel.width, metrics.width, accuracy: 0.5)
        XCTAssertGreaterThan(panel.height, metrics.headerHeight + metrics.tabsHeight)
        // SPEC §17.3: the filter row's own height is measured, not part of the metrics formula
        // (it wraps, so there is no fixed number for it) — `PanelController.contentHeight()`
        // adds exactly this allowance, and the assertion below has to match it.
        let filterAllowance = filterRowAllowance(metrics)
        XCTAssertLessThanOrEqual(
            panel.height,
            metrics.totalHeight(
                tab: .sessions, rows: state.visibleSessions.count, cards: 0, extraLine: false
            ) + filterAllowance,
            "the panel laid out taller than the window its own height math asks for"
        )

        // 2. Every fixture row, at the fixed height for this density and scale.
        let sessions = try fixtureSessions()
        let rows = render(
            VStack(spacing: metrics.rowGap) {
                ForEach(sessions) { session in
                    SessionRow(session: session, isSeen: false, onTap: {})
                }
            }
            .padding(.horizontal, metrics.listInset)
            .padding(.vertical, metrics.rowGap)
            .frame(width: metrics.width)
            .background(Theme.windowBackground)
            .environment(\.metrics, metrics)
            .environment(\.colorScheme, .dark),
            named: "rows-\(name)"
        )
        XCTAssertEqual(rows.width, metrics.width, accuracy: 0.5)

        let air = 8 * metrics.scale
        for session in sessions {
            let row = layout(
                SessionRow(session: session, isSeen: false, onTap: {})
                    .frame(width: metrics.width - 2 * metrics.listInset)
                    .environment(\.metrics, metrics)
            )
            XCTAssertEqual(row.height, metrics.rowHeight, accuracy: 0.5, session.project)
            XCTAssertLessThanOrEqual(
                rowContentHeight(session, metrics), metrics.rowHeight - air,
                "\(session.project): its two lines do not fit inside the row at this appearance"
            )
        }

        // 3. The header's two rows inside the fixed header height.
        let headline = layout(
            HStack(spacing: metrics.controlGap) {
                Circle().frame(width: metrics.scaled(7), height: metrics.scaled(7))
                Text("12 agents").font(metrics.header)
                Spacer(minLength: metrics.controlGap)
                NeedsYouPill(count: 3)
                IconButton(symbol: "pin.fill", help: "Pin", action: {})
                IconButton(symbol: "gearshape", help: "Settings", action: {})
            }
            .padding(.horizontal, metrics.padding)
            .frame(width: metrics.width)
            .environment(\.metrics, metrics)
        )
        let detail = layout(
            Text("9 claude · 2 codex · 27 sub-agents").font(metrics.rowSecondary)
        )
        XCTAssertLessThanOrEqual(
            headline.height + metrics.scaled(3) + detail.height, metrics.headerHeight,
            "the header's two rows must fit the height the window reserves for them"
        )

        // 4. The tabs row, and the usage card's three lines.
        let visibleTabs = PanelTab.visibleCases(
            showHistory: settings.showHistoryTab, showSentinel: settings.sentinelEnabled
        )
        let tabLabel: (PanelTab) -> String = { $0 == .agents ? "Agents · 27" : $0.label }
        let tabs = layout(
            HStack(spacing: metrics.controlGap) {
                SegmentedTabs(selection: .constant(.agents), tabs: visibleTabs, label: tabLabel)
                Spacer(minLength: metrics.controlGap)
                if metrics.tabStripFitsSummary(
                    labels: visibleTabs.map(tabLabel), summary: "10% · 8%"
                ) {
                    Text("10% · 8%").font(metrics.numeral)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, metrics.padding)
            .frame(width: metrics.width)
            .environment(\.metrics, metrics)
        )
        XCTAssertLessThanOrEqual(tabs.height, metrics.tabsHeight)
        // SPEC §18.3: the four labels themselves fit, at both ends of the appearance range.
        XCTAssertTrue(
            metrics.tabStripFitsPanel(labels: visibleTabs.map(tabLabel)),
            "the strip has to fit without scrolling at \(appearance.scale)×/\(appearance.panelWidth) pt"
        )

        let limit = UsageLimit(
            kind: "weekly_scoped", group: "weekly", percent: 83, severity: "normal",
            resetsAt: Date().addingTimeInterval(9_660), modelName: "Fable", isActive: true
        )
        let card = layout(
            UsageCard(limit: limit)
                .frame(width: metrics.width - 2 * metrics.padding)
                .environment(\.metrics, metrics)
        )
        XCTAssertEqual(card.height, metrics.usageCardHeight, accuracy: 0.5)
        let labelLine = layout(
            HStack {
                Text("Session (5h)").font(metrics.rowTitle)
                Text("83%").font(metrics.bigNumeral)
            }
        )
        let resetLine = layout(Text("resets in 2h 41m").font(metrics.rowSecondary))
        XCTAssertLessThanOrEqual(
            labelLine.height + metrics.scaled(6) + metrics.barHeight + metrics.scaled(6)
                + resetLine.height + 2 * metrics.rowInset,
            metrics.usageCardHeight,
            "the usage card's three lines must fit its fixed height at this appearance"
        )

        // 5. The card follows the panel's width (SPEC §14) and still fits its cap.
        let coordinator = AttentionCoordinator(settings: settings)
        let model = AttentionCardModel(
            settings: settings, coordinator: coordinator,
            suggester: Suggester(), home: LookoutHome(root: Fixtures.home)
        )
        let session = try fixture("claude-ab813983-4f21-4c0e-9a17-2f5b6c8d1e00.json")
        coordinator.present(session)
        model.present(coordinator.current, request: nil)
        let cardSize = render(AttentionCardView(model: model), named: "card-\(name)")
        XCTAssertEqual(cardSize.width, metrics.cardWidth, accuracy: 0.5)
        XCTAssertEqual(cardSize.width, max(380, appearance.panelWidth + 20), accuracy: 0.5)
        XCTAssertLessThanOrEqual(cardSize.height, metrics.cardMaxHeight)

        // 6. The setup window scales with the same value.
        let installer = HookInstaller(resources: nil, home: Fixtures.root)
        let setup = render(
            SetupView(
                installer: installer, companion: companionInstaller(), settings: settings,
                onDone: {}
            ),
            named: "setup-\(name)"
        )
        XCTAssertEqual(setup.width, metrics.setupWidth, accuracy: 0.5)
        XCTAssertLessThan(
            setup.height, 900,
            "the setup window has to stay on a 900 pt laptop screen at every text size"
        )
    }

    /// SPEC §15.4: the rename panel, laid out for real. 320 pt wide, its five rows stacked, and
    /// short enough that it never covers the list it opened next to.
    func testTheRenamePanelLaysOutAt320Points() throws {
        var session = try fixtureSessions()[0]
        session.host = .claudeDesktop
        let model = RenameModel(
            names: SessionNames(home: temporaryHome), settings: settings, home: temporaryHome
        )
        model.begin(session)

        let size = render(RenameView(model: model), named: "rename")
        XCTAssertEqual(size.width, metrics.renameWidth, accuracy: 0.5)
        XCTAssertEqual(metrics.renameWidth, 320, accuracy: 0.5)
        // Header, field, checkbox and buttons — never taller than the panel it docks beside.
        XCTAssertGreaterThan(size.height, metrics.renameFieldHeight * 3)
        XCTAssertLessThan(size.height, 260)

        // SPEC §15.5's checkbox is gone for Codex, so the panel gets shorter, not overlapped.
        var codex = session
        codex.agent = .codex
        model.begin(codex)
        let shorter = render(RenameView(model: model), named: "rename-codex")
        XCTAssertEqual(shorter.width, metrics.renameWidth, accuracy: 0.5)
        XCTAssertLessThan(shorter.height, size.height)
    }

    /// SPEC §15.4: a renamed row shows the name on line 2 and is still exactly one row tall —
    /// a custom name may be long, and the row height is fixed.
    func testARenamedRowKeepsItsHeightAndItsThreeLines() throws {
        let store = SessionNames(home: temporaryHome)
        let sessions = try fixtureSessions()
        for session in sessions {
            store.setName(
                "Nimbus fase 0 — en meget lang omdøbning der aldrig får lov at vokse rækken",
                for: session.sessionID
            )
        }
        let renamed = store.decorate(sessions)
        XCTAssertEqual(renamed.compactMap(\.customName).count, sessions.count)

        render(
            VStack(spacing: metrics.rowGap) {
                ForEach(renamed) { session in
                    SessionRow(session: session, isSeen: false, onTap: {})
                }
            }
            .padding(.horizontal, metrics.listInset)
            .padding(.vertical, metrics.rowGap)
            .frame(width: metrics.width)
            .background(Theme.windowBackground)
            .environment(\.metrics, metrics)
            .environment(\.colorScheme, .dark),
            named: "rows-renamed"
        )

        let air = 8 * metrics.scale
        for session in renamed {
            let row = layout(
                SessionRow(session: session, isSeen: false, onTap: {})
                    .frame(width: metrics.width - 2 * metrics.listInset)
                    .environment(\.metrics, metrics)
            )
            XCTAssertEqual(row.height, metrics.rowHeight, accuracy: 0.5, session.project)
            XCTAssertLessThanOrEqual(
                rowContentHeight(session, metrics), metrics.rowHeight - air,
                "\(session.project): a renamed row's three lines do not fit"
            )
        }
    }

    /// A row's own three lines (SPEC §15.3), measured unconstrained — the row frame would
    /// happily clip an overflow, so the content has to be measured on its own to prove there is
    /// none.
    private func rowContentHeight(_ session: Session, _ metrics: Theme.Metrics) -> CGFloat {
        let line1 = layout(
            HStack(spacing: metrics.scaled(6)) {
                Text(session.project).font(metrics.rowTitle)
                HostChip(host: session.host)
                SubagentChip(count: session.subagents.count)
                if let chip = session.modelChip {
                    ModelChip(text: chip, color: Theme.familyClaude, help: "")
                } else {
                    AgentGlyph(agent: session.agent)
                }
            }
            .environment(\.metrics, metrics)
        )
        let line2 = layout(
            Text(session.displayName ?? " ").font(metrics.rowSecondary)
                .environment(\.metrics, metrics)
        )
        let line3 = layout(
            HStack(spacing: metrics.scaled(5)) {
                Text(session.statusLabel).font(metrics.rowSecondary)
                Text(session.rowDetail ?? " ").font(metrics.rowSecondary)
            }
            .environment(\.metrics, metrics)
        )
        return line1.height + metrics.scaled(3) + line2.height
            + metrics.scaled(3) + line3.height
    }

    /// Mirrors `PanelController.filterRowHeight()` exactly: the same view, the same padding,
    /// the same explicit width — so this can never silently drift from what the window is
    /// really sized from.
    private func filterRowAllowance(_ metrics: Theme.Metrics) -> CGFloat {
        let height = layout(
            SessionFilterRow(state: state, settings: settings)
                .padding(.horizontal, metrics.padding)
                .padding(.top, metrics.scaled(2))
                .padding(.bottom, metrics.scaled(6))
                .frame(width: metrics.width)
        ).height
        return height + PanelController.filterRowMeasurementMargin
    }

    func fixture(_ name: String) throws -> Session {
        try JSONDecoder().decode(
            Session.self,
            from: Data(contentsOf: Fixtures.sessionsDirectory.appendingPathComponent(name))
        )
    }

    func fixtureSessions() throws -> [Session] {
        let names = try FileManager.default
            .contentsOfDirectory(atPath: Fixtures.sessionsDirectory.path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
        return try names.map { try fixture($0) }
    }
}
