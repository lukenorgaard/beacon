import SwiftUI

/// SPEC §18.3's warning row: a severity bar, the title with how long it has been going on, one
/// line of advice, and the button(s) the signal carries.
///
/// Everything is in the layout flow — an `HStack` of [bar | text | Spacer | buttons], with the
/// buttons stacked in their own trailing column at `controlGap` (SPEC §14's 8 pt floor) from each
/// other and from the text. Nothing is positioned over anything, which is why the row can be a
/// fixed height that `Theme.Metrics` computes from the button count.
struct SentinelWarningRow: View {
    let signal: SystemSignal
    var now: Date = Date()
    /// SPEC §18.4: a failed action's message, under this row and nowhere else.
    var inlineError: String?
    /// True while this row's Stop is waiting on the engine. The button is disabled and the row
    /// says "Stopping…" on the same line a failure would use — so the row's height is the one the
    /// window already reserved, and the label on the button never changes width mid-flight (the
    /// text column is measured from that label; a wider one would re-wrap the title inside a
    /// frame sized for the narrower one).
    var isStopping: Bool = false
    var onAction: (SystemSignalAction) -> Void = { _ in }
    /// Non-nil only when the signal names one of Lookout's own sessions.
    var onJump: (() -> Void)?

    @Environment(\.metrics) private var metrics
    @State private var showsDetails = false

    /// The same measurement the window's height was computed from (`Sentinel.layout`), so the
    /// row cannot draw itself into a frame that was sized for a different shape.
    private var layout: SentinelRowLayout {
        var measured = Sentinel.layout(for: signal, metrics: metrics, now: now)
        // `onJump` is what actually puts a Jump on screen; a signal carrying a `sessionID` the
        // caller chose not to wire up must not reserve room for one.
        if signal.sessionID != nil, onJump == nil {
            measured.buttons -= 1
        }
        return measured
    }

    private var durationLabel: String {
        Sentinel.durationText(since: signal.since, now: now)
    }

    /// The buttons this row will actually draw — `onJump` is what puts a Jump on screen, so a
    /// signal whose `sessionID` the caller did not wire up reserves no room for one.
    private var buttonLabels: [String] {
        var labels = Sentinel.buttonLabels(signal)
        if signal.sessionID != nil, onJump == nil { labels.removeAll { $0 == Sentinel.jumpLabel } }
        return labels
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: metrics.controlGap) {
                RoundedRectangle(cornerRadius: metrics.accentBarWidth / 2, style: .continuous)
                    .fill(Theme.color(for: signal.severity))
                    .frame(width: metrics.accentBarWidth)
                    .frame(maxHeight: .infinity)

                VStack(alignment: .leading, spacing: metrics.sentinelRowLineGap) {
                    // The duration keeps its place beside the title only while both fit on one
                    // line. Otherwise the title takes the whole column and `for 6m` drops to its
                    // own muted line — a title must never break mid-phrase around the duration
                    // ("Memory pressure / is critical" beside "for 6m" was the bug).
                    if layout.durationBelowTitle {
                        title
                        Text(durationLabel)
                            .font(metrics.numeral)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    } else {
                        // No `Spacer` here. An `HStack` splits its spare width between every
                        // flexible child, and a `Spacer(minLength: 0)` counts as one — it took
                        // half the line from the title, which then wrapped anyway (and pushed
                        // its advice out through the bottom of the card). The row is left-aligned
                        // by the frame instead, and the title keeps the priority.
                        HStack(alignment: .firstTextBaseline, spacing: metrics.scaled(6)) {
                            title.layoutPriority(1)
                            Text(durationLabel)
                                .font(metrics.numeral)
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let advice = signal.advice.first {
                        Text(advice)
                            .font(metrics.rowSecondary)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
                // The measured width, not a flexible one. An `HStack` splits its spare width
                // between every flexible child — with a `Spacer` beside it, a `maxWidth:
                // .infinity` text column got about half of what it was measured for, and both the
                // title and its advice wrapped out through the bottom of the card. Pinning the
                // column to `sentinelWarningTextWidth` is what makes the drawn row and the height
                // the window reserved for it the same arithmetic.
                .frame(
                    width: metrics.sentinelWarningTextWidth(buttonLabels: buttonLabels),
                    alignment: .leading
                )

                if layout.buttons > 0 {
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: metrics.controlGap) {
                        Button("Details") { showsDetails = true }
                            .buttonStyle(QuietButtonStyle(metrics: metrics))
                            .popover(isPresented: $showsDetails) { SentinelSignalDetailView(signal: signal) }
                        if let action = signal.action {
                            Button(action.label) { onAction(action) }
                                .buttonStyle(QuietButtonStyle(metrics: metrics))
                                .disabled(isStopping)
                                .accessibilityLabel(
                                    isStopping
                                        ? "Stopping \(signal.title)"
                                        : "\(action.label): \(signal.title)"
                                )
                        }
                        // SPEC §18.4: the same jump a session row does — the culprit is a
                        // session the owner can go and look at.
                        if let onJump {
                            Button(Sentinel.jumpLabel, action: onJump)
                                .buttonStyle(QuietButtonStyle(metrics: metrics))
                                .accessibilityLabel("Jump to the session behind \(signal.title)")
                        }
                        Spacer(minLength: 0)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(maxHeight: .infinity)

            // One line, two jobs: "Stopping…" while the engine is working and the failure after
            // it answers. In flight wins — a message from the previous attempt is not what is
            // happening now.
            if isStopping || inlineError != nil {
                Text(isStopping ? SentinelWarningRow.stoppingText : (inlineError ?? ""))
                    .font(metrics.caption)
                    .foregroundStyle(isStopping ? Theme.textTertiary : Theme.signalWarning)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: metrics.sentinelInlineErrorHeight, alignment: .leading)
                    .padding(.leading, metrics.accentBarWidth + metrics.controlGap)
            }
        }
        .padding(.horizontal, metrics.rowInset)
        .padding(.vertical, metrics.sentinelWarningPadding)
        .frame(
            height: metrics.sentinelWarningRowHeight(layout)
                + (isStopping || inlineError != nil ? metrics.sentinelInlineErrorHeight : 0),
            alignment: .top
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: metrics.rowCorner, style: .continuous)
                .fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.rowCorner, style: .continuous)
                .strokeBorder(
                    Theme.color(for: signal.severity).opacity(signal.severity == .critical ? 0.35 : 0.18),
                    lineWidth: metrics.stroke
                )
                .allowsHitTesting(false)
        )
        .help(signal.detail)
    }

    /// SPEC §18.4: what the row says while the engine is signalling. On its own line rather than
    /// on the button, whose label is what the text column beside it was measured against.
    static let stoppingText = "Stopping…"

    /// Up to two lines, wrapping. The button on the right leaves the title about 186 pt at 360,
    /// and "Memory pressure is critical" needs 165 of it — nothing here truncates.
    private var title: some View {
        Text(signal.title)
            .font(metrics.rowTitle)
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
