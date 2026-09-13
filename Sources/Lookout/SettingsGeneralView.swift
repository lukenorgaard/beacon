import AppKit
import Combine
import SwiftUI

extension SettingsView {
    // MARK: - General

    @ViewBuilder
    var generalSections: some View {
        Section("Panel") {
            Picker("Mode", selection: $settings.mode) {
                ForEach(PanelMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Menu bar text", selection: $settings.statusText) {
                ForEach(StatusTextMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Toggle("Show idle sessions", isOn: $settings.showIdle)
            Toggle("Show History tab", isOn: $settings.showHistoryTab)
            Toggle("Start at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    _ = newValue ? LaunchAgent.install() : LaunchAgent.uninstall()
                }
        }

        Section("Order") {
            // SPEC §17.3.
            Picker("Order", selection: $settings.sessionOrder) {
                ForEach(SessionOrder.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Text("Pinned first still breaks ties by state — needs you, then finished, then working.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }

        Section("Keyboard shortcuts") {
            // SPEC §17.2.
            ForEach(HotKeyAction.allCases, id: \.self) { action in
                hotKeyRow(action)
            }
            Text("Click a field, then press the new combination. Esc cancels.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }

        Section("Usage") {
            Picker("Refresh every", selection: $settings.usageRefreshInterval) {
                Text("30 s").tag(30)
                Text("60 s").tag(60)
                Text("120 s").tag(120)
            }
            if scopedModels.isEmpty {
                Text("Model limits appear here once the usage API returns them.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(scopedModels, id: \.self) { name in
                    Toggle(name, isOn: binding(for: name))
                }
            }

            // SPEC §17.6: the per-model prices the session-row cost chip and the Usage tab's
            // "Sessions today" total both read from — four independent numbers per model, because
            // a cache-read token is not priced like an input token.
            //
            // One shared column header rather than a label stacked over every field: nesting a
            // label-above-textfield VStack inside every one of the four `ForEach` rows made the
            // Form/List row-height pass miscompute and the rows visually overlapped (caught by
            // rendering this to a PNG and looking at it before shipping it).
            VStack(alignment: .leading, spacing: 4) {
                Text("Pricing (USD per 1M tokens)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                pricingHeader
                ForEach(PricingTable.orderedModelKeys, id: \.self) { key in
                    pricingRow(key)
                }
                HStack(spacing: SettingsView.gap) {
                    Text(
                        "API-equivalent estimate, not what your subscription charges — a model "
                            + "missing here stays unpriced."
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: SettingsView.gap)
                    Button("Reset to Default") { settings.pricing = .standard }
                        .font(.system(size: 10))
                }
            }
            .padding(.vertical, 2)

            // SPEC §19.2/§19.3: the threshold the row's context chip turns red at, and the
            // windows its percentage is measured against — one block, because a percentage and
            // the number it is a percentage *of* are one thought.
            VStack(alignment: .leading, spacing: 4) {
                contextThresholdRow
                Text("Context windows (tokens)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                // Its own stack: six text fields four points apart would sit closer than any
                // two controls in this window are allowed to. 10 and not 8, measured off the
                // render: a bordered field draws inside its frame, so a spacing of 8 leaves only
                // 6.5 pt of real air between two of them.
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(ContextWindows.orderedModelKeys, id: \.self) { key in
                        contextWindowRow(key)
                    }
                }
                HStack(spacing: SettingsView.gap) {
                    Text(
                        "Codex reports its own window; everything else is measured against these. "
                            + "Best knowledge, not documentation — correct them when they drift."
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: SettingsView.gap)
                    Button("Reset to Default") { settings.contextWindows = .standard }
                        .font(.system(size: 10))
                }
            }
            .padding(.vertical, 2)
        }

        Section("Notifications") {
            Toggle("Notify when a session needs you", isOn: $settings.notifyNeedsYou)
            Toggle("Notify when a session finishes", isOn: $settings.notifyDone)
        }

        Section("Setup") {
            // Its own row: the button never sits on top of the text beside it.
            HStack(spacing: SettingsView.gap) {
                Text("Hooks, permissions and start at login.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: SettingsView.gap)
                Button("Setup…", action: onOpenSetup)
            }
            .padding(.vertical, 2)
        }
    }
}
