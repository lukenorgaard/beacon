import SwiftUI

/// The usage percentages beside the tabs — or, when the strip is full, on the header's second
/// line. Claude's session and weekly limits first; when the reporter has written
/// `codex-usage.json`, Codex's windows beside them on a second chip in the Codex family blue,
/// so the pair reads as two accounts rather than four numbers.
///
/// Each number carries its own band colour (amber from 80 %, red from 90 %), a chip glows in
/// the strongest band it holds, and every chip sits on its own opaque card — the panel's
/// ground is translucent, and a bare numeral on it was nearly invisible.
struct UsageChips: View {
    let claude: UsageSnapshot?
    let codex: CodexUsageSnapshot?

    @Environment(\.metrics) private var metrics

    /// `69% · 17%` for the Claude chip, or nil when there is nothing to show.
    static func claudeText(_ snapshot: UsageSnapshot) -> String? {
        let text = joined(claudePercents(snapshot))
        return text.isEmpty ? nil : text
    }

    /// `◇ 1% · 64%` for the Codex chip — the glyph is part of the text on purpose, so the width
    /// the fit decisions measure is the width that is drawn.
    static func codexText(_ snapshot: CodexUsageSnapshot) -> String? {
        let text = joined(codexPercents(snapshot))
        return text.isEmpty ? nil : "\(SessionAgent.codex.glyph) \(text)"
    }

    static func claudePercents(_ snapshot: UsageSnapshot) -> [Double] {
        [snapshot.sessionPercent, snapshot.weeklyPercent].compactMap { $0 }
    }

    static func codexPercents(_ snapshot: CodexUsageSnapshot) -> [Double] {
        [snapshot.primary?.usedPercent, snapshot.secondary?.usedPercent].compactMap { $0 }
    }

    /// The loudest band among the numbers on one chip drives its glow.
    static func glow(for percents: [Double]) -> UsageLevel {
        let levels = percents.map(UsageLevel.header(percent:))
        if levels.contains(.critical) { return .critical }
        if levels.contains(.warn) { return .warn }
        return .ok
    }

    private static func joined(_ percents: [Double]) -> String {
        percents.map { "\(Int($0.rounded()))%" }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: metrics.controlGap) {
            if let claude, UsageChips.claudeText(claude) != nil {
                UsageChip(percents: UsageChips.claudePercents(claude), prefix: nil, identity: nil)
            }
            if let codex, UsageChips.codexText(codex) != nil {
                UsageChip(
                    percents: UsageChips.codexPercents(codex),
                    prefix: SessionAgent.codex.glyph,
                    identity: Theme.familyCodex
                )
            }
        }
    }
}

/// One chip: numbers coloured by band, an optional agent glyph in the identity colour, on an
/// opaque card whose outline is the identity colour when there is one, else the glow colour.
struct UsageChip: View {
    let percents: [Double]
    let prefix: String?
    let identity: Color?

    @Environment(\.metrics) private var metrics

    private var glow: UsageLevel { UsageChips.glow(for: percents) }
    private var glowColor: Color { Theme.color(for: glow) }
    private var glowRadius: CGFloat { metrics.scaled(glow == .ok ? 2 : 5) }
    private var glowOpacity: Double { glow == .ok ? 0.35 : 0.75 }

    /// Built as one concatenated `Text` so it lays out exactly like the string the fit
    /// decisions measure (`UsageChips.claudeText` / `codexText`).
    private var label: Text {
        var text = Text("")
        if let prefix {
            text = text + Text("\(prefix) ").foregroundColor(identity ?? Theme.textSecondary)
        }
        for (index, percent) in percents.enumerated() {
            if index > 0 { text = text + Text(" · ").foregroundColor(Theme.textTertiary) }
            let color = Theme.color(for: UsageLevel.header(percent: percent))
            text = text + Text("\(Int(percent.rounded()))%").foregroundColor(color)
        }
        return text
    }

    var body: some View {
        label
            .font(metrics.numeral)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .shadow(color: glowColor.opacity(glowOpacity), radius: glowRadius)
            .padding(.horizontal, metrics.usageChipInset - Theme.familyStrokeWidth)
            .padding(.vertical, metrics.scaled(3))
            .background(
                ZStack {
                    let shape = RoundedRectangle(cornerRadius: metrics.scaled(6), style: .continuous)
                    shape.fill(Theme.cardBase)
                    shape.strokeBorder(
                        (identity ?? glowColor).opacity(identity == nil ? 0.28 : 0.55),
                        lineWidth: Theme.familyStrokeWidth
                    )
                }
            )
            .help(identity == nil ? "Claude session and weekly usage" : "Codex usage windows")
    }
}
