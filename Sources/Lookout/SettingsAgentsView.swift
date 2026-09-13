import AppKit
import Combine
import SwiftUI

extension SettingsView {
    // MARK: - Agents

    @ViewBuilder
    var agentsSections: some View {
        Section("Agents") {
            Toggle("Discover agents without hooks", isOn: $settings.discoverAgents)
            VStack(alignment: .leading, spacing: 6) {
                Text("Agent commands")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("claude, codex, gemini…", text: $commandsText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commit() }
                    Button("Apply") { commit() }
                }
                Text("Executable names the process scan treats as an agent, comma separated.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)

            // SPEC §16.3: the companion is installed from the setup window; this is the line
            // that says it exists at all, for anyone who never opens that window again.
            VStack(alignment: .leading, spacing: 6) {
                Text("Editor companion")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Sessions in Cursor, Devin and VS Code can be reached inside the window — "
                     + "a click lands in the session's own terminal tab, and Send and Rename "
                     + "type into it. Install it per editor in Beacon Setup → Editor companion, "
                     + "then reload the editor window.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        }

        Section("Row colours") {
            VStack(alignment: .leading, spacing: 6) {
                FamilyLegend()
                Text("A row is tinted by its model's family — the provider wins over the agent.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
        }
    }
}
