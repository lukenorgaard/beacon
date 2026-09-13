import AppKit
import Combine
import SwiftUI

/// Every toggle from SPEC §5.5, in a plain system-looking window — the panel is the sleek part,
/// settings should just be legible.
///
/// SPEC §15.2: four tabs, because one column of every section was "so tall I can't use it". The
/// window is a fixed 460 pt wide and never taller than 600 pt; a tab whose form needs more than
/// that scrolls inside itself.
struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var usage: UsageClient
    /// SPEC §17.2: read for the recorder fields' conflict warnings, written through by rebinding.
    @ObservedObject var hotKeys: HotKeyCenter
    var onOpenSetup: () -> Void = {}
    /// Models Ollama reported at startup, for the picker (SPEC §11.4). Empty when it is not
    /// running, in which case the picker says so rather than offering nothing.
    var ollamaModels: [OllamaModel] = []
    /// Sessions with a card override, so they can be taken back one by one.
    var sessions: [Session] = []
    /// Where `suggest-prompt.md` lives (SPEC §13.2).
    var home: LookoutHome = LookoutHome()

    /// Which action's recorder is mid-combo, if any (SPEC §17.2).
    /// The field's own live buffer while it is being edited, keyed by model — separate from
    /// `settings.contextWindows` so a keystroke is not itself a commit.
    @State var contextWindowTexts: [String: String] = [:]
    /// Which context-window field currently holds focus, if any — losing it (not just changing
    /// text) is one of the two moments a value commits.
    @FocusState var focusedContextWindowKey: String?

    @State var recordingAction: HotKeyAction?
    /// The Presets section's "Add" field (SPEC §17.4).
    @State var newPresetText = ""

    @State var commandsText: String = ""
    @State var launchAtLogin = LaunchAgent.isInstalled
    /// The template editor's buffer. Loaded on appear, written back debounced so a keystroke
    /// is not a disk write.
    @State var templateText: String = ""
    @State var claudeBinaryText: String = ""
    @State var templateSave: DispatchWorkItem?
    @State var detected: String?

    /// The settings form is a plain system window: it is where the scale is *chosen*, so it does
    /// not scale with it — a form that resized under the stepper would be its own bug. The one
    /// measurement it borrows is the 8 pt gap every Lookout control keeps.
    static let gap = Theme.Metrics.standard.controlGap
    /// The width the render tests pin, and the width the family legend has to fit inside.
    static let formWidth: CGFloat = 460
    /// SPEC §15.2: the window's content never grows past this — the tab scrolls instead.
    static let maxContentHeight: CGFloat = 600

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $settings.settingsTab) {
                ForEach(SettingsTab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // 8 pt, not 12: SPEC §18.5 adds a fifth segment, and the picker shares whatever
            // width it is given equally between them. The four points this gives back are four
            // points "Appearance" — the longest label — does not have to give up.
            .padding(.horizontal, SettingsView.gap)
            .padding(.vertical, SettingsView.gap)
            .accessibilityLabel("Settings section")

            Divider()

            // The form is measured at its full height and the scroll view takes the overflow,
            // so nothing is ever clipped — it is scrolled to.
            ScrollView { tabForm }
        }
        .frame(width: SettingsView.formWidth)
        .frame(maxHeight: SettingsView.maxContentHeight)
        .onAppear {
            commandsText = settings.agentCommandsText
            claudeBinaryText = settings.claudeBinaryPath ?? ""
        }
        .onDisappear { flushTemplate() }
    }

    /// One tab's sections, at their natural height — what the tests measure to prove the window
    /// scrolls the content rather than cutting it off.
    @ViewBuilder
    var tabForm: some View {
        Form {
            switch settings.settingsTab {
            case .general: generalSections
            case .appearance: appearanceSection
            case .agents: agentsSections
            case .cards: cardsSections
            case .sentinel: sentinelSections
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}
