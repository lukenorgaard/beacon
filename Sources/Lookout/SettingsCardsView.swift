import AppKit
import Combine
import SwiftUI

extension SettingsView {
    // MARK: - Cards

    @ViewBuilder
    var cardsSections: some View {
        Section("Answer from the widget") {
            Toggle("Show a card when a session needs you", isOn: $settings.attentionCards)
            Toggle("Also when a session finishes", isOn: $settings.cardOnDone)
                .disabled(!settings.attentionCards)
            Toggle("Cards for new sessions", isOn: $settings.cardsForNewSessions)
                .disabled(!settings.attentionCards)

            // Its own row, with the value beside the label — nothing sits on the stepper.
            Stepper(value: $settings.waitSeconds, in: LookoutConfig.waitRange) {
                HStack(spacing: SettingsView.gap) {
                    Text("Hold the terminal for")
                    Spacer(minLength: SettingsView.gap)
                    Text(
                        settings.waitSeconds == 0
                            ? "don't wait" : "\(settings.waitSeconds) s"
                    )
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            Text("How long a permission prompt waits for your answer before the terminal takes over.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Picker("Suggestions", selection: suggestionBinding) {
                ForEach(SuggestionSource.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if settings.effectiveSuggestionSource == .ollama {
                if ollamaModels.isEmpty {
                    Text("Ollama did not answer at startup — the heuristic is used instead.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else {
                    Picker("Model", selection: modelBinding) {
                        ForEach(ollamaModels.map(\.name), id: \.self) { Text($0).tag($0) }
                    }
                }
            }

            if settings.effectiveSuggestionSource == .claude {
                claudeSuggestions
            }

            if !cardOverrides.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Per session")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    ForEach(cardOverrides, id: \.id) { session in
                        Toggle(
                            session.project.isEmpty ? session.sessionID : session.project,
                            isOn: cardBinding(for: session.sessionID)
                        )
                    }
                    Text("Right-click a row in the panel to add or remove one.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }
        }

        presetsSection
    }
}
