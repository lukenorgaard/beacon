import SwiftUI

struct SessionRow: View {
    let session: Session
    let isSeen: Bool
    /// SPEC §17.3: pinned sessions keep a small pin glyph, whatever the active order is.
    var isPinned: Bool = false
    /// SPEC §17.6: what the cost chip prices tokens against. Defaulting to `.standard` keeps
    /// every existing call site (tests included) compiling without threading Settings through.
    var pricing: PricingTable = .standard
    /// SPEC §19.3: the per-model context windows the chip's percentage is measured against.
    /// Defaulted like `pricing`, so no existing call site has to thread Settings through.
    var contextWindows: ContextWindows = .standard
    /// SPEC §19.2: at or above this the chip turns red — Settings → General → Usage.
    var contextWarnFraction: Double = ContextGauge.defaultWarnFraction
    /// SPEC §15.4: where this row is, in the window's coordinates, so Rename… can open beside
    /// it. Reported on every layout; nothing here reads it back.
    var onFrame: (CGRect) -> Void = { _ in }
    let onTap: () -> Void

    @Environment(\.metrics) var metrics
    @State private var hovering = false

    var accent: Color {
        // On hold: a plain grey — neither a state colour nor idle's own (SPEC: "no coloured
        // left bar accent or the idle one"). `needs_you` always wins regardless.
        if session.isEffectivelyHeld { return Theme.held }
        let base = Theme.color(for: session.state)
        return isSeen ? base.opacity(0.45) : base
    }

    /// SPEC §9.5. Discovered rows outline at 25 %, everything else at 45 %.
    var family: Color { Theme.color(for: session.family) }

    /// SPEC §17.6: `≈ $0.42`, or nil when the reporter has recorded no tokens for this session
    /// yet. The "≈" says plainly that this is an API-price estimate, not a subscription charge.
    private var costChip: String? {
        session.cost(pricing: pricing).map(PricingTable.formatEstimate)
    }

    /// SPEC §19.2: this session's context reading, or nil when the reporter has measured
    /// nothing for it yet (and after a compaction, until it measures again) — then there is no
    /// chip at all, not a chip that says zero.
    private var contextGauge: ContextGauge? {
        session.contextGauge(windows: contextWindows)
    }

    /// SPEC §19.2/§19.4: line 2 — the session's own name, with the context chip right-aligned
    /// after it. The chip is what yields: when the row is too narrow to hold both it and the
    /// first `contextNameFloor` characters of the name, the chip is dropped outright rather than
    /// clipped mid-glyph, and the name keeps the whole line.
    @ViewBuilder
    private var nameLine: some View {
        let gauge = contextGauge
        let over = gauge?.isOverThreshold(contextWarnFraction) ?? false
        let showsChip = gauge.map {
            metrics.contextChipFits(
                name: session.displayName, chip: $0.percentText, dot: over, pinned: isPinned
            )
        } ?? false
        if session.displayName != nil || showsChip {
            HStack(spacing: 0) {
                if let name = session.displayName {
                    Text(name)
                        .font(metrics.rowSecondary)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(session.sessionNameIsPath ? .middle : .tail)
                }
                if let gauge, showsChip {
                    // A `Spacer` and not a padding: the chip sits at the trailing edge of its
                    // own line, never on top of the name, with `controlGap` of air at worst.
                    Spacer(minLength: metrics.controlGap)
                    ContextChip(
                        text: gauge.percentText, isOver: over, help: gauge.tooltip()
                    )
                    .layoutPriority(1)
                }
            }
        }
    }

    private var familyStroke: Double {
        session.state == .running ? Theme.familyStrokeDiscovered : Theme.familyStroke
    }

    /// A zero-size background that measures the row and hands its rectangle up (SPEC §15.4).
    /// It draws nothing and hit-tests nothing, so it cannot come between a click and the row.
    private var frameReporter: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onFrame(proxy.frame(in: .global)) }
                .onChange(of: proxy.frame(in: .global)) { _, frame in onFrame(frame) }
        }
        .allowsHitTesting(false)
    }

    /// Fill, then the hover wash, then the outline — the outline last so the hover state never
    /// washes it out, which is the one ordering that keeps both readable.
    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.rowCorner, style: .continuous)
        return ZStack {
            shape.fill(Theme.cardBase)
            shape.fill(family.opacity(Theme.familyFill))
            if hovering { shape.fill(Theme.hoverFill) }
            shape.strokeBorder(
                family.opacity(familyStroke), lineWidth: Theme.familyStrokeWidth
            )
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: metrics.rowInset) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(accent)
                    .frame(width: metrics.accentBarWidth, height: metrics.accentBarHeight)

                VStack(alignment: .leading, spacing: metrics.scaled(3)) {
                    HStack(spacing: metrics.scaled(6)) {
                        Text(session.project)
                            .font(metrics.rowTitle)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            // The one thing that gives way under pressure, and only by
                            // truncating: a row without its project name is not a row.
                            .layoutPriority(0)
                        HostChip(host: session.host)
                            .layoutPriority(1)
                        // SPEC §12.3: a tool event running in a worktree says so here, after
                        // the host chip — the title and the jump keep using the main session's
                        // own project.
                        //
                        // Measured at the panel's 360 pt: the project, the host chip and *one*
                        // more chip is all line 1 holds (a worktree name alone is 118 pt). So
                        // the worktree takes that slot when there is one — it is the fact that
                        // explains a confusing row — and the model and the sub-agent count fall
                        // back to the tooltip, which line 2 and the family outline already
                        // echo. Four chips would either overflow the row or truncate every one
                        // of them into noise.
                        if let worktree = session.worktreeChip {
                            WorktreeChip(text: worktree, help: session.worktreeTooltip)
                                .layoutPriority(1)
                        } else {
                            SubagentChip(count: session.subagents.count)
                                .layoutPriority(1)
                            // SPEC §9.5: the model chip takes the glyph's place when the
                            // reporter named a model; the glyph is what a session without one
                            // still gets.
                            if let chip = session.modelChip {
                                ModelChip(
                                    text: chip,
                                    color: family,
                                    help: session.modelTooltip ?? session.agent.display
                                )
                                .layoutPriority(1)
                            } else {
                                AgentGlyph(agent: session.agent)
                                    .layoutPriority(1)
                            }
                        }
                    }

                    // SPEC §15.3: the session's own name, under the folder it runs in. One
                    // line, truncated — never wrapped, because the row height is fixed.
                    // SPEC §15.4: a name the owner gave it wins over the one it computed.
                    // SPEC §19.2: and the context chip on the right of the same line.
                    nameLine

                    HStack(spacing: metrics.scaled(5)) {
                        // Priority, not `fixedSize`: the status keeps its full width whenever
                        // it fits — which is every ordinary label — but it can still give way
                        // instead of shoving the whole row past the edge of the panel.
                        Text(session.statusLabel)
                            .font(metrics.rowSecondary)
                            .foregroundStyle(accent)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(1)
                        if let secondary = session.rowDetail, !secondary.isEmpty {
                            Text("·")
                                .font(metrics.rowSecondary)
                                .foregroundStyle(Theme.textTertiary)
                            Text(secondary)
                                .font(metrics.rowSecondary)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        // SPEC §17.6: the session's running cost, right side of line 3 — only
                        // when the reporter has actually recorded tokens for it.
                        if let costChip {
                            Spacer(minLength: metrics.controlGap)
                            Text(costChip)
                                .font(metrics.chip)
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .help(session.costTooltip(pricing: pricing) ?? costChip)
                        }
                    }
                }
                // The three text lines get the width first; the duration asks for exactly what
                // it needs and no more.
                .layoutPriority(1)

                Spacer(minLength: metrics.controlGap)
                // SPEC §17.3: a small pin glyph, its own element beside the duration rather than
                // layered over anything — pinned sessions are rare enough that line 1's already
                // tight budget (SPEC §12.3) is better left alone.
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(metrics.font(9, .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .accessibilityLabel("Pinned")
                        .help("Pinned to the top")
                }
                DurationLabel(session: session)
            }
            .padding(.horizontal, metrics.rowInset)
            .frame(height: metrics.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .background(frameReporter)
            .contentShape(RoundedRectangle(cornerRadius: metrics.rowCorner, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(session.tooltip)
    }
}

/// Ticks once a second, and only while the panel is on screen — the view does not exist
/// otherwise, so nothing runs in the background (SPEC §5.6).
struct DurationLabel: View {
    let session: Session

    @Environment(\.metrics) var metrics

    /// Seconds matter for the first minute; after that the label only ever says `3m` or
    /// `1h 12m`, so there is nothing to redraw ten times as often.
    private var cadence: TimeInterval {
        session.timeInState() < 60 ? 1 : 10
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: cadence)) { context in
            Text(Format.duration(session.timeInState(now: context.date)))
                .font(metrics.numeral)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

struct HostChip: View {
    let host: SessionHost

    @Environment(\.metrics) var metrics

    var body: some View {
        Text(host.chip)
            .font(metrics.chip)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, metrics.chipPaddingH)
            .padding(.vertical, metrics.chipPaddingV)
            .background(
                RoundedRectangle(cornerRadius: metrics.chipCorner, style: .continuous)
                    .fill(Theme.chipFill)
            )
    }
}

/// `⑂ 3` — how many sub-agents this session has running (SPEC §9.3). Same chip as the host,
/// so line 1 keeps one visual rhythm; nothing at all when the count is zero, which keeps the
/// row height and the row's spacing exactly as they were.
struct SubagentChip: View {
    let count: Int

    @Environment(\.metrics) var metrics

    var body: some View {
        if count > 0 {
            HStack(spacing: metrics.scaled(3)) {
                Image(systemName: "arrow.triangle.branch")
                    .font(metrics.font(9, .medium))
                Text("\(count)")
                    .font(metrics.chip)
                    .monospacedDigit()
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, metrics.chipPaddingH)
            .padding(.vertical, metrics.chipPaddingV)
            .background(
                RoundedRectangle(cornerRadius: metrics.chipCorner, style: .continuous)
                    .fill(Theme.chipFill)
            )
            .accessibilityLabel("\(count) sub-agents")
            .help(count == 1 ? "1 sub-agent" : "\(count) sub-agents")
        }
    }
}

/// `⎇ wt-export-import` — the worktree a tool event is running in (SPEC §12.3). Same
/// shape and height as the host chip beside it, so line 1 keeps one rhythm.
struct WorktreeChip: View {
    let text: String
    let help: String

    @Environment(\.metrics) var metrics

    var body: some View {
        Text(text)
            .font(metrics.chip)
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, metrics.chipPaddingH)
            .padding(.vertical, metrics.chipPaddingV)
            .background(
                RoundedRectangle(cornerRadius: metrics.chipCorner, style: .continuous)
                    .fill(Theme.chipFill)
            )
            .help(help)
    }
}

/// `Fable`, `GPT-5.6`, `Llama · Local` — the model behind the session, in its family colour
/// (SPEC §9.5). Same shape as the host chip, so line 1 keeps one rhythm and one height.
struct ModelChip: View {
    let text: String
    let color: Color
    let help: String

    @Environment(\.metrics) var metrics

    var body: some View {
        Text(text)
            .font(metrics.chip)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(color)
            .padding(.horizontal, metrics.chipPaddingH)
            .padding(.vertical, metrics.chipPaddingV)
            .background(
                RoundedRectangle(cornerRadius: metrics.chipCorner, style: .continuous)
                    .fill(color.opacity(Theme.familyChipFill))
            )
            .help(help)
    }
}

/// `ctx 24 %` — how full this session's context is (SPEC §19.2). Muted like the cost chip on
/// the line below it; at or above the threshold it turns the usage red and grows a small filled
/// dot in front, which is the only thing on a row that ever asks for a compaction. No pill
/// behind it: line 2 is type, and a second chip shape here would fight line 1's rhythm.
struct ContextChip: View {
    let text: String
    let isOver: Bool
    let help: String

    @Environment(\.metrics) var metrics

    var body: some View {
        HStack(spacing: metrics.contextDotGap) {
            if isOver {
                Circle()
                    .fill(Theme.usageCritical)
                    .frame(width: metrics.contextDotSize, height: metrics.contextDotSize)
            }
            Text(text)
                .font(metrics.chip)
                .foregroundStyle(isOver ? Theme.usageCritical : Theme.textTertiary)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .help(help)
        .accessibilityLabel(isOver ? "\(text), over the compact threshold" : text)
    }
}

/// ✦ claude, ◇ codex, otherwise the agent's first letter in a small circle — no whitelist.
struct AgentGlyph: View {
    let agent: SessionAgent

    @Environment(\.metrics) var metrics

    var body: some View {
        if agent.glyphIsLetter {
            Text(agent.glyph)
                .font(metrics.glyphLetter)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: metrics.glyphSize, height: metrics.glyphSize)
                .background(Circle().fill(Theme.chipFill))
                .help(agent.display)
        } else {
            Text(agent.glyph)
                .font(metrics.glyph)
                .foregroundStyle(Theme.textTertiary)
                .help(agent.display)
        }
    }
}
