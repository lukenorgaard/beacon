import AppKit
import SwiftUI

/// The card itself: header, Asks, Suggestion, the field, the buttons, one status line.
///
/// Every section is a row in one `VStack` — nothing is layered over a control, and no two
/// controls sit closer than the 8 pt gap. Its width follows the panel's (SPEC §14); its height
/// comes from the laid-out content, because a six-line command and a one-line question do not
/// deserve the same window.
struct AttentionCardView: View {
    @ObservedObject var model: AttentionCardModel
    /// The card is a root window of its own, so it reads the appearance itself and puts the
    /// measurements into its own environment (SPEC §14).
    @ObservedObject var settings: Settings

    /// SPEC §17.2's ⌃⌥R: a new `focusRequestToken` from the model is the cue to take focus.
    @FocusState private var replyFocused: Bool

    init(model: AttentionCardModel) {
        self.model = model
        self.settings = model.settings
    }

    var metrics: Theme.Metrics { settings.metrics }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.controlGap + metrics.scaled(2)) {
            header
            asks
            suggestionSection
            presetsRow
            editor
            buttons
            statusLine
        }
        .padding(metrics.padding)
        .frame(width: metrics.cardWidth, alignment: .leading)
        .background(VisualEffectBackground())
        // SPEC §17.4's ⌘1…⌘9: invisible buttons carry the shortcuts — `.keyboardShortcut` needs
        // no size or visibility, only a target, so this never disturbs the layout above it.
        .background(presetKeyboardShortcuts)
        .clipShape(RoundedRectangle(cornerRadius: metrics.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: metrics.corner, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: metrics.stroke)
                .allowsHitTesting(false)
        )
        .environment(\.metrics, metrics)
        .environment(\.colorScheme, .dark)
        .onChange(of: model.focusRequestToken) { _, _ in replyFocused = true }
        // Cards lane, 2026-09-04: the other half of `isTypingOrFocused` — an about-to-expire
        // `done` card is held open while the field has focus, even before a character is typed.
        .onChange(of: replyFocused) { _, focused in model.replyFieldFocused = focused }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        if let session = model.session {
            VStack(alignment: .leading, spacing: metrics.scaled(5)) {
                HStack(spacing: metrics.scaled(6)) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Theme.color(for: session.state))
                        .frame(width: metrics.accentBarWidth, height: metrics.scaled(15))
                    Text(session.project)
                        .font(metrics.header)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HostChip(host: session.host)
                    if let chip = session.modelChip {
                        ModelChip(
                            text: chip,
                            color: Theme.color(for: session.family),
                            help: session.modelTooltip ?? session.agent.display
                        )
                    }
                    Spacer(minLength: metrics.controlGap)
                    Text(Format.duration(session.timeInState()))
                        .font(metrics.numeral)
                        .foregroundStyle(Theme.textTertiary)
                }
                // SPEC §15.4: the session's name, on its own line under the project — the card
                // has the room a row's line 1 does not, and a home-folder name is not a session name.
                if let name = session.displayName {
                    Text(name)
                        .font(metrics.rowSecondary)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(session.sessionNameIsPath ? .middle : .tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: metrics.scaled(6)) {
                    Text(session.statusLabel)
                        .font(metrics.rowSecondary)
                        .foregroundStyle(Theme.color(for: session.state))
                        .lineLimit(1)
                    if model.pendingCount > 0 {
                        Spacer(minLength: metrics.controlGap)
                        Text(
                            model.pendingCount == 1
                                ? "1 more waiting" : "\(model.pendingCount) more waiting"
                        )
                        .font(metrics.chip)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, metrics.chipPaddingH)
                        .padding(.vertical, metrics.chipPaddingV)
                        .background(
                            RoundedRectangle(cornerRadius: metrics.chipCorner, style: .continuous)
                                .fill(Theme.chipFill)
                        )
                    }
                }
            }
        }
    }

    // MARK: Asks (SPEC §11.4)

    @ViewBuilder
    private var asks: some View {
        VStack(alignment: .leading, spacing: metrics.scaled(6)) {
            CardSectionLabel(text: "Asks")
            switch model.kind {
            case .permission:
                Text(model.request?.headline ?? model.session?.detail ?? "Permission")
                    .font(metrics.rowSecondary)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let command = commandText {
                    CommandBox(text: command)
                }
            case .question:
                // Bug fix 2026-09-04: Codex can ask several questions in one call — the roomy
                // single-question layout stays for everything else (including a Codex call that
                // only ever asked one), and only a real multi-question call gets the compact list.
                if let codexQuestions = model.request?.codexQuestions, codexQuestions.count > 1 {
                    codexQuestionsList(codexQuestions)
                } else {
                    Text(questionText)
                        .font(metrics.rowSecondary)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let options = model.request?.options, !options.isEmpty {
                        optionButtons(options)
                    }
                }
            case .done:
                Text(model.session?.lastMessage ?? model.session?.displayTitle ?? "Turn complete")
                    .font(metrics.rowSecondary)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var commandText: String? {
        model.request?.commandText ?? Session.text(model.session?.detailArgument)
    }

    private var questionText: String {
        Session.text(model.request?.question)
            ?? Session.text(model.request?.summary)
            ?? Session.text(model.session?.detail)
            ?? "Question for you"
    }

    /// SPEC §11.4: an option button fills the field — it never sends by itself.
    private func optionButtons(_ options: [String]) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: metrics.controlGap) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Button {
                        model.use(option: option)
                    } label: {
                        Text(option)
                            .font(metrics.rowSecondary)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, metrics.scaled(9))
                            .padding(.vertical, metrics.scaled(5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(
                                    cornerRadius: metrics.scaled(7), style: .continuous
                                )
                                .fill(Theme.cardFill)
                            )
                            .overlay(
                                RoundedRectangle(
                                    cornerRadius: metrics.scaled(7), style: .continuous
                                )
                                .strokeBorder(Theme.hairline, lineWidth: metrics.stroke)
                                .allowsHitTesting(false)
                            )
                            .contentShape(
                                RoundedRectangle(
                                    cornerRadius: metrics.scaled(7), style: .continuous
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Put this option in the field")
                }
            }
        }
        .frame(maxHeight: metrics.optionsMaxHeight)
    }

    /// Bug fix 2026-09-04: Codex's `request_user_input` can ask more than one question in the
    /// same call — `question`/`options` stay the first one alone (so every single-question card,
    /// Codex or not, keeps the roomy layout above), and this is what a second and third question
    /// get instead: "Question 2 of 3" over its own text, with a compact, wrapping row of its own
    /// options rather than a second scrolling list of full-width buttons.
    private func codexQuestionsList(_ questions: [CodexQuestion.Question]) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: metrics.controlGap) {
                ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                    VStack(alignment: .leading, spacing: metrics.scaled(4)) {
                        Text("Question \(index + 1) of \(questions.count)")
                            .font(metrics.chip)
                            .foregroundStyle(Theme.textTertiary)
                        Text(question.question)
                            .font(metrics.rowSecondary)
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !question.options.isEmpty {
                            compactOptionChips(question.options)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: metrics.questionsListMaxHeight)
    }

    /// The same "fill the field, never send" click `optionButtons` offers, as a wrapping row of
    /// small chips instead — what keeps `codexQuestionsList` readable at the panel's own width
    /// even when several questions each offer several options.
    private func compactOptionChips(_ options: [String]) -> some View {
        FlowLayout(spacing: metrics.scaled(6), lineSpacing: metrics.scaled(6)) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button {
                    model.use(option: option)
                } label: {
                    Text(option)
                        .font(metrics.chip)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .padding(.horizontal, metrics.chipPaddingH + metrics.scaled(2))
                        .padding(.vertical, metrics.chipPaddingV + metrics.scaled(2))
                        .background(
                            RoundedRectangle(cornerRadius: metrics.chipCorner, style: .continuous)
                                .fill(Theme.chipFill)
                        )
                        .contentShape(
                            RoundedRectangle(cornerRadius: metrics.chipCorner, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .help("Put this option in the field")
            }
        }
    }

    // MARK: Suggestion

    @ViewBuilder
    private var suggestionSection: some View {
        if settings.effectiveSuggestionSource != .off {
            VStack(alignment: .leading, spacing: metrics.scaled(6)) {
                // Its own row: the label sits left, the source chip right — nothing is layered
                // over anything, and the 8 pt gap between them is the card's minimum.
                HStack(spacing: metrics.controlGap) {
                    CardSectionLabel(text: "Suggestion")
                    Spacer(minLength: metrics.controlGap)
                    if let label = model.suggestionSourceLabel {
                        Text(label)
                            .font(metrics.chip)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityLabel("Suggestion source: \(label)")
                    }
                }
                HStack(alignment: .top, spacing: metrics.controlGap) {
                    if model.isSuggesting {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: metrics.glyphSize, height: metrics.glyphSize)
                        Text("Thinking…")
                            .font(metrics.rowSecondary)
                            .foregroundStyle(Theme.textTertiary)
                        Spacer(minLength: metrics.controlGap)
                    } else {
                        Text(model.suggestion ?? "No suggestion")
                            .font(metrics.rowSecondary)
                            .foregroundStyle(
                                model.suggestion == nil ? Theme.textTertiary : Theme.textSecondary
                            )
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                HStack(spacing: metrics.controlGap) {
                    CardButton(
                        title: "Use suggestion",
                        tone: .secondary,
                        help: "Put the suggestion in the field — it is never sent for you",
                        enabled: model.suggestion != nil && !model.isSuggesting
                    ) {
                        model.useSuggestion()
                    }
                    CardButton(
                        title: "↻",
                        tone: .secondary,
                        help: "Ask again",
                        enabled: !model.isSuggesting
                    ) {
                        model.regenerate()
                    }
                    Spacer(minLength: metrics.controlGap)
                }
            }
        }
    }

    // MARK: Presets (SPEC §17.4)

    /// A row of small buttons above the reply field; a click fills the field and never sends —
    /// exactly `useSuggestion`'s rule, for a reply the owner wrote himself instead of one the
    /// suggester came up with. `FlowLayout` (SPEC §17.3's reusable wrap) rather than a horizontal
    /// `ScrollView`: a card is only as wide as the panel, so a fourth or fifth preset used to run
    /// off the edge mid-word instead of dropping to a second line — the card's height is content-
    /// driven, so wrapping costs nothing.
    @ViewBuilder
    private var presetsRow: some View {
        if !settings.answerPresets.isEmpty {
            FlowLayout(spacing: metrics.scaled(6), lineSpacing: metrics.scaled(6)) {
                ForEach(settings.answerPresets) { preset in
                    PresetChip(preset: preset) { model.use(preset: preset) }
                }
            }
        }
    }

    /// SPEC §17.4: ⌘1…⌘9, each bound to whichever preset claimed that key.
    private var presetKeyboardShortcuts: some View {
        ForEach(1...AnswerPresets.maxKeyBinding, id: \.self) { number in
            if let preset = AnswerPresets.preset(for: number, in: settings.answerPresets) {
                Button("") { model.use(preset: preset) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: The field

    private var editor: some View {
        VStack(alignment: .leading, spacing: metrics.scaled(4)) {
            CardSectionLabel(text: "Your reply")
            TextEditor(text: $model.text)
                .font(metrics.editorFont)
                .foregroundStyle(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(metrics.scaled(6))
                .frame(height: metrics.editorHeight)
                .background(
                    RoundedRectangle(cornerRadius: metrics.scaled(8), style: .continuous)
                        .fill(Theme.cardFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: metrics.scaled(8), style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: metrics.stroke)
                        .allowsHitTesting(false)
                )
                .focused($replyFocused)
                .accessibilityLabel("Reply")
        }
    }

    // MARK: Buttons

    /// Two rows when Allow/Deny are on screen: five controls on one row would each be narrower
    /// than their own label (the 8 pt minimum decides this, not taste).
    @ViewBuilder
    private var buttons: some View {
        if model.isExpired {
            HStack(spacing: metrics.controlGap) {
                Text("Answer in the terminal")
                    .font(metrics.rowSecondary)
                    .foregroundStyle(Theme.needsYou)
                    .lineLimit(1)
                Spacer(minLength: metrics.controlGap)
                CardButton(title: "Open", tone: .primary, help: "Jump to the session") {
                    model.openSession()
                }
                CardButton(title: "Ignore", tone: .quiet, help: "Dismiss this card (Esc)") {
                    model.ignore()
                }
            }
        } else if model.isCodexQuestionCard {
            // Bug fix 2026-09-04: Codex only ever takes an answer to this from its own TUI —
            // Send stays on screen (so its caption explains why, same as every other disabled
            // control) but does nothing; Open takes its usual place on its own row instead, next
            // to Ignore, mirroring the expired-request layout above rather than crowding a fourth
            // button onto the Send row.
            VStack(alignment: .leading, spacing: metrics.controlGap) {
                HStack(spacing: metrics.controlGap) {
                    CardButton(
                        title: "Send", tone: .primary, help: model.sendHelp, enabled: false
                    ) {}
                    CardButton(
                        title: "Copy & go", tone: .secondary,
                        help: "Copy the reply and jump to the session", enabled: model.canCopy
                    ) {
                        model.copyAndGo()
                    }
                    Spacer(minLength: metrics.controlGap)
                }
                HStack(spacing: metrics.controlGap) {
                    CardButton(title: "Open", tone: .primary, help: "Jump to the session") {
                        model.openSession()
                    }
                    CardButton(title: "Ignore", tone: .quiet, help: "Dismiss this card (Esc)") {
                        model.ignore()
                    }
                    Spacer(minLength: metrics.controlGap)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: metrics.controlGap) {
                if model.canAnswerWithFile {
                    HStack(spacing: metrics.controlGap) {
                        CardButton(
                            title: "Allow", tone: .primary,
                            help: "Answer the waiting permission request",
                            enabled: model.answered == nil
                        ) {
                            model.answer(.allow)
                        }
                        CardButton(
                            title: "Deny", tone: .danger,
                            help: "Refuse the waiting permission request",
                            enabled: model.answered == nil
                        ) {
                            model.answer(.deny)
                        }
                        Spacer(minLength: metrics.controlGap)
                    }
                }
                HStack(spacing: metrics.controlGap) {
                    CardButton(
                        title: model.isSending ? "Sending…" : "Send",
                        tone: .primary,
                        help: model.sendHelp,
                        enabled: model.canSend
                    ) {
                        model.send()
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    CardButton(
                        title: "Copy & go", tone: .secondary,
                        help: "Copy the reply and jump to the session",
                        enabled: model.canCopy
                    ) {
                        model.copyAndGo()
                    }
                    CardButton(title: "Ignore", tone: .quiet, help: "Dismiss this card (Esc)") {
                        model.ignore()
                    }
                    Spacer(minLength: metrics.controlGap)
                }
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        Text(model.statusLine ?? " ")
            .font(metrics.rowSecondary)
            .foregroundStyle(model.statusLineIsError ? Theme.needsYou : Theme.textTertiary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
