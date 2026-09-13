import AppKit
import SwiftUI

/// `ASKS`, `SUGGESTION` — the quiet label above a section.
struct CardSectionLabel: View {
    let text: String

    @Environment(\.metrics) var metrics

    var body: some View {
        Text(text.uppercased())
            .font(metrics.sectionLabel)
            .tracking(0.8)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// The full command, monospaced, at most six lines and scrolling past that (SPEC §11.4).
struct CommandBox: View {
    let text: String

    @Environment(\.metrics) var metrics

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            Text(text)
                .font(metrics.mono)
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(metrics.commandBoxPadding)
        }
        .frame(maxHeight: metrics.commandBoxMaxHeight)
        .background(
            RoundedRectangle(cornerRadius: metrics.scaled(8), style: .continuous)
                .fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.scaled(8), style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: metrics.stroke)
                .allowsHitTesting(false)
        )
    }
}

/// One preset button (SPEC §17.4): smaller and quieter than `CardButton`, because there may be
/// up to nine of them in a row that must not compete with Send and Copy & go for attention.
struct PresetChip: View {
    let preset: AnswerPreset
    let action: () -> Void

    @Environment(\.metrics) var metrics
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(preset.text)
                .font(metrics.chip)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, metrics.chipPaddingH + metrics.scaled(2))
                .padding(.vertical, metrics.chipPaddingV + metrics.scaled(2))
                .background(
                    RoundedRectangle(cornerRadius: metrics.chipCorner, style: .continuous)
                        .fill(Color.white.opacity(hovering ? 0.14 : 0.09))
                )
                .contentShape(
                    RoundedRectangle(cornerRadius: metrics.chipCorner, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(
            preset.keyBinding.map { "\(preset.text) (⌘\($0))" } ?? preset.text
        )
        .accessibilityLabel(preset.text)
    }
}

/// One card button. Flat, never smaller than its label or than the 24 pt hit target — the row
/// spaces them with the 8 pt gap, so nothing here has to fight for room.
struct CardButton: View {
    enum Tone {
        case primary
        case secondary
        case danger
        case quiet
    }

    let title: String
    var tone: Tone = .secondary
    var help: String = ""
    var enabled: Bool = true
    let action: () -> Void

    @Environment(\.metrics) var metrics
    @State private var hovering = false

    private var foreground: Color {
        guard enabled else { return Theme.textTertiary }
        switch tone {
        case .primary: return Theme.textPrimary
        case .secondary: return Theme.textPrimary
        case .danger: return Theme.usageCritical
        case .quiet: return Theme.textSecondary
        }
    }

    var fill: Color {
        guard enabled else { return Color.white.opacity(0.04) }
        switch tone {
        case .primary: return Theme.working.opacity(hovering ? 0.42 : 0.30)
        case .secondary: return Color.white.opacity(hovering ? 0.14 : 0.09)
        case .danger: return Theme.usageCritical.opacity(hovering ? 0.24 : 0.16)
        case .quiet: return Color.white.opacity(hovering ? 0.10 : 0.05)
        }
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(metrics.control)
                .foregroundStyle(foreground)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, metrics.scaled(11))
                .frame(height: metrics.buttonHeight)
                .background(
                    RoundedRectangle(cornerRadius: metrics.scaled(7), style: .continuous)
                        .fill(fill)
                )
                .contentShape(
                    RoundedRectangle(cornerRadius: metrics.scaled(7), style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 && enabled }
        .help(help)
        .accessibilityLabel(title)
    }
}
