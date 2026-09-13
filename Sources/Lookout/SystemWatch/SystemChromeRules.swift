import Foundation

extension SystemRulesEngine {
    /// A pinned core is an observation, not proof of a loop: legitimate serial work looks similar.
    func appendRunawaySignals(
        _ s: SystemSnapshot, _ t: SystemThresholds, into signals: inout [SystemSignal]
    ) {
        let candidates = s.processes.filter { $0.cpuPercent >= t.runawayCPU && $0.cpuPercent <= 135 }
            .sorted { $0.cpuPercent > $1.cpuPercent }
        var reported: Set<String> = []
        for candidate in candidates {
            guard !reported.contains(candidate.actionableName), reported.count < 3,
                  sustained(t.runawaySustain, { snapshot in
                      snapshot.processes.contains {
                          self.sameProcess($0, candidate) && $0.cpuPercent >= t.runawayCPU
                              && $0.cpuPercent <= 135
                      }
                  }) else { continue }
            reported.insert(candidate.actionableName)
            let chrome = candidate.identity?.isChromeHelper == true
            signals.append(SystemSignal(
                id: "cpu.runaway.\(candidate.actionableName)", severity: .warning,
                title: "\(candidate.actionableName) has sustained high CPU",
                detail: "\(candidate.name) (pid \(candidate.pid)) is using "
                    + "\(SystemFormat.percent(candidate.cpuPercent)) of one core across recent samples "
                    + "over \(Int(t.runawaySustain)) seconds. It may be busy or stuck; CPU alone cannot tell.",
                advice: chrome ? Self.chromeAdvice : [
                    "Inspect the process in Activity Monitor before deciding whether to quit it",
                    "A build, export or calculation can legitimately keep one core busy",
                ],
                culprit: candidate.actionableName, since: s.sampledAt,
                action: chrome ? .stopProcess(pid: candidate.pid, name: candidate.name) : .openActivityMonitor
            ))
        }
    }

    func appendChromeMemorySignal(
        _ s: SystemSnapshot, _ t: SystemThresholds, into signals: inout [SystemSignal]
    ) {
        // A large browser process alone is not a leak. Require pressure on the whole Mac as well.
        let floor = max(UInt64(2) << 30, s.memoryTotal / 10)
        let candidates = s.processes.filter {
            $0.identity?.isChromeHelper == true && $0.residentBytes >= floor
        }.sorted { $0.residentBytes > $1.residentBytes }
        guard let candidate = candidates.first(where: { candidate in
            sustained(t.runawaySustain) { snapshot in
                snapshot.memoryPressure != .normal && snapshot.processes.contains {
                    self.sameProcess($0, candidate) && $0.residentBytes >= floor
                }
            }
        }) else { return }
        signals.append(SystemSignal(
            id: "memory.chrome-helper", severity: .warning,
            title: "A Chrome helper is using substantial memory",
            detail: "\(candidate.name) (pid \(candidate.pid)) uses "
                + "\(SystemFormat.bytes(candidate.residentBytes)) while macOS reports memory pressure. "
                + "Both conditions persisted across recent samples. This does not prove a memory leak.",
            advice: Self.chromeAdvice, culprit: "Google Chrome", since: s.sampledAt,
            action: .stopProcess(pid: candidate.pid, name: candidate.name)
        ))
    }

    private func sameProcess(_ left: SystemProcessLoad, _ right: SystemProcessLoad) -> Bool {
        left.pid == right.pid && left.name == right.name && left.identity == right.identity
    }

    private static let chromeAdvice = [
        "In Chrome, open More tools → Task manager to identify the tab or extension first",
        "Stop asks for confirmation and targets this helper only; one helper may serve several tabs",
        "Stopping it can reload tabs or lose unsaved work. Close an identified tab normally when possible",
    ]
}
