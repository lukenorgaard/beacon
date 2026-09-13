import AppKit
import Combine
import SwiftUI

extension SettingsView {
    // MARK: - Appearance

    @ViewBuilder
    var appearanceSection: some View {
        Section("Appearance") {
            Picker("Preset", selection: presetBinding) {
                ForEach(AppearancePreset.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            // Its own row, with a live sample of the size being chosen — nothing is layered
            // over the stepper (SPEC §14).
            Stepper(
                value: $settings.appearance.scale,
                in: Appearance.scaleRange,
                step: Appearance.scaleStep
            ) {
                HStack(spacing: SettingsView.gap) {
                    Text("Text size")
                    Spacer(minLength: SettingsView.gap)
                    Text("Aa")
                        .font(.system(size: 13 * settings.appearance.scale, weight: .semibold))
                        .frame(minWidth: 30, alignment: .trailing)
                        .accessibilityLabel("Sample text at the chosen size")
                    Text(percent(settings.appearance.scale))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }
            }

            Stepper(
                value: $settings.appearance.panelWidth,
                in: Appearance.widthRange,
                step: Appearance.widthStep
            ) {
                HStack(spacing: SettingsView.gap) {
                    Text("Panel width")
                    Spacer(minLength: SettingsView.gap)
                    Text(points(settings.appearance.panelWidth))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Stepper(
                value: $settings.appearance.listMaxHeight,
                in: Appearance.listHeightRange,
                step: Appearance.listHeightStep
            ) {
                HStack(spacing: SettingsView.gap) {
                    Text("List height")
                    Spacer(minLength: SettingsView.gap)
                    Text(points(settings.appearance.listMaxHeight))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Density", selection: $settings.appearance.density) {
                ForEach(PanelDensity.allCases, id: \.self) { Text($0.label).tag($0) }
            }

            HStack(spacing: SettingsView.gap) {
                Text(appearanceSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: SettingsView.gap)
                Button("Reset to Default") { settings.resetAppearance() }
            }
            .padding(.vertical, 2)
        }
    }
}
