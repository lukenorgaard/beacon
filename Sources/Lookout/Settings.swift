import Foundation

/// Everything the user can change, persisted in the `io.github.lukenorgaard.beacon` defaults suite (SPEC §5.5).
final class Settings: ObservableObject {
    static let suiteName = "io.github.lukenorgaard.beacon.settings"
    let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: Settings.suiteName) ?? .standard

        let store = self.defaults
        mode = PanelMode(rawValue: store.string(forKey: Key.mode) ?? "") ?? .pinned
        settingsTab = SettingsTab(rawValue: store.string(forKey: Key.settingsTab) ?? "") ?? .general
        statusText = StatusTextMode(rawValue: store.string(forKey: Key.statusText) ?? "") ?? .full
        showIdle = store.object(forKey: Key.showIdle) as? Bool ?? true
        showHistoryTab = store.object(forKey: Key.showHistoryTab) as? Bool ?? false
        // SPEC §18.5's four: on, Balanced, on, on.
        sentinelEnabled = store.object(forKey: Key.sentinelEnabled) as? Bool ?? true
        sentinelSensitivity = SystemWatchSensitivity(
            rawValue: store.string(forKey: Key.sentinelSensitivity) ?? ""
        ) ?? .balanced
        sentinelNotifications = store.object(forKey: Key.sentinelNotifications) as? Bool ?? true
        sentinelMenuBarDot = store.object(forKey: Key.sentinelMenuBarDot) as? Bool ?? true
        notifyNeedsYou = store.object(forKey: Key.notifyNeedsYou) as? Bool ?? true
        notifyDone = store.object(forKey: Key.notifyDone) as? Bool ?? true
        usageRefreshInterval = store.object(forKey: Key.usageInterval) as? Int ?? 60
        hiddenUsageModels = Set(store.stringArray(forKey: Key.hiddenUsageModels) ?? [])
        discoverAgents = store.object(forKey: Key.discoverAgents) as? Bool ?? true
        agentCommands = store.stringArray(forKey: Key.agentCommands) ?? ProcessScanner.defaultCommands
        attentionCards = store.object(forKey: Key.attentionCards) as? Bool ?? true
        cardsForNewSessions = store.object(forKey: Key.cardsForNewSessions) as? Bool ?? true
        cardOnDone = store.object(forKey: Key.cardOnDone) as? Bool ?? false
        cardOverrides = (store.dictionary(forKey: Key.cardOverrides) as? [String: Bool]) ?? [:]
        waitSeconds = LookoutConfig.clamp(
            store.object(forKey: Key.waitSeconds) as? Int ?? LookoutConfig.defaultWaitSeconds
        )
        // Left unset until the startup probe knows whether Ollama is there (SPEC §11.4).
        suggestionSource = (store.string(forKey: Key.suggestionSource))
            .flatMap(SuggestionSource.init(rawValue:))
        ollamaModel = store.string(forKey: Key.ollamaModel)
        claudeModel = ClaudeCLI.models.contains(store.string(forKey: Key.claudeModel) ?? "")
            ? (store.string(forKey: Key.claudeModel) ?? ClaudeCLI.defaultModel)
            : ClaudeCLI.defaultModel
        claudeBinaryPath = store.string(forKey: Key.claudeBinaryPath)
        let storedScale = store.object(forKey: Key.scale) as? Double
        let storedWidth = store.object(forKey: Key.panelWidth) as? Double
        let storedListHeight = store.object(forKey: Key.listMaxHeight) as? Double
        appearance = Appearance(
            scale: storedScale.map { CGFloat($0) } ?? Appearance.standard.scale,
            panelWidth: storedWidth.map { CGFloat($0) } ?? Appearance.standard.panelWidth,
            listMaxHeight: storedListHeight.map { CGFloat($0) }
                ?? Appearance.standard.listMaxHeight,
            density: PanelDensity(rawValue: store.string(forKey: Key.density) ?? "")
                ?? Appearance.standard.density
        )

        // SPEC §17.3: an empty set means "All" for both — nothing stored yet is nothing filtered.
        filterStates = Set(
            (store.stringArray(forKey: Key.filterStates) ?? []).compactMap(StateFilter.init(rawValue:))
        )
        filterHosts = Set(
            (store.stringArray(forKey: Key.filterHosts) ?? []).compactMap(SessionHost.init(rawValue:))
        )
        sessionOrder = SessionOrder(rawValue: store.string(forKey: Key.sessionOrder) ?? "") ?? .state
        pinnedSessions = Set(store.stringArray(forKey: Key.pinnedSessions) ?? [])

        // On hold: session id → when it was held. Same style as `pinnedSessions`, but a
        // dictionary because the clock matters — `SessionHold` reads it to decide whether a
        // report since then lifts the hold.
        heldSessions = (store.dictionary(forKey: Key.heldSessions) as? [String: Date]) ?? [:]

        // SPEC §17.4
        answerPresets = AnswerPresets.load(store, key: Key.answerPresets)

        // SPEC §17.2
        hotKeyBindings = HotKeyStorage.load(store, key: Key.hotKeyBindings)
        clearedHotKeys = Set(store.stringArray(forKey: Key.clearedHotKeys) ?? [])

        // SPEC §17.6
        pricing = PricingStorage.load(store, key: Key.pricing)

        // SPEC §19.2/§19.3: 40 % out of the box — and the windows the
        // percentage is measured against.
        contextWarnPercent = Settings.clampWarnPercent(
            store.object(forKey: Key.contextWarnPercent) as? Int
                ?? Int((ContextGauge.defaultWarnFraction * 100).rounded())
        )
        contextWindows = ContextWindowStorage.load(store, key: Key.contextWindows)
    }

    // MARK: - Appearance (SPEC §14)

    /// The four numbers every measurement in the app comes from. `Appearance` clamps itself, so
    /// nothing that writes here — stepper, preset, drag, a hand-edited defaults entry — can put
    /// a value outside its range.
    @Published var appearance: Appearance {
        didSet {
            guard appearance != oldValue else { return }
            if persistsAppearance { writeAppearance() }
        }
    }

    /// A resize drag changes the width sixty times a second; the defaults write happens once, on
    /// mouse-up (SPEC §14).
    private var persistsAppearance = true

    /// Fonts and points for the current appearance — what the SwiftUI environment carries and
    /// what the AppKit controllers size their windows from.
    var metrics: Theme.Metrics { Theme.Metrics(appearance) }

    func beginAppearanceDrag() { persistsAppearance = false }

    func endAppearanceDrag() {
        persistsAppearance = true
        writeAppearance()
    }

    func apply(preset: AppearancePreset) { appearance.apply(preset) }

    func resetAppearance() { appearance = .standard }

    private func writeAppearance() {
        defaults.set(Double(appearance.scale), forKey: Key.scale)
        defaults.set(Double(appearance.panelWidth), forKey: Key.panelWidth)
        defaults.set(Double(appearance.listMaxHeight), forKey: Key.listMaxHeight)
        defaults.set(appearance.density.rawValue, forKey: Key.density)
    }

    // MARK: - Sorting and filtering (SPEC §17.3)

    /// The state chips that are checked. Empty = "All" — every state chip unchecked is the same
    /// as none of them mattering, so it is never persisted as anything but an empty array.
    @Published var filterStates: Set<StateFilter> {
        didSet {
            defaults.set(filterStates.map(\.rawValue).sorted(), forKey: Key.filterStates)
        }
    }

    /// The host popover's checked hosts. Empty = every host passes.
    @Published var filterHosts: Set<SessionHost> {
        didSet {
            defaults.set(filterHosts.map(\.rawValue).sorted(), forKey: Key.filterHosts)
        }
    }

    /// Settings → General → Order.
    @Published var sessionOrder: SessionOrder {
        didSet { defaults.set(sessionOrder.rawValue, forKey: Key.sessionOrder) }
    }

    /// Session ids pinned via the row's "Pin to top" (SPEC §17.3). Only `.pinned` order actually
    /// moves them, but the glyph shows regardless of which order is active.
    @Published var pinnedSessions: Set<String> {
        didSet { defaults.set(Array(pinnedSessions).sorted(), forKey: Key.pinnedSessions) }
    }

    func isPinned(_ sessionID: String) -> Bool { pinnedSessions.contains(sessionID) }

    func togglePin(_ sessionID: String) {
        guard !sessionID.isEmpty else { return }
        if pinnedSessions.contains(sessionID) {
            pinnedSessions.remove(sessionID)
        } else {
            pinnedSessions.insert(sessionID)
        }
    }

    /// Drops pins for sessions that no longer exist, exactly like the card overrides.
    func prunePinned(keeping ids: Set<String>) {
        let kept = pinnedSessions.intersection(ids)
        if kept != pinnedSessions { pinnedSessions = kept }
    }

    // MARK: - On hold (manual override)

    /// Session ids the owner put "on hold" via the row's right-click menu, and when — `SessionHold`
    /// reads the timestamp to decide whether a report since then lifts the hold on its own.
    @Published var heldSessions: [String: Date] {
        didSet { defaults.set(heldSessions, forKey: Key.heldSessions) }
    }

    /// Drops holds for sessions that no longer exist, exactly like the pins and the card
    /// overrides.
    func pruneHeld(keeping ids: Set<String>) {
        let kept = heldSessions.filter { ids.contains($0.key) }
        if kept.count != heldSessions.count { heldSessions = kept }
    }

    // MARK: - Cost per session (SPEC §17.6)

    /// USD per million tokens, per model family, editable in Settings → General → Usage.
    @Published var pricing: PricingTable {
        didSet { PricingStorage.persist(pricing, in: defaults, key: Key.pricing) }
    }

    // MARK: - Context per session (SPEC §19.2, §19.3)

    /// Settings → General → Usage, "Suggest compact at". Stored as whole percent because that is
    /// what the stepper offers (10…90 in fives); `contextWarnFraction` is what the row and the
    /// header actually compare against.
    @Published var contextWarnPercent: Int {
        didSet {
            let clamped = Settings.clampWarnPercent(contextWarnPercent)
            // Assigning here does not re-enter `didSet`, so the write below is the only one.
            if clamped != contextWarnPercent { contextWarnPercent = clamped }
            defaults.set(clamped, forKey: Key.contextWarnPercent)
        }
    }

    /// The threshold as `ContextGauge` wants it: 40 % → 0.40.
    var contextWarnFraction: Double { Double(contextWarnPercent) / 100 }

    /// SPEC §19.3: tokens per model family, edited under the pricing table.
    @Published var contextWindows: ContextWindows {
        didSet {
            ContextWindowStorage.persist(contextWindows, in: defaults, key: Key.contextWindows)
        }
    }

    /// Nothing — stepper, a hand-edited defaults entry, a stale value from an older build — can
    /// put the threshold outside SPEC §19.2's 10…90, or off its 5-point step.
    static func clampWarnPercent(_ value: Int) -> Int {
        let range = ContextGauge.warnPercentRange
        let step = ContextGauge.warnPercentStep
        let stepped = Int((Double(value) / Double(step)).rounded()) * step
        return min(max(stepped, range.lowerBound), range.upperBound)
    }

    // MARK: - Answer presets (SPEC §17.4)

    /// One-line replies, in the order the Cards settings tab shows them; each optionally bound to
    /// a card key (⌘1…⌘9).
    @Published var answerPresets: [AnswerPreset] {
        didSet { AnswerPresets.persist(answerPresets, in: defaults, key: Key.answerPresets) }
    }

    // MARK: - Global hotkeys (SPEC §17.2)

    /// Explicit overrides only, keyed by `HotKeyAction.rawValue`; an action with none — and that
    /// is not in `clearedHotKeys` — uses its own default (SPEC §17.2's ⌃⌥L / ⌃⌥J / ⌃⌥R / ⌃⌥A /
    /// ⌃⌥D).
    @Published var hotKeyBindings: [String: HotKeyBinding] {
        didSet { HotKeyStorage.persist(hotKeyBindings, in: defaults, key: Key.hotKeyBindings) }
    }

    /// SPEC §17.2's Clear: an action in here has *no* shortcut, which is a third state a missing
    /// dictionary entry cannot represent on its own — that already means "use the default".
    @Published var clearedHotKeys: Set<String> {
        didSet { defaults.set(Array(clearedHotKeys).sorted(), forKey: Key.clearedHotKeys) }
    }

    /// `nil` means no shortcut at all — Clear's own persisted state, not merely "not customised".
    func hotKey(for action: HotKeyAction) -> HotKeyBinding? {
        guard !clearedHotKeys.contains(action.rawValue) else { return nil }
        return hotKeyBindings[action.rawValue] ?? action.defaultBinding
    }

    func setHotKey(_ binding: HotKeyBinding, for action: HotKeyAction) {
        if clearedHotKeys.contains(action.rawValue) { clearedHotKeys.remove(action.rawValue) }
        hotKeyBindings[action.rawValue] = binding
    }

    /// SPEC §17.2's Clear: no shortcut, unregistered — not the same as resetting to the default.
    func clearHotKey(for action: HotKeyAction) {
        hotKeyBindings.removeValue(forKey: action.rawValue)
        clearedHotKeys.insert(action.rawValue)
    }

    /// SPEC §17.2's Reset: back to the action's own default.
    func resetHotKey(for action: HotKeyAction) {
        clearedHotKeys.remove(action.rawValue)
        hotKeyBindings.removeValue(forKey: action.rawValue)
    }

    // MARK: - Answer from the widget (SPEC §11.4)

    /// The master switch. Off means no card ever opens, whatever a session does.
    @Published var attentionCards: Bool {
        didSet { defaults.set(attentionCards, forKey: Key.attentionCards) }
    }

    /// Whether a session nobody has decided about yet gets cards.
    @Published var cardsForNewSessions: Bool {
        didSet { defaults.set(cardsForNewSessions, forKey: Key.cardsForNewSessions) }
    }

    /// A card when a session *finishes*, not only when it needs something. Default off.
    @Published var cardOnDone: Bool {
        didSet { defaults.set(cardOnDone, forKey: Key.cardOnDone) }
    }

    /// Per-session yes/no, keyed by `session_id`; absent = follow `cardsForNewSessions`.
    @Published var cardOverrides: [String: Bool] {
        didSet { defaults.set(cardOverrides, forKey: Key.cardOverrides) }
    }

    /// How long the reporter waits for an answer file before letting the terminal prompt
    /// through (SPEC §11.3). Mirrored into `~/.lookout/config.json` by `AppState`.
    @Published var waitSeconds: Int {
        didSet {
            let clamped = LookoutConfig.clamp(waitSeconds)
            if clamped != waitSeconds {
                waitSeconds = clamped
                return
            }
            defaults.set(waitSeconds, forKey: Key.waitSeconds)
        }
    }

    /// Nil until the startup probe has run: `ollama` when Ollama answered, else `heuristic`.
    @Published var suggestionSource: SuggestionSource? {
        didSet {
            guard let suggestionSource else {
                defaults.removeObject(forKey: Key.suggestionSource)
                return
            }
            defaults.set(suggestionSource.rawValue, forKey: Key.suggestionSource)
        }
    }

    @Published var ollamaModel: String? {
        didSet {
            guard let value = Session.text(ollamaModel) else {
                defaults.removeObject(forKey: Key.ollamaModel)
                return
            }
            defaults.set(value, forKey: Key.ollamaModel)
        }
    }

    /// Which Claude answers when the source is `.claude` — haiku, sonnet or opus, haiku by
    /// default because a one-line reply is not a reasoning problem (SPEC §13.2).
    @Published var claudeModel: String {
        didSet {
            guard ClaudeCLI.models.contains(claudeModel) else {
                claudeModel = ClaudeCLI.defaultModel
                return
            }
            defaults.set(claudeModel, forKey: Key.claudeModel)
        }
    }

    /// An explicit path to `claude`, when discovery finds the wrong one (SPEC §13.2). Nil = use
    /// the discovery order.
    @Published var claudeBinaryPath: String? {
        didSet {
            guard let value = Session.text(claudeBinaryPath) else {
                defaults.removeObject(forKey: Key.claudeBinaryPath)
                return
            }
            defaults.set(value, forKey: Key.claudeBinaryPath)
        }
    }

    /// The three Settings values the Claude suggester needs, in the shape it asks for them.
    var claudeOptions: Suggester.ClaudeOptions {
        Suggester.ClaudeOptions(model: claudeModel, binaryPath: claudeBinaryPath)
    }

    /// What the card actually uses before the probe has answered.
    var effectiveSuggestionSource: SuggestionSource { suggestionSource ?? .heuristic }

    /// SPEC §11.4: a session gets cards when it was opted in explicitly, or — absent an
    /// explicit answer — when new sessions get them.
    func cardsEnabled(for sessionID: String) -> Bool {
        cardOverrides[sessionID] ?? cardsForNewSessions
    }

    func setCards(_ enabled: Bool, for sessionID: String) {
        guard !sessionID.isEmpty else { return }
        var next = cardOverrides
        // Storing only the *disagreements* keeps the dictionary from growing one entry per
        // session ever seen.
        if enabled == cardsForNewSessions {
            next.removeValue(forKey: sessionID)
        } else {
            next[sessionID] = enabled
        }
        if next != cardOverrides { cardOverrides = next }
    }

    /// Drops overrides for sessions that no longer exist, so the dictionary stays small.
    func pruneCardOverrides(keeping ids: Set<String>) {
        let kept = cardOverrides.filter { ids.contains($0.key) }
        if kept.count != cardOverrides.count { cardOverrides = kept }
    }

    @Published var mode: PanelMode {
        didSet { defaults.set(mode.rawValue, forKey: Key.mode) }
    }

    /// SPEC §15.2: the settings window reopens on the tab it was left on.
    @Published var settingsTab: SettingsTab {
        didSet { defaults.set(settingsTab.rawValue, forKey: Key.settingsTab) }
    }

    @Published var statusText: StatusTextMode {
        didSet { defaults.set(statusText.rawValue, forKey: Key.statusText) }
    }

    @Published var showIdle: Bool {
        didSet { defaults.set(showIdle, forKey: Key.showIdle) }
    }

    /// Settings → General → Panel: whether the History tab is in the tab strip at all. Default
    /// off — the owner: "history I think is irrelevant". The reporter keeps writing `history.jsonl`
    /// either way; this only hides the tab.
    @Published var showHistoryTab: Bool {
        didSet { defaults.set(showHistoryTab, forKey: Key.showHistoryTab) }
    }

    // MARK: - Sentinel (SPEC §18.5)

    /// Off takes the tab out of the strip *and* stops the engine — the watcher is not something
    /// that keeps sampling behind a hidden tab.
    @Published var sentinelEnabled: Bool {
        didSet { defaults.set(sentinelEnabled, forKey: Key.sentinelEnabled) }
    }

    /// Scales every rule's thresholds (1.6 / 1.0 / 0.5 — Sentinel's own numbers, SPEC §18.2).
    @Published var sentinelSensitivity: SystemWatchSensitivity {
        didSet { defaults.set(sentinelSensitivity.rawValue, forKey: Key.sentinelSensitivity) }
    }

    @Published var sentinelNotifications: Bool {
        didSet { defaults.set(sentinelNotifications, forKey: Key.sentinelNotifications) }
    }

    /// Whether a critical signal may colour the menu-bar dot. A session that needs the owner always
    /// keeps priority over it (SPEC §18.5).
    @Published var sentinelMenuBarDot: Bool {
        didSet { defaults.set(sentinelMenuBarDot, forKey: Key.sentinelMenuBarDot) }
    }

    @Published var notifyNeedsYou: Bool {
        didSet { defaults.set(notifyNeedsYou, forKey: Key.notifyNeedsYou) }
    }

    @Published var notifyDone: Bool {
        didSet { defaults.set(notifyDone, forKey: Key.notifyDone) }
    }

    /// 30, 60 or 120 seconds (SPEC §5.3).
    @Published var usageRefreshInterval: Int {
        didSet { defaults.set(usageRefreshInterval, forKey: Key.usageInterval) }
    }

    /// Scoped usage models the user unticked. Storing the *hidden* ones means a model seen for
    /// the first time is visible by default, as the spec requires.
    @Published var hiddenUsageModels: Set<String> {
        didSet { defaults.set(Array(hiddenUsageModels).sorted(), forKey: Key.hiddenUsageModels) }
    }

    @Published var discoverAgents: Bool {
        didSet { defaults.set(discoverAgents, forKey: Key.discoverAgents) }
    }

    /// Executable basenames the process scan treats as agents (SPEC §8.2).
    @Published var agentCommands: [String] {
        didSet { defaults.set(agentCommands, forKey: Key.agentCommands) }
    }

    var agentCommandsText: String {
        get { agentCommands.joined(separator: ", ") }
        set { agentCommands = Settings.parseCommands(newValue) }
    }

    static func parseCommands(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for piece in text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " }) {
            let name = piece.trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty, !seen.contains(name) else { continue }
            seen.insert(name)
            result.append(name)
        }
        return result
    }

}
