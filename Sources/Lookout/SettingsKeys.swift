import Foundation

extension Settings {
    enum Key {
        static let mode = "panelMode"
        static let statusText = "statusTextMode"
        static let showIdle = "showIdleSessions"
        static let showHistoryTab = "showHistoryTab"
        static let notifyNeedsYou = "notifyNeedsYou"
        static let notifyDone = "notifyDone"
        static let usageInterval = "usageRefreshInterval"
        static let hiddenUsageModels = "hiddenUsageModels"
        static let discoverAgents = "discoverAgents"
        static let agentCommands = "agentCommands"
        static let panelOrigin = "panelOrigin"
        static let settingsTab = "settingsTab"
        static let setupSeen = "setupSeen"
        static let launchAgentBootstrapped = "launchAgentBootstrapped"
        // Answer from the widget (SPEC §11.4)
        static let attentionCards = "attentionCards"
        static let cardsForNewSessions = "cardsForNewSessions"
        static let cardOnDone = "cardOnDone"
        static let cardOverrides = "cardOverrides"
        static let waitSeconds = "waitSeconds"
        static let suggestionSource = "suggestionSource"
        static let ollamaModel = "ollamaModel"
        // Suggestions from the owner's own Claude (SPEC §13.2)
        static let claudeModel = "claudeSuggestModel"
        static let claudeBinaryPath = "claudeBinaryPath"
        // Appearance (SPEC §14)
        static let scale = "appearanceScale"
        static let panelWidth = "appearancePanelWidth"
        static let listMaxHeight = "appearanceListMaxHeight"
        static let density = "appearanceDensity"
        // Sorting and filtering (SPEC §17.3)
        static let filterStates = "sessionFilterStates"
        static let filterHosts = "sessionFilterHosts"
        static let sessionOrder = "sessionOrder"
        static let pinnedSessions = "pinnedSessions"
        // On hold (manual override)
        static let heldSessions = "heldSessions"
        // Answer presets (SPEC §17.4)
        static let answerPresets = "answerPresets"
        // Global hotkeys (SPEC §17.2)
        static let hotKeyBindings = "hotKeyBindings"
        /// SPEC §17.2's Clear: actions with no shortcut at all, distinct from one merely left at
        /// its default.
        static let clearedHotKeys = "clearedHotKeyActions"
        // Cost per session (SPEC §17.6)
        static let pricing = "pricingTable"
        // Context per session (SPEC §19.2, §19.3)
        static let contextWarnPercent = "contextWarnPercent"
        static let contextWindows = "contextWindows"
        // Sentinel (SPEC §18.5)
        static let sentinelEnabled = "sentinelEnabled"
        static let sentinelSensitivity = "sentinelSensitivity"
        static let sentinelNotifications = "sentinelNotifications"
        static let sentinelMenuBarDot = "sentinelMenuBarDot"
    }
}
