import XCTest
@testable import Lookout

final class SettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "io.github.lukenorgaard.beacon.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testDefaultsMatchTheSpec() {
        let settings = Settings(defaults: defaults)
        XCTAssertEqual(settings.mode, .pinned)
        XCTAssertEqual(settings.statusText, .full)
        XCTAssertTrue(settings.showIdle)
        XCTAssertTrue(settings.notifyNeedsYou)
        XCTAssertTrue(settings.notifyDone)
        XCTAssertEqual(settings.usageRefreshInterval, 60)
        XCTAssertTrue(settings.discoverAgents)
        XCTAssertEqual(settings.agentCommands, ProcessScanner.defaultCommands)
        XCTAssertTrue(settings.hiddenUsageModels.isEmpty)

        // SPEC §11.4
        XCTAssertTrue(settings.attentionCards)
        XCTAssertTrue(settings.cardsForNewSessions)
        XCTAssertFalse(settings.cardOnDone, "a card on `done` is opt-in")
        XCTAssertTrue(settings.cardOverrides.isEmpty)
        XCTAssertEqual(settings.waitSeconds, 45)
        XCTAssertNil(settings.suggestionSource, "decided by the startup probe")
        XCTAssertEqual(settings.effectiveSuggestionSource, .heuristic)
        XCTAssertNil(settings.ollamaModel)

        // History tab behind a switch — the owner: "history I think is irrelevant".
        XCTAssertFalse(settings.showHistoryTab)
        // SPEC §18.5: Sentinel is on out of the box, at Balanced, notifying, with the dot.
        XCTAssertTrue(settings.sentinelEnabled)
        XCTAssertEqual(settings.sentinelSensitivity, .balanced)
        XCTAssertTrue(settings.sentinelNotifications)
        XCTAssertTrue(settings.sentinelMenuBarDot)
        // On hold (manual override).
        XCTAssertTrue(settings.heldSessions.isEmpty)
        // SPEC §19.2/§19.3: 40 % out of the box, measured against §19.3's windows.
        XCTAssertEqual(settings.contextWarnPercent, 40)
        XCTAssertEqual(settings.contextWarnFraction, 0.40, accuracy: 0.0001)
        XCTAssertEqual(settings.contextWindows, .standard)
    }

    func testShowHistoryTabPersistsAcrossInstances() {
        let settings = Settings(defaults: defaults)
        settings.showHistoryTab = true
        XCTAssertTrue(Settings(defaults: defaults).showHistoryTab)
    }

    func testHeldSessionsRoundTripAndPruneLikePinnedSessions() {
        let settings = Settings(defaults: defaults)
        let heldAt = Date(timeIntervalSince1970: 1_800_000_000)
        settings.heldSessions = ["s1": heldAt]

        let reopened = Settings(defaults: defaults)
        XCTAssertEqual(
            reopened.heldSessions["s1"]?.timeIntervalSince1970 ?? -1,
            heldAt.timeIntervalSince1970, accuracy: 1
        )

        reopened.heldSessions["s2"] = Date()
        reopened.pruneHeld(keeping: ["s2"])
        XCTAssertEqual(Set(reopened.heldSessions.keys), ["s2"])
    }

    func testTheCardSettingsPersistAndTheWaitIsClamped() {
        let settings = Settings(defaults: defaults)
        settings.cardOnDone = true
        settings.cardsForNewSessions = false
        settings.waitSeconds = 400
        settings.suggestionSource = .ollama
        settings.ollamaModel = "qwen3.5:4b"
        settings.setCards(true, for: "s1")

        let reopened = Settings(defaults: defaults)
        XCTAssertTrue(reopened.cardOnDone)
        XCTAssertFalse(reopened.cardsForNewSessions)
        XCTAssertEqual(reopened.waitSeconds, 110, "the stepper's range is 0…110 (SPEC §11.4)")
        XCTAssertEqual(reopened.suggestionSource, .ollama)
        XCTAssertEqual(reopened.effectiveSuggestionSource, .ollama)
        XCTAssertEqual(reopened.ollamaModel, "qwen3.5:4b")
        XCTAssertTrue(reopened.cardsEnabled(for: "s1"))
        XCTAssertFalse(reopened.cardsEnabled(for: "s2"))

        reopened.waitSeconds = -1
        XCTAssertEqual(reopened.waitSeconds, 0)
    }

    /// Only the sessions that disagree with the default are stored, and dead ones are dropped —
    /// the dictionary must not grow one entry per session ever seen.
    func testCardOverridesStaySmall() {
        let settings = Settings(defaults: defaults)
        settings.setCards(true, for: "s1")
        XCTAssertTrue(settings.cardOverrides.isEmpty, "agreeing with the default stores nothing")

        settings.setCards(false, for: "s1")
        XCTAssertEqual(settings.cardOverrides, ["s1": false])

        settings.setCards(true, for: "s1")
        XCTAssertTrue(settings.cardOverrides.isEmpty)

        settings.setCards(false, for: "s1")
        settings.setCards(false, for: "s2")
        settings.pruneCardOverrides(keeping: ["s2"])
        XCTAssertEqual(settings.cardOverrides, ["s2": false])

        settings.setCards(true, for: "")
        XCTAssertEqual(settings.cardOverrides, ["s2": false], "a blank id is not a session")
    }

    func testValuesPersistAcrossInstances() {
        let settings = Settings(defaults: defaults)
        settings.mode = .menuBar
        settings.showIdle = false
        settings.usageRefreshInterval = 120
        settings.hiddenUsageModels = ["Fable"]
        settings.agentCommandsText = "claude, gemini ,, CLAUDE, my-agent"

        let reopened = Settings(defaults: defaults)
        XCTAssertEqual(reopened.mode, .menuBar)
        XCTAssertFalse(reopened.showIdle)
        XCTAssertEqual(reopened.usageRefreshInterval, 120)
        XCTAssertEqual(reopened.hiddenUsageModels, ["Fable"])
        // Lowercased, de-duplicated, order kept.
        XCTAssertEqual(reopened.agentCommands, ["claude", "gemini", "my-agent"])
        XCTAssertEqual(reopened.agentCommandsText, "claude, gemini, my-agent")
    }

    /// SPEC §15.2: the settings window reopens on the tab it was left on.
    func testTheSettingsTabIsRemembered() {
        let settings = Settings(defaults: defaults)
        XCTAssertEqual(settings.settingsTab, .general, "a first open lands on General")

        settings.settingsTab = .cards
        XCTAssertEqual(Settings(defaults: defaults).settingsTab, .cards)

        settings.settingsTab = .agents
        XCTAssertEqual(Settings(defaults: defaults).settingsTab, .agents)

        // A defaults entry from somewhere else cannot select a tab that does not exist.
        defaults.set("nonsense", forKey: "settingsTab")
        XCTAssertEqual(Settings(defaults: defaults).settingsTab, .general)
        // SPEC §18.5 adds the fifth page.
        XCTAssertEqual(
            SettingsTab.allCases.map(\.label),
            ["General", "Appearance", "Agents", "Cards", "Sentinel"]
        )
    }

    // MARK: - Context-window field commit (SettingsView bug, 2026-09-06)
    //
    // The field used to write to `settings.contextWindows` on every keystroke — retyping
    // "200,000" into "500,000" passed a "5", "50", "500" … through that binding, each one
    // committed immediately, turning every row red for the length of the retype. The fix moves
    // the commit to submit/focus-loss only, through a pure parse-and-floor helper.

    func testContextWindowParsingFloorsAtOneThousandTokens() {
        XCTAssertEqual(SettingsView.parseContextWindow("500,000"), 500_000)
        XCTAssertEqual(SettingsView.parseContextWindow("1000"), 1_000, "the floor itself is accepted")
        XCTAssertNil(SettingsView.parseContextWindow("999"), "just under the floor is refused")
        XCTAssertNil(SettingsView.parseContextWindow("5"), "a mid-retype digit must never parse as a real window")
        XCTAssertNil(SettingsView.parseContextWindow("50"))
        XCTAssertNil(SettingsView.parseContextWindow(""), "empty text is not a value")
        XCTAssertNil(SettingsView.parseContextWindow("abc"), "no digits at all")
        XCTAssertEqual(
            SettingsView.parseContextWindow("  1,234,000 tokens "), 1_234_000,
            "separators and stray text are ignored — only the digits are kept"
        )
    }

    /// The Settings round trip, driven through the same guard `SettingsView.commitContextWindow`
    /// commits through: with the fix, a keystroke no longer reaches `settings.contextWindows` at
    /// all (only submit/focus-loss does), so the floor's job is the boundary case a real commit
    /// can still hit — a field blurred (Tab, clicking away) after only a few digits were typed,
    /// e.g. "5" of a "500,000" retype. That must be refused exactly like unparseable text, and a
    /// genuine commit (>= the floor) must persist normally.
    func testACommitBelowTheFloorIsRefusedAndAGoodCommitPersistsAndRoundTrips() {
        let settings = Settings(defaults: defaults)
        settings.contextWindows.windows["sonnet"] = 200_000

        // A premature blur mid-retype — only "5" typed so far.
        if let parsed = SettingsView.parseContextWindow("5") {
            settings.contextWindows.windows["sonnet"] = parsed
        }
        XCTAssertEqual(
            settings.contextWindows.windows["sonnet"], 200_000,
            "a value below the 1,000-token floor must never commit — the old value stands"
        )

        // The owner finishes typing and the real commit (submit/focus loss) fires once.
        if let parsed = SettingsView.parseContextWindow("500,000") {
            settings.contextWindows.windows["sonnet"] = parsed
        }
        XCTAssertEqual(settings.contextWindows.windows["sonnet"], 500_000)
        XCTAssertEqual(
            Settings(defaults: defaults).contextWindows.windows["sonnet"], 500_000,
            "the committed value survives a reopened Settings instance"
        )
    }

    func testPanelOriginRoundTrips() {
        let settings = Settings(defaults: defaults)
        XCTAssertNil(settings.panelOrigin)
        settings.panelOrigin = CGPoint(x: 1200.5, y: 640)
        XCTAssertEqual(Settings(defaults: defaults).panelOrigin, CGPoint(x: 1200.5, y: 640))
    }
}
