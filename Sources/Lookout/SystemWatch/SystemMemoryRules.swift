import Foundation

extension SystemRulesEngine {
    // MARK: - Memory

    func appendMemorySignals(
        _ s: SystemSnapshot, _ t: SystemThresholds, _ apps: [SystemAppLoad],
        into signals: inout [SystemSignal]
    ) {
        let top = apps.max { $0.residentBytes < $1.residentBytes }
        let offender = top.map { "\($0.name) (\(SystemFormat.bytes($0.residentBytes)))" }
            ?? "no single dominant app"

        if sustained(t.memoryCriticalSustain, { $0.memoryPressure == .critical }) {
            signals.append(SystemSignal(
                id: "memory.critical",
                severity: .critical,
                title: "Memory pressure is critical",
                detail: "\(SystemFormat.bytes(s.memoryUsed)) of \(SystemFormat.bytes(s.memoryTotal)) "
                    + "in use. Biggest user: \(offender)",
                advice: [
                    top.map { "Quitting \($0.name) frees up to \(SystemFormat.bytes($0.residentBytes))" }
                        ?? "Quit the largest app in the list below",
                    "Close unused browser tabs — each one holds its own memory",
                    "If this keeps happening, restart to clear compressed memory",
                ],
                culprit: top?.name,
                since: s.sampledAt,
                action: .openActivityMonitor
            ))
        } else if sustained(t.memoryWarningSustain, { $0.memoryPressure != .normal }) {
            signals.append(SystemSignal(
                id: "memory.warning",
                severity: .warning,
                title: "Memory is under pressure",
                detail: "\(SystemFormat.bytes(s.memoryUsed)) of \(SystemFormat.bytes(s.memoryTotal)) "
                    + "in use. Biggest user: \(offender)",
                advice: [
                    top.map {
                        "\($0.name) is holding up to \(SystemFormat.bytes($0.residentBytes)) "
                            + "across \($0.processCount) processes"
                    } ?? "Check the process list below",
                    "Close what you are not using before it gets worse",
                ],
                culprit: top?.name,
                since: s.sampledAt,
                action: .openActivityMonitor
            ))
        }
    }

    func appendSwapSignal(
        _ s: SystemSnapshot, _ t: SystemThresholds, _ apps: [SystemAppLoad],
        into signals: inout [SystemSignal]
    ) {
        guard s.swapUsed > 512 * 1024 * 1024 else { return }

        let critical = sustained(t.swapSustain, { $0.swapOutPerSecond >= t.swapoutRateCritical })
        let warning = sustained(t.swapSustain, { $0.swapOutPerSecond >= t.swapoutRateHigh })
        guard critical || warning else { return }

        let megabytesPerSecond = s.swapOutPerSecond * Double(vm_kernel_page_size) / 1_048_576

        signals.append(SystemSignal(
            id: "swap.thrash",
            severity: critical ? .critical : .warning,
            title: critical ? "The system is thrashing swap" : "Swapping heavily to disk",
            detail: String(
                format: "Writing %.1f MB/s to swap, %@ used. This is what makes everything stutter.",
                megabytesPerSecond, SystemFormat.bytes(s.swapUsed)
            ),
            advice: [
                "Free memory now — quit the biggest app rather than waiting it out",
                "Video calls and audio will glitch while this continues",
            ],
            culprit: apps.max { $0.residentBytes < $1.residentBytes }?.name,
            since: s.sampledAt,
            action: .openActivityMonitor
        ))
    }
}
