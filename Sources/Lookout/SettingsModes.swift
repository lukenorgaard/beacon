import Foundation

enum PanelMode: String, CaseIterable {
    /// Floating panel on every Space (SPEC §5.1).
    case pinned
    /// Panel hidden; the status item opens it transiently.
    case menuBar

    var label: String {
        switch self {
        case .pinned: return "Pinned"
        case .menuBar: return "Menu bar"
        }
    }
}

enum StatusTextMode: String, CaseIterable {
    case needsCount
    case full
    case none

    var label: String {
        switch self {
        case .needsCount: return "Needs-you count"
        case .full: return "Count + usage"
        case .none: return "Dot only"
        }
    }
}

/// SPEC §15.2: the four pages of the settings window. The window opens on whichever one was
/// last used, so the tab a person lives in is the tab they get.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case agents
    case cards
    /// SPEC §18.5: the machine watcher's own page.
    case sentinel

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .agents: return "Agents"
        case .cards: return "Cards"
        case .sentinel: return "Sentinel"
        }
    }
}
