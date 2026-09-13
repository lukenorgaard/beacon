import AppKit
import Combine
import SwiftUI

extension SettingsView {
    // MARK: - Claude (SPEC §13.2)

    /// Every control on its own row, 8 pt apart, and the editor is a block of its own — nothing
    /// here is layered over anything else.
    @ViewBuilder
    var claudeSuggestions: some View {
        Picker("Claude model", selection: $settings.claudeModel) {
            ForEach(ClaudeCLI.models, id: \.self) { Text($0.capitalized).tag($0) }
        }
        Text("Beacon asks your own Claude through `claude -p` — your subscription, no API key.")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 6) {
            Text("Claude binary")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: SettingsView.gap) {
                TextField("Leave empty to detect", text: $claudeBinaryText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit { commitBinary() }
                Button("Detect") { detect() }
            }
            Text(binaryHint)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: SettingsView.gap) {
                Text("Prompt template")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: SettingsView.gap)
                Button("Reset to default") {
                    templateSave?.cancel()
                    templateText = SuggestPromptTemplate.reset(in: home)
                }
            }
            TextEditor(text: $templateText)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: SettingsView.templateEditorHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                        .allowsHitTesting(false)
                )
                .onChange(of: templateText) { _, _ in scheduleTemplateSave() }
                // Read the first time the Claude section is on screen, so someone who never
                // picks Claude never gets the file written for them (SPEC §13.2).
                .onAppear {
                    guard templateText.isEmpty else { return }
                    templateText = SuggestPromptTemplate.load(in: home)
                }
                .accessibilityLabel("Suggestion prompt template")
            Text(
                "~/.lookout/suggest-prompt.md — "
                    + SuggestPromptTemplate.placeholders.map { "{{\($0)}}" }
                        .joined(separator: " ")
            )
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    /// Ten monospaced lines, plus the editor's own padding (SPEC §13.2).
    static let templateEditorHeight: CGFloat = 10 * 14 + 12

    private var binaryHint: String {
        if let path = Session.text(settings.claudeBinaryPath) { return path }
        if let detected { return "Found: \(detected)" }
        return "Empty = ~/.npm-global/bin/claude, then PATH, then the desktop bundle."
    }

    private func commitBinary() {
        settings.claudeBinaryPath = Session.text(claudeBinaryText)
        claudeBinaryText = settings.claudeBinaryPath ?? ""
    }

    private func detect() {
        let found = ClaudeBinary.discover(override: nil)
        detected = found
        claudeBinaryText = found ?? ""
        settings.claudeBinaryPath = found
    }

    private func scheduleTemplateSave() {
        templateSave?.cancel()
        let text = templateText
        let target = home
        let work = DispatchWorkItem { SuggestPromptTemplate.save(text, in: target) }
        templateSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func flushTemplate() {
        templateSave?.cancel()
        templateSave = nil
        guard !templateText.isEmpty else { return }
        SuggestPromptTemplate.save(templateText, in: home)
    }
}
