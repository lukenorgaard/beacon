import AppKit
import Combine
import SwiftUI

extension SettingsView {
    // MARK: - Keyboard shortcuts (SPEC §17.2)

    /// A label, the recorder field itself (click, press a combo, the label updates), a Clear
    /// button (no shortcut at all — SPEC §17.2), a Reset button (back to the default), and — its
    /// own line, never crowding the field — the conflict warning.
    @ViewBuilder
    func hotKeyRow(_ action: HotKeyAction) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: SettingsView.gap) {
                Text(action.label)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: SettingsView.gap)
                hotKeyRecorder(action)
                    .frame(width: 96, height: 22)
                Button("Clear") { hotKeys.clear(action) }
                    .font(.system(size: 10))
                    .help("No shortcut")
                Button("Reset") { hotKeys.reset(action) }
                    .font(.system(size: 10))
                    .help("Restore \(action.defaultBinding.label)")
            }
            if hotKeys.conflicts.contains(action) {
                Text("In use by another app")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.red)
            }
        }
        .padding(.vertical, 2)
    }

    private func hotKeyRecorder(_ action: HotKeyAction) -> some View {
        let recording = recordingAction == action
        let label = settings.hotKey(for: action)?.label ?? "None"
        return HotKeyRecorderField(
            isRecording: recording,
            onStart: { recordingAction = action },
            onCapture: { binding in
                hotKeys.rebind(action, to: binding)
                recordingAction = nil
            },
            onCancel: { recordingAction = nil }
        )
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(
                    recording ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: 1
                )
        )
        .overlay(
            Text(recording ? "Press keys…" : label)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .foregroundStyle(recording ? .secondary : .primary)
                .allowsHitTesting(false)
        )
        .accessibilityLabel("\(action.label) shortcut: \(label)")
    }
}
