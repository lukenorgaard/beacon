import Foundation

/// The numbers a rule fires at (SPEC §18.2), and how sensitivity moves them. Straight from the
/// Sentinel app's `Thresholds`, including the values `.early` overrides outright.
struct SystemThresholds: Equatable {
    var cpuHigh: Double = 85
    var cpuSustain: TimeInterval = 90

    var memoryWarningSustain: TimeInterval = 60
    var memoryCriticalSustain: TimeInterval = 20

    /// Pages per second written to swap. At a 16 KB page, 400 p/s ≈ 6 MB/s of thrash.
    var swapoutRateHigh: Double = 400
    var swapoutRateCritical: Double = 1500
    var swapSustain: TimeInterval = 30

    var runawayCPU: Double = 95
    var runawaySustain: TimeInterval = 120

    var windowServerCPU: Double = 35
    var networkExtensionCPU: Double = 25
    var helperSustain: TimeInterval = 60

    var diskWarnFraction: Double = 0.10
    var diskWarnBytes: UInt64 = 30 * 1024 * 1024 * 1024
    var diskCriticalFraction: Double = 0.05
    var diskCriticalBytes: UInt64 = 12 * 1024 * 1024 * 1024

    var thermalSustain: TimeInterval = 30

    var uptimeInfoDays: Double = 7
    var uptimeWarnDays: Double = 14

    var processCountHigh: Int = 950

    static func scaled(for sensitivity: SystemWatchSensitivity) -> SystemThresholds {
        var thresholds = SystemThresholds()
        let scale = sensitivity.scale
        thresholds.cpuSustain *= scale
        thresholds.memoryWarningSustain *= scale
        thresholds.memoryCriticalSustain *= scale
        thresholds.swapSustain *= scale
        thresholds.runawaySustain *= scale
        thresholds.helperSustain *= scale
        thresholds.thermalSustain *= scale

        if sensitivity == .early {
            thresholds.cpuHigh = 75
            thresholds.runawayCPU = 85
            thresholds.windowServerCPU = 25
            thresholds.networkExtensionCPU = 18
            thresholds.diskWarnFraction = 0.15
            thresholds.diskWarnBytes = 50 * 1024 * 1024 * 1024
            thresholds.uptimeInfoDays = 5
            thresholds.uptimeWarnDays = 9
        }
        return thresholds
    }
}

/// Numbers as a warning says them out loud. The tab formats its own gauges; this exists because
/// the advice strings are sentences, and a sentence cannot hold a `UInt64`.
enum SystemFormat {
    static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var scaled = Double(value)
        var unit = 0
        while scaled >= 1024, unit < units.count - 1 {
            scaled /= 1024
            unit += 1
        }
        return unit <= 1
            ? String(format: "%.0f %@", scaled, units[unit])
            : String(format: "%.1f %@", scaled, units[unit])
    }

    static func percent(_ value: Double) -> String { String(format: "%.0f%%", value) }

    static func duration(_ interval: TimeInterval) -> String {
        let days = Int(interval / 86400)
        let hours = Int(interval.truncatingRemainder(dividingBy: 86400) / 3600)
        let minutes = Int(interval.truncatingRemainder(dividingBy: 3600) / 60)
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

extension SystemSnapshot {
    var orphanCPU: Double { orphans.reduce(0) { $0 + $1.cpuPercent } }
    var diskUsedFraction: Double { 1 - diskFreeFraction }
    var coreCount: Int { cpuPerCore.count }
}
