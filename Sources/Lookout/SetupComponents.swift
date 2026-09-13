import AppKit
import ApplicationServices
import SwiftUI
import UserNotifications

// MARK: - Pieces

/// One bordered block. Its children stack vertically, so a checkbox or a note under a row can
/// never end up on top of the row's button.
struct SetupCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    @Environment(\.metrics) var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.setupCardGap) {
            content()
        }
        .padding(metrics.scaled(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: metrics.rowCorner, style: .continuous)
                .fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.rowCorner, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: metrics.stroke)
        )
    }
}

/// Status dot, title, explanation, and whatever control the row acts with — three columns that
/// share the width; the text wraps rather than pushing the control off the card.
struct SetupHeadline<Trailing: View>: View {
    let dot: Color
    let title: String
    let message: String
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.metrics) var metrics

    var body: some View {
        HStack(alignment: .top, spacing: metrics.scaled(10)) {
            Circle()
                .fill(dot)
                .frame(width: metrics.scaled(8), height: metrics.scaled(8))
                .padding(.top, metrics.scaled(4))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: metrics.scaled(3)) {
                Text(title)
                    .font(metrics.rowTitle)
                    .foregroundStyle(Theme.textPrimary)
                Text(message)
                    .font(metrics.rowSecondary)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing()
                .padding(.leading, metrics.controlGap)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One editor in the companion card: its own dot, its own line, its own Install button — a
/// three-column row, so nothing is ever layered over the button (SPEC §16.3).
struct CompanionAppRow: View {
    let status: CompanionAppStatus
    let busy: Bool
    let enabled: Bool
    let install: () -> Void

    @Environment(\.metrics) var metrics

    var dot: Color {
        switch status.state {
        case .live: return Theme.done
        case .installable: return Theme.needsYou
        case .absent: return Theme.idle
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.scaled(10)) {
            Circle()
                .fill(dot)
                .frame(width: metrics.scaled(7), height: metrics.scaled(7))
                .accessibilityHidden(true)
            Text(status.app.label)
                .font(metrics.rowSecondary)
                .foregroundStyle(Theme.textPrimary)
                .frame(width: metrics.scaled(64), alignment: .leading)
            Text(status.state.message)
                .font(metrics.font(10.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: metrics.controlGap) {
                if busy { ProgressView().controlSize(.small).scaleEffect(0.6) }
                Button(status.state == .live ? "Reinstall" : "Install", action: install)
                    .disabled(!enabled || busy)
                    .accessibilityLabel("Install the companion in \(status.app.label)")
            }
            .controlSize(.small)
            .fixedSize()
            .padding(.leading, metrics.controlGap)
            .opacity(status.state == .absent ? 0.4 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A secondary line under a row — installer output, a blocker, the Codex trust step.
struct SetupNote: View {
    let text: String
    let tone: Color

    @Environment(\.metrics) var metrics

    var body: some View {
        Text(text)
            .font(metrics.font(10.5))
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
