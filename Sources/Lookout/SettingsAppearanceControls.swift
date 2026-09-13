import AppKit
import Combine
import SwiftUI

extension SettingsView {
    // MARK: - Appearance (SPEC §14)

    /// Picking a preset sets the three values; picking "Custom" changes nothing, because Custom
    /// is what the panel *reports* once one of them has been nudged.
    var presetBinding: Binding<AppearancePreset> {
        Binding(
            get: { settings.appearance.preset },
            set: { settings.apply(preset: $0) }
        )
    }

    var appearanceSummary: String {
        let appearance = settings.appearance
        return "Rows \(Int(Theme.Metrics(appearance).rowHeight)) pt · "
            + "card \(Int(appearance.cardWidth)) pt · drag the panel's right edge or corner."
    }

    func percent(_ scale: CGFloat) -> String { "\(Int((scale * 100).rounded())) %" }

    func points(_ value: CGFloat) -> String { "\(Int(value.rounded())) pt" }

    var scopedModels: [String] {
        usage.snapshot?.scopedModelNames ?? []
    }

    /// Only the sessions the user actually decided about get a row; the rest follow the
    /// "Cards for new sessions" default and would only be noise here.
    var cardOverrides: [Session] {
        sessions.filter { settings.cardOverrides[$0.sessionID] != nil }
    }

    var suggestionBinding: Binding<SuggestionSource> {
        Binding(
            get: { settings.effectiveSuggestionSource },
            set: { settings.suggestionSource = $0 }
        )
    }

    var modelBinding: Binding<String> {
        Binding(
            get: { settings.ollamaModel ?? Ollama.defaultModel(ollamaModels) ?? "" },
            set: { settings.ollamaModel = $0 }
        )
    }

    func cardBinding(for sessionID: String) -> Binding<Bool> {
        Binding(
            get: { settings.cardsEnabled(for: sessionID) },
            set: { settings.setCards($0, for: sessionID) }
        )
    }

    func binding(for model: String) -> Binding<Bool> {
        Binding(
            get: { !settings.hiddenUsageModels.contains(model) },
            set: { visible in
                if visible {
                    settings.hiddenUsageModels.remove(model)
                } else {
                    settings.hiddenUsageModels.insert(model)
                }
            }
        )
    }

    func commit() {
        settings.agentCommandsText = commandsText
        commandsText = settings.agentCommandsText
    }
}
