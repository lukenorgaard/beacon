import AppKit
import SwiftUI
import XCTest
@testable import Lookout

/// A headless smoke test for the SwiftUI hierarchy: it lays the panel out for real, so a
/// malformed view tree fails here instead of at the first launch.
final class PanelRenderTests: XCTestCase {
    /// Whatever appearance the test set — the default one unless it says otherwise.
    var metrics: Theme.Metrics { settings.metrics }

    private var suiteName = ""
    var settings: Lookout.Settings!
    var state: AppState!
    /// SPEC §17.2: `SettingsView` needs one to show its recorder rows. Constructing it never
    /// touches Carbon — only `.start()` registers anything, and these tests never call it.
    var hotKeys: HotKeyCenter { HotKeyCenter(settings: settings) }
    /// Settings writes `suggest-prompt.md` on first use (SPEC §13.2) — never into the checked-in
    /// fixtures, and never into the real `~/.lookout`.
    var temporaryHome = LookoutHome(root: URL(fileURLWithPath: NSTemporaryDirectory()))

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        suiteName = "io.github.lukenorgaard.beacon.tests.\(UUID().uuidString)"
        temporaryHome = LookoutHome(
            root: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("lookout-render-\(UUID().uuidString)")
        )
        let defaults = UserDefaults(suiteName: suiteName)!
        settings = Lookout.Settings(defaults: defaults)
        state = AppState(
            settings: settings,
            store: SessionStore(home: Fixtures.home),
            usage: UsageClient(),
            // Never `~/.lookout`: a render test must not be able to write a real answer.
            home: LookoutHome(root: Fixtures.home)
        )
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: temporaryHome.root)
        state = nil
        settings = nil
        super.tearDown()
    }

    /// SPEC §16.3: a companion installer that looks at a directory with no editors in it and a
    /// stub channel — a render test must never probe /Applications or a live companion.
    func companionInstaller() -> CompanionInstaller {
        CompanionInstaller(
            resources: nil,
            applications: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("lookout-no-apps"),
            companion: StubCompanion()
        )
    }

    func layout<V: View>(_ view: V) -> NSSize {
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize
    }

    /// Lays a view out at its fitting size and, when `LOOKOUT_RENDER_DIR` points somewhere,
    /// writes a PNG of it there. That is how a window is eyeballed without launching the app.
    @discardableResult
    func render<V: View>(_ view: V, named name: String) -> NSSize {
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        guard let directory = ProcessInfo.processInfo.environment["LOOKOUT_RENDER_DIR"],
              let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
        else { return size }

        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? representation.representation(using: .png, properties: [:])?.write(to: url)
        return size
    }

    func testPanelLaysOutAtTheDesignWidth() {
        let size = render(
            PanelView(state: state, settings: settings, onTogglePin: {}, onOpenSettings: {}),
            named: "panel-sessions"
        )
        XCTAssertEqual(size.width, metrics.width, accuracy: 0.5)
        XCTAssertGreaterThan(size.height, metrics.headerHeight + metrics.tabsHeight)
    }

    /// History tab behind a switch (default off): the strip lays out with three segments, not
    /// four, and nothing about the panel breaks.
    func testThePanelLaysOutWithTheHistoryTabHiddenByDefault() {
        XCTAssertFalse(settings.showHistoryTab, "off by default — the owner: history is irrelevant")
        let size = render(
            PanelView(state: state, settings: settings, onTogglePin: {}, onOpenSettings: {}),
            named: "panel-no-history-tab"
        )
        XCTAssertEqual(size.width, metrics.width, accuracy: 0.5)

        let tabs = layout(
            SegmentedTabs(
                selection: .constant(.sessions),
                tabs: PanelTab.visibleCases(showHistory: settings.showHistoryTab)
            )
            .frame(width: metrics.width)
        )
        XCTAssertLessThanOrEqual(tabs.height, metrics.tabsHeight)
    }

    /// SPEC §10.2. The six rows are a plain vertical stack, so the only thing that can go wrong
    /// in layout is the width — and a row whose text squeezed its button off the card.
    func testSetupWindowLaysOutWithEveryRowPresent() {
        let installer = HookInstaller(resources: nil, home: Fixtures.root)
        installer.apply(HookInstaller.Snapshot(
            claude: .installedElsewhere("/Users/you/Desktop/Lookout/hooks/lookout-report.py"),
            codex: .notInstalled,
            codexPresent: true
        ))
        let size = render(
            SetupView(
                installer: installer, companion: companionInstaller(), settings: settings,
                onDone: {}
            ),
            named: "setup"
        )
        XCTAssertEqual(size.width, metrics.setupWidth, accuracy: 0.5)
        // Header, six cards and a footer: comfortably taller than the panel, never off-screen.
        XCTAssertGreaterThan(size.height, 420)
        XCTAssertLessThan(size.height, 900)
    }

    /// SPEC §12.3: the third tab, with a row per live sub-agent.
    func testAgentsTabLaysOut() {
        state.tab = .agents
        let size = render(
            PanelView(state: state, settings: settings, onTogglePin: {}, onOpenSettings: {}),
            named: "panel-agents"
        )
        XCTAssertEqual(size.width, metrics.width, accuracy: 0.5)
        XCTAssertGreaterThan(size.height, metrics.headerHeight + metrics.tabsHeight)

        // The strip as the panel actually shows it (SPEC §18.3: four tabs, and the usage
        // summary only when there is room for it) still fits one row of the panel's width.
        let visible = PanelTab.visibleCases(
            showHistory: settings.showHistoryTab, showSentinel: settings.sentinelEnabled
        )
        let label: (PanelTab) -> String = { $0 == .agents ? "Agents · 27" : $0.label }
        let tabs = layout(
            HStack(spacing: metrics.controlGap) {
                SegmentedTabs(selection: .constant(.agents), tabs: visible, label: label)
                Spacer(minLength: metrics.controlGap)
                if metrics.tabStripFitsSummary(
                    labels: visible.map(label), summary: "10% · 8%"
                ) {
                    Text("10% · 8%").font(metrics.numeral)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, metrics.padding)
            .frame(width: metrics.width)
        )
        XCTAssertLessThanOrEqual(tabs.height, metrics.tabsHeight)
    }

    /// SPEC §11.4: the card as it is actually drawn, at the fixed 380 pt.
    func testAttentionCardRenders() throws {
        let coordinator = AttentionCoordinator(settings: settings)
        let model = AttentionCardModel(
            settings: settings, coordinator: coordinator,
            suggester: Suggester(), home: LookoutHome(root: Fixtures.home)
        )
        let session = try XCTUnwrap(
            state.store.sessions.first ?? JSONDecoder().decode(
                Session.self,
                from: Data(contentsOf: Fixtures.sessionsDirectory.appendingPathComponent(
                    "claude-ab813983-4f21-4c0e-9a17-2f5b6c8d1e00.json"
                ))
            )
        )
        coordinator.present(session)
        let request = AttentionRequest.decode(
            try Data(contentsOf: Fixtures.requestsDirectory.appendingPathComponent(
                "claude-ab813983-4f21-4c0e-9a17-2f5b6c8d1e00-3f9c1a7e.json"
            )),
            name: "claude-ab813983-4f21-4c0e-9a17-2f5b6c8d1e00-3f9c1a7e"
        )
        model.present(coordinator.current, request: request)

        let size = render(AttentionCardView(model: model), named: "attention-card")
        XCTAssertEqual(size.width, metrics.cardWidth, accuracy: 0.5)
        XCTAssertLessThanOrEqual(size.height, metrics.cardMaxHeight)
    }

    /// SPEC §17.4: a preset row above the reply field, small buttons that never crowd
    /// Send/Copy & go/Ignore below them — the card still fits its width and height cap.
    func testAttentionCardRendersWithPresets() throws {
        let coordinator = AttentionCoordinator(settings: settings)
        let model = AttentionCardModel(
            settings: settings, coordinator: coordinator,
            suggester: Suggester(), home: LookoutHome(root: Fixtures.home)
        )
        let session = try fixture("claude-ab813983-4f21-4c0e-9a17-2f5b6c8d1e00.json")
        coordinator.present(session)
        model.present(coordinator.current, request: nil)

        XCTAssertEqual(settings.answerPresets.count, 4, "the SPEC §17.4 defaults are on by default")
        let size = render(AttentionCardView(model: model), named: "attention-card-presets")
        XCTAssertEqual(size.width, metrics.cardWidth, accuracy: 0.5)
        XCTAssertLessThanOrEqual(size.height, metrics.cardMaxHeight)

        // A click fills the field and never sends (also covered without a window in
        // AnswerPresetsTests; this proves the button that does it actually lays out).
        let preset = settings.answerPresets[0]
        model.use(preset: preset)
        XCTAssertEqual(model.text, preset.text)

        // No presets at all: the row simply is not there, nothing else moves to fill the gap.
        settings.answerPresets = []
        let withoutPresets = layout(AttentionCardView(model: model))
        XCTAssertLessThan(withoutPresets.height, size.height)
    }

    func testUsageTabLaysOut() {
        state.tab = .usage
        let size = layout(
            PanelView(state: state, settings: settings, onTogglePin: {}, onOpenSettings: {})
        )
        XCTAssertEqual(size.width, metrics.width, accuracy: 0.5)
    }

    func testARowAndAUsageCardLayOutWithinTheirFixedHeights() throws {
        let session = try JSONDecoder().decode(
            Session.self,
            from: Data(contentsOf: Fixtures.sessionsDirectory.appendingPathComponent(
                "claude-ab813983-4f21-4c0e-9a17-2f5b6c8d1e00.json"
            ))
        )
        let row = layout(
            SessionRow(session: session, isSeen: false, onTap: {})
                .frame(width: metrics.width - 16)
        )
        XCTAssertEqual(row.height, metrics.rowHeight, accuracy: 0.5)

        let limit = UsageLimit(
            kind: "weekly_scoped", group: "weekly", percent: 83, severity: "normal",
            resetsAt: Date().addingTimeInterval(9_660), modelName: "Fable", isActive: true
        )
        let card = layout(UsageCard(limit: limit).frame(width: metrics.width - 28))
        XCTAssertEqual(card.height, metrics.usageCardHeight, accuracy: 0.5)
    }

    func testSettingsViewLaysOut() {
        let size = render(
            SettingsView(settings: settings, usage: state.usage, hotKeys: hotKeys, home: temporaryHome),
            named: "settings-general"
        )
        XCTAssertEqual(size.width, SettingsView.formWidth, accuracy: 1)
        XCTAssertGreaterThan(size.height, 200)
        XCTAssertLessThanOrEqual(size.height, SettingsView.maxContentHeight)
    }

    /// SPEC §15.2: four tabs, 460 pt wide, never taller than 600 — a tab whose form needs more
    /// than that scrolls instead of growing the window off the screen.
    func testEverySettingsTabFitsTheWindowOrScrolls() {
        settings.suggestionSource = .claude
        XCTAssertEqual(SettingsView.formWidth, 460)
        XCTAssertEqual(SettingsView.maxContentHeight, 600)

        // The four segments, side by side, inside the window's width. (A headless PNG only
        // draws the selected segment, so the tab bar is checked by measurement, not by eye.)
        let tabs = layout(
            Picker("Section", selection: .constant(SettingsTab.general)) {
                ForEach(SettingsTab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        )
        let oneTab = layout(
            Picker("Section", selection: .constant(SettingsTab.general)) {
                Text(SettingsTab.general.label).tag(SettingsTab.general)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        )
        XCTAssertGreaterThan(tabs.width, 3 * oneTab.width, "five segments, not one")
        // SPEC §18.5 adds a fifth segment, and the picker's *ideal* width (470 pt) is now a
        // little wider than the window. That is fine — `.segmented` shares the width it is given
        // equally and only truncates when a label does not fit its share, so what has to be
        // asserted is the share, not the ideal. Measured against the real system font, every
        // label keeps well over 30 pt of padding at the width the window actually gives it.
        let available = SettingsView.formWidth - 2 * SettingsView.gap
        let share = available / CGFloat(SettingsTab.allCases.count)
        // What `.segmented` actually keeps around a label. Measured off the Appearance tab's own
        // five-segment Preset picker, which has shipped since SPEC §14: "Comfortable" (72.5 pt)
        // renders whole in an 80 pt segment, so the control needs under 4 pt a side. 5 is the
        // conservative number this asserts against.
        let segmentPadding: CGFloat = 5
        let systemFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        for tab in SettingsTab.allCases {
            let labelWidth = (tab.label as NSString)
                .size(withAttributes: [.font: systemFont]).width
            XCTAssertLessThanOrEqual(
                labelWidth + 2 * segmentPadding, share,
                "\(tab.rawValue): the segment's share of the window has to hold its whole label"
            )
        }

        for tab in SettingsTab.allCases {
            settings.settingsTab = tab
            let view = SettingsView(
                settings: settings, usage: state.usage, hotKeys: hotKeys,
                sessions: state.store.sessions, home: temporaryHome
            )
            let window = render(view, named: "settings-\(tab.rawValue)")
            // The tab's own form, unconstrained: what the scroll view has to carry.
            let content = layout(view.tabForm.frame(width: SettingsView.formWidth))

            XCTAssertEqual(window.width, SettingsView.formWidth, accuracy: 1, tab.rawValue)
            XCTAssertLessThanOrEqual(
                window.height, SettingsView.maxContentHeight,
                "\(tab.rawValue): the settings window must stay under 600 pt"
            )
            XCTAssertGreaterThan(content.height, 0, tab.rawValue)
            if content.height <= SettingsView.maxContentHeight {
                XCTAssertGreaterThanOrEqual(
                    window.height, content.height,
                    "\(tab.rawValue): a form that fits must not be scrolled or clipped"
                )
            } else {
                XCTAssertEqual(
                    window.height, SettingsView.maxContentHeight, accuracy: 0.5,
                    "\(tab.rawValue): a form taller than the window scrolls inside it"
                )
            }
        }
    }

    /// SPEC §11.4's section, on its own tab: the stepper, the pickers and a per-session row.
    func testSettingsViewLaysOutWithTheCardSectionPopulated() {
        settings.settingsTab = .cards
        settings.setCards(false, for: "ab813983-4f21-4c0e-9a17-2f5b6c8d1e00")
        settings.suggestionSource = .ollama
        let view = SettingsView(
            settings: settings,
            usage: state.usage,
            hotKeys: hotKeys,
            ollamaModels: [
                OllamaModel(name: "qwen3.5:4b", parameterSize: "4.0B"),
                OllamaModel(name: "llama3.3:70b", parameterSize: "70.6B"),
            ],
            sessions: state.store.sessions,
            home: temporaryHome
        )
        let size = layout(view)
        XCTAssertEqual(size.width, SettingsView.formWidth, accuracy: 1)
        XCTAssertLessThanOrEqual(size.height, SettingsView.maxContentHeight)

        // The per-session row and the model picker are extra rows, not a layer over the ones
        // that were already there.
        let populated = layout(view.tabForm.frame(width: SettingsView.formWidth))
        settings.pruneCardOverrides(keeping: [])
        let bare = layout(
            SettingsView(settings: settings, usage: state.usage, hotKeys: hotKeys, home: temporaryHome)
                .tabForm.frame(width: SettingsView.formWidth)
        )
        XCTAssertGreaterThan(populated.height, bare.height)
        XCTAssertGreaterThan(bare.height, 250)
    }

    /// SPEC §13.2: picking Claude adds a model picker, a binary field with its button, and the
    /// ten-line template editor — each on its own row, so the form only gets taller. The window
    /// stays 600 pt either way, which is exactly what the scroll view is for.
    func testSettingsViewLaysOutWithTheClaudeSectionOpen() {
        settings.settingsTab = .cards
        settings.suggestionSource = .ollama
        let ollamaView = SettingsView(
            settings: settings, usage: state.usage, hotKeys: hotKeys, home: temporaryHome
        )
        let withOllama = layout(ollamaView.tabForm.frame(width: SettingsView.formWidth))

        settings.suggestionSource = .claude
        let claudeView = SettingsView(
            settings: settings, usage: state.usage, hotKeys: hotKeys, home: temporaryHome
        )
        let withClaude = layout(claudeView.tabForm.frame(width: SettingsView.formWidth))

        XCTAssertEqual(withClaude.width, SettingsView.formWidth, accuracy: 1)
        XCTAssertGreaterThan(
            withClaude.height, withOllama.height + SettingsView.templateEditorHeight,
            "the editor and the binary row need their own space, not a layer over something"
        )
        XCTAssertLessThanOrEqual(
            layout(claudeView).height, SettingsView.maxContentHeight,
            "however tall the form is, the window is not"
        )
    }
}
