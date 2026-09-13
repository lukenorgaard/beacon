import Foundation

/// Only resource totals are retained, in memory, for at most fifteen minutes.
struct SystemResourceSample: Equatable, Identifiable {
    var sampledAt: Date
    var cpuPercent: Double
    var memoryPercent: Double
    var swapBytes: UInt64
    var id: Date { sampledAt }

    init(_ snapshot: SystemSnapshot) {
        sampledAt = snapshot.sampledAt
        cpuPercent = min(100, max(0, snapshot.cpuPercent))
        memoryPercent = snapshot.memoryTotal > 0
            ? min(100, 100 * Double(snapshot.memoryUsed) / Double(snapshot.memoryTotal)) : 0
        swapBytes = snapshot.swapUsed
    }
}

extension SystemWatchState {
    func record(_ value: SystemSnapshot) {
        snapshot = value
        let sample = SystemResourceSample(value)
        // Do not draw a line across sleep, a sampling failure or a backwards clock change.
        if let last = resourceHistory.last,
           sample.sampledAt < last.sampledAt || sample.sampledAt.timeIntervalSince(last.sampledAt) > 30 {
            resourceHistory.removeAll()
        }
        if resourceHistory.last?.sampledAt == sample.sampledAt { resourceHistory.removeLast() }
        resourceHistory.append(sample)
        resourceHistory.removeAll { $0.sampledAt < sample.sampledAt.addingTimeInterval(-900) }
        if resourceHistory.count > 181 { resourceHistory.removeFirst(resourceHistory.count - 181) }
    }
}
