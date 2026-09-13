import AppKit
import Combine
import SwiftUI

extension SettingsView {
    // MARK: - Presets (SPEC §17.4)

    @ViewBuilder
    var presetsSection: some View {
        Section("Presets") {
            ForEach(settings.answerPresets) { preset in
                HStack(spacing: SettingsView.gap) {
                    TextField("Reply", text: presetTextBinding(for: preset.id))
                        .textFieldStyle(.roundedBorder)
                    Picker("Key", selection: presetKeyBinding(for: preset.id)) {
                        Text("—").tag(0)
                        ForEach(1...AnswerPresets.maxKeyBinding, id: \.self) { number in
                            Text("⌘\(number)").tag(number)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 64)
                    Button {
                        movePreset(preset.id, up: true)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(settings.answerPresets.first?.id == preset.id)
                    .help("Move up")
                    Button {
                        movePreset(preset.id, up: false)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(settings.answerPresets.last?.id == preset.id)
                    .help("Move down")
                    Button(role: .destructive) {
                        removePreset(preset.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Remove this preset")
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: SettingsView.gap) {
                TextField("New preset", text: $newPresetText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addPreset() }
                Button("Add", action: addPreset)
                    .disabled(newPresetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.vertical, 2)

            Text(
                "Shown as small buttons above the card's reply field — a click fills it, "
                    + "never sends. ⌘1…⌘9 do the same from the keyboard."
            )
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
    }

    private func presetTextBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { settings.answerPresets.first { $0.id == id }?.text ?? "" },
            set: { newValue in
                guard let index = settings.answerPresets.firstIndex(where: { $0.id == id })
                else { return }
                settings.answerPresets[index].text = newValue
            }
        )
    }

    /// `0` stands for "no binding" in the picker's tag space — `AnswerPreset.keyBinding` is
    /// `Int?`, and a `Picker` selection needs a concrete, hashable value.
    private func presetKeyBinding(for id: UUID) -> Binding<Int> {
        Binding(
            get: { settings.answerPresets.first { $0.id == id }?.keyBinding ?? 0 },
            set: { newValue in
                settings.answerPresets = AnswerPresets.assign(
                    settings.answerPresets, id: id, keyBinding: newValue == 0 ? nil : newValue
                )
            }
        )
    }

    private func movePreset(_ id: UUID, up: Bool) {
        guard let index = settings.answerPresets.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? index - 1 : index + 1
        guard settings.answerPresets.indices.contains(target) else { return }
        settings.answerPresets.swapAt(index, target)
    }

    private func removePreset(_ id: UUID) {
        settings.answerPresets.removeAll { $0.id == id }
    }

    private func addPreset() {
        let text = newPresetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        settings.answerPresets.append(AnswerPreset(text: text))
        newPresetText = ""
    }
}
