import SwiftUI

/// SPEC §18.3's first block: four equal columns — CPU, Memory, Swap, Disk free — and the thermal
/// chip on its own row underneath when the machine is not nominal.
///
/// Four columns, not a grid with a floating chip: at 360 pt each column is about 77 pt wide, and
/// the only way to keep a label whole in that is to give every column exactly the same share and
/// let the type shrink a little rather than truncate (the owner's rule: nothing clipped, nothing
/// overlapping, and "top-right" is a row of its own — so the chip gets its own row).
struct SentinelGaugesView: View {
    let snapshot: SystemSnapshot?
    var thermalChip: String?

    @Environment(\.metrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.sentinelGaugeGap) {
            HStack(spacing: metrics.sentinelGaugeGap) {
                ForEach(Sentinel.gauges(snapshot)) { gauge in
                    SentinelGaugeCard(gauge: gauge)
                }
            }
            .frame(height: metrics.sentinelGaugeHeight)

            if let thermalChip {
                Text(thermalChip)
                    .font(metrics.chip)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(Theme.signalWarning)
                    .padding(.horizontal, metrics.chipPaddingH + metrics.scaled(2))
                    .padding(.vertical, metrics.chipPaddingV + metrics.scaled(2))
                    .background(
                        RoundedRectangle(cornerRadius: metrics.chipCorner, style: .continuous)
                            .fill(Theme.signalWarning.opacity(0.16))
                    )
                    .frame(height: metrics.sentinelChipRowHeight, alignment: .leading)
            }
        }
        .padding(.horizontal, metrics.padding)
        .frame(
            height: metrics.sentinelGaugesHeight(thermalChip: thermalChip != nil),
            alignment: .top
        )
    }
}

/// One column: the label, the number, the line under it. Every string is `lineLimit(1)` with a
/// `minimumScaleFactor`, so a wide word ("MEMORY" at the Large appearance) gets a little smaller
/// instead of losing its tail — SPEC §18.3's "nothing clipped", read strictly.
struct SentinelGaugeCard: View {
    let gauge: Sentinel.Gauge

    @Environment(\.metrics) private var metrics

    private var valueColor: Color {
        guard let level = gauge.level else { return Theme.textPrimary }
        return level == .ok ? Theme.textPrimary : Theme.color(for: level)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.scaled(2)) {
            Text(gauge.label)
                .font(metrics.sectionLabel)
                .tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(gauge.value)
                .font(metrics.bigNumeral)
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text(gauge.detail)
                .font(metrics.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, metrics.scaled(7))
        .padding(.vertical, metrics.scaled(7))
        .frame(height: metrics.sentinelGaugeHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: metrics.rowCorner, style: .continuous)
                .fill(Theme.cardFill)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(gauge.label) \(gauge.value), \(gauge.detail)")
    }
}
