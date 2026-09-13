import SwiftUI

struct SentinelHistoryView: View {
    var samples: [SystemResourceSample]
    @Environment(\.metrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.scaled(5)) {
            HStack {
                Text("RECENT HISTORY").font(metrics.sectionLabel)
                Spacer()
                Text(duration).font(metrics.caption)
            }
            HStack(spacing: metrics.controlGap) {
                chart("CPU", values: samples.map(\.cpuPercent), color: .blue)
                chart("Memory", values: samples.map(\.memoryPercent), color: .orange)
            }
            Text(swapText).font(metrics.caption).lineLimit(1)
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, metrics.rowInset)
        .frame(height: metrics.sentinelHistoryHeight)
        .accessibilityElement(children: .combine)
        .help("Up to 15 minutes in memory only. Gaps reset the charts. CPU and memory use a 0–100% scale.")
    }

    private var duration: String {
        guard let first = samples.first, let last = samples.last, samples.count > 1 else {
            return "Collecting samples…"
        }
        return Format.duration(last.sampledAt.timeIntervalSince(first.sampledAt)) + " · in memory"
    }

    private var swapText: String {
        guard let first = samples.first, let last = samples.last else { return "Waiting for resource samples" }
        return "Swap: \(Sentinel.memoryText(last.swapBytes)) · started at \(Sentinel.memoryText(first.swapBytes))"
    }

    private func chart(_ label: String, values: [Double], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label + (values.last.map { " · \(Int($0))%" } ?? " · —"))
                .font(metrics.caption)
            GeometryReader { geometry in
                Path { path in
                    guard values.count > 1, let first = samples.first, let last = samples.last else { return }
                    let duration = max(1, last.sampledAt.timeIntervalSince(first.sampledAt))
                    for index in values.indices {
                        let point = CGPoint(
                            x: geometry.size.width * samples[index].sampledAt.timeIntervalSince(first.sampledAt) / duration,
                            y: geometry.size.height * (1 - values[index] / 100)
                        )
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }.stroke(color, lineWidth: 1.5)
            }.frame(height: metrics.scaled(30))
                .background(Theme.cardFill)
                .accessibilityHidden(true)
        }
    }
}

struct SentinelSignalDetailView: View {
    var signal: SystemSignal
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(signal.title).font(.headline)
                Text(signal.detail)
                Text("What you can do").font(.headline)
                ForEach(Array(signal.advice.enumerated()), id: \.offset) { item in
                    Text("\(item.offset + 1). \(item.element)")
                }
                Text("Warnings are observations, not a diagnosis. Actions require your decision.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }.frame(width: 340, height: 300)
            .textSelection(.enabled)
    }
}
