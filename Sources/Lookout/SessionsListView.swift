import SwiftUI

/// Where each row is on screen, written during layout and read when a context menu fires
/// (SPEC §15.4: the rename panel opens *next to the row*).
///
/// A reference box and not `@State`: a row's frame changes on every scroll, and re-rendering the
/// whole list for a rectangle nothing draws would be the one thing the panel cannot afford.
final class RowFrames {
    private var frames: [String: CGRect] = [:]

    func set(_ frame: CGRect, for id: String) { frames[id] = frame }
    func frame(for id: String) -> CGRect { frames[id] ?? .zero }
}

struct SessionsListView: View {
    @ObservedObject var state: AppState

    @Environment(\.metrics) var metrics
    @State private var frames = RowFrames()

    var body: some View {
        Group {
            if state.visibleSessions.isEmpty {
                EmptyState(
                    symbol: "moon.zzz",
                    title: "No sessions running",
                    message: "Start Claude Code, Codex or any other agent and it shows up here."
                )
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: metrics.rowGap) {
                        ForEach(SessionSections(state.visibleSessions).items) { item in
                            switch item {
                            case .section(let title, let count):
                                SessionSectionHeader(title: title, count: count, color: Theme.familyCodex)
                            case .project(let name, let count, let codex):
                                SessionSectionHeader(
                                    title: name, count: count,
                                    color: codex ? Theme.familyCodex.opacity(0.75) : Theme.textSecondary,
                                    tracking: 0, lineOpacity: 0.12
                                )
                            case .row(let session):
                                row(session)
                            }
                        }
                    }
                    .padding(.horizontal, metrics.listInset)
                }
            }
        }
    }

    /// One session row with its context menu — shared by both sections of the list.
    @ViewBuilder
    private func row(_ session: Session) -> some View {
                    SessionRow(
                        session: session,
                        isSeen: session.state == .done && state.seen.isSeen(session.id),
                        isPinned: state.isPinned(session),
                        pricing: state.settings.pricing,
                        // SPEC §19.2/§19.3: the window the chip's percentage is
                        // measured against, and the threshold it turns red at.
                        contextWindows: state.settings.contextWindows,
                        contextWarnFraction: state.settings.contextWarnFraction,
                        onFrame: { frames.set($0, for: session.id) }
                    ) {
                        state.jump(to: session)
                    }
                    // SPEC §11.4: per-session opt-in lives in the row's menu, and
                    // SPEC §15.4's Rename… sits under it.
                    .contextMenu {
                        // SPEC §17.3.
                        Button(
                            state.isPinned(session) ? "✓ Pin to top" : "Pin to top"
                        ) {
                            state.togglePin(for: session)
                        }
                        // On hold: "finished or on hold, not closing it" — a toggle right
                        // beside Pin to top.
                        Button(
                            state.isHeld(session) ? "Resume" : "Put on hold"
                        ) {
                            state.toggleHold(for: session)
                        }
                        Button(
                            state.cardsEnabled(for: session)
                                ? "✓ Cards for this session"
                                : "Cards for this session"
                        ) {
                            state.toggleCards(for: session)
                        }
                        Button("Rename…") {
                            state.beginRename(
                                session, rowFrame: frames.frame(for: session.id)
                            )
                        }
                    }
    }
}

/// One row: accent bar, two lines of text, live duration, and a family-coloured outline around
/// the whole thing (SPEC §9.5). One accent per row, hover is a 6 % wash — nothing else moves,
/// and nothing is layered over a control: the tint is a *background*, the content sits on it.
