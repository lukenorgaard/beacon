import AppKit
import Combine
import SwiftUI

extension SettingsView {
    // MARK: - Sentinel (SPEC §18.5)

    /// Four controls, each on its own row — nothing shares a line with a segmented picker, and
    /// the two explanatory lines are captions under the control they belong to, not labels beside
    /// it (the owner's rule: elements occupy their own space).
    @ViewBuilder
    var sentinelSections: some View {
        Section("Sentinel") {
            Toggle("Watch this Mac", isOn: $settings.sentinelEnabled)
            Text("Off removes the tab from the panel and stops the sampler entirely.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Picker("Sensitivity", selection: $settings.sentinelSensitivity) {
                ForEach(SystemWatchSensitivity.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(!settings.sentinelEnabled)
            Text(
                "Balanced uses Sentinel's own thresholds. Critical only raises them, "
                    + "Early warning lowers them — a rule still has to hold for its whole "
                    + "window before it fires."
            )
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Section("Alerts") {
            Toggle("Notify me about warnings", isOn: $settings.sentinelNotifications)
                .disabled(!settings.sentinelEnabled)
            Toggle("Menu-bar dot on critical", isOn: $settings.sentinelMenuBarDot)
                .disabled(!settings.sentinelEnabled)
            Text("A session that needs you always keeps the dot.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}
