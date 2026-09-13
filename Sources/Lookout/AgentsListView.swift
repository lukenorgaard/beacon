import SwiftUI

/// SPEC §12.3: every live sub-agent across every session, in parent-session order then start
/// time. A click lands in the parent session — a sub-agent has no window of its own.
struct AgentsListView: View {
    @ObservedObject var state: AppState

    @Environment(\.metrics) private var metrics

    @ViewBuilder
    private func overflowMask(rows: Int) -> some View {
        if metrics.agentListOverflows(rows: rows) {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.86),
                    .init(color: .black.opacity(0.08), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        } else {
            Color.black
        }
    }

    var body: some View {
        Group {
            if state.subagents.isEmpty {
                EmptyState(
                    symbol: "arrow.triangle.branch",
                    title: "No sub-agents running",
                    message: "Sub-agents a session spawns show up here while they work."
                )
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: metrics.rowGap) {
                        ForEach(state.subagents) { entry in
                            SubagentRow(entry: entry) {
                                state.jump(to: entry.session)
                            }
                        }
                    }
                    .padding(.horizontal, metrics.listInset)
                }
                .mask(overflowMask(rows: state.subagents.count))
            }
        }
    }
}

/// One sub-agent: what it is doing, what it is, whose session it belongs to, how long it has
/// been at it (SPEC §12.3).
struct SubagentRow: View {
    let entry: LiveSubagent
    let onTap: () -> Void

    @Environment(\.metrics) private var metrics
    @State private var hovering = false

    private var family: Color { Theme.color(for: entry.session.family) }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: metrics.rowInset) {
                Image(systemName: "arrow.triangle.branch")
                    .font(metrics.font(10, .medium))
                    .foregroundStyle(family)
                    .frame(width: metrics.glyphSize)

                VStack(alignment: .leading, spacing: metrics.scaled(3)) {
                    HStack(spacing: metrics.scaled(6)) {
                        Text(entry.headline)
                            .font(metrics.rowTitle)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let chip = entry.chip {
                            ModelChip(text: chip, color: family, help: entry.chipTooltip)
                        }
                    }
                    HStack(spacing: metrics.scaled(5)) {
                        // SPEC §15.4: the parent's custom name when it has one, else its
                        // project — a two-line row has room for exactly one of them.
                        Text(entry.parentLabel)
                            .font(metrics.rowSecondary)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HostChip(host: entry.session.host)
                    }
                }

                Spacer(minLength: metrics.controlGap)

                if entry.hasElapsed {
                    Text(Format.duration(entry.elapsed()))
                        .font(metrics.numeral)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, metrics.rowInset)
            .frame(height: metrics.agentRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack {
                    let shape = RoundedRectangle(cornerRadius: metrics.rowCorner, style: .continuous)
                    shape.fill(family.opacity(Theme.familyFill))
                    if hovering { shape.fill(Theme.hoverFill) }
                    shape.strokeBorder(
                        family.opacity(Theme.familyStrokeDiscovered),
                        lineWidth: Theme.familyStrokeWidth
                    )
                }
            )
            .contentShape(RoundedRectangle(cornerRadius: metrics.rowCorner, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(entry.tooltip)
    }
}
