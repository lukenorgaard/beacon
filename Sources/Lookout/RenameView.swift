import SwiftUI

/// SPEC §15.4's Rename… panel: a label, a field, §15.5's checkbox, Save (⏎) and Cancel (⎋).
///
/// Same material, corner and stroke as the attention card, and built the same way — every
/// element is a row in one `VStack`, so nothing is layered over the field and no two controls
/// sit closer than the 8 pt gap.
struct RenameView: View {
    @ObservedObject var model: RenameModel
    /// A root window of its own, so it reads the appearance itself (SPEC §14).
    @ObservedObject var settings: Settings

    @FocusState private var focused: Bool

    init(model: RenameModel) {
        self.model = model
        self.settings = model.settings
    }

    private var metrics: Theme.Metrics { settings.metrics }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.controlGap) {
            header
            field
            channelToggle
            buttons
            statusLine
        }
        .padding(metrics.padding)
        .frame(width: metrics.renameWidth, alignment: .leading)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: metrics.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: metrics.corner, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: metrics.stroke)
                .allowsHitTesting(false)
        )
        .environment(\.metrics, metrics)
        .environment(\.colorScheme, .dark)
        .onAppear {
            // One hop later: the field has to exist before it can take focus.
            DispatchQueue.main.async { focused = true }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: metrics.scaled(3)) {
            Text("Rename session")
                .font(metrics.header)
                .foregroundStyle(Theme.textPrimary)
            if let subtitle = headerSubtitle {
                Text(subtitle)
                    .font(metrics.rowSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The project, and the name the row would show without an override — the one thing a
    /// prefilled field cannot tell you (SPEC §15.4).
    private var headerSubtitle: String? {
        guard let session = model.session else { return nil }
        guard let original = model.originalName, original != model.trimmed else {
            return session.project
        }
        return "\(session.project) · \(Session.truncate(original, to: 48))"
    }

    // MARK: The field

    private var field: some View {
        TextField("Session name", text: $model.text)
            .textFieldStyle(.plain)
            .font(metrics.editorFont)
            .foregroundStyle(Theme.textPrimary)
            .focused($focused)
            .onSubmit { model.save() }
            .disabled(!model.canSave)
            .padding(.horizontal, metrics.scaled(8))
            .frame(height: metrics.renameFieldHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: metrics.scaled(8), style: .continuous)
                    .fill(Theme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: metrics.scaled(8), style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: metrics.stroke)
                    .allowsHitTesting(false)
            )
            .accessibilityLabel("Session name")
            .help("Empty removes the custom name")
    }

    // MARK: SPEC §15.5

    @ViewBuilder
    private var channelToggle: some View {
        if let subtitle = model.channelSubtitle {
            Toggle(isOn: $model.alsoRenameInSession) {
                VStack(alignment: .leading, spacing: metrics.scaled(2)) {
                    Text("Also rename in the session")
                        .font(metrics.rowSecondary)
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(metrics.chip)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!model.canPushToSession || !model.canSave)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(
                model.canPushToSession
                    ? "Rename the session where it runs, not only here"
                    : "An empty name only removes the local one"
            )
        }
    }

    // MARK: Buttons

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: metrics.controlGap) {
            if model.isFinished {
                CardButton(title: "Close", tone: .primary, help: "Done (⎋)") {
                    model.finish()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                CardButton(
                    title: model.isWorking ? "Renaming…" : "Save",
                    tone: .primary,
                    help: model.clears
                        ? "Remove the custom name (⏎)"
                        : "Save this name (⏎)",
                    enabled: model.canSave
                ) {
                    model.save()
                }
                .keyboardShortcut(.defaultAction)
                CardButton(title: "Cancel", tone: .quiet, help: "Leave the name as it is (⎋)") {
                    model.cancel()
                }
                .keyboardShortcut(.cancelAction)
            }
            Spacer(minLength: metrics.controlGap)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let status = model.status {
            Text(status)
                .font(metrics.rowSecondary)
                .foregroundStyle(model.statusIsError ? Theme.needsYou : Theme.textTertiary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
