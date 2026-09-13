import Foundation

extension SystemRulesEngine {
    // MARK: - CPU

    func appendCPUSignals(
        _ s: SystemSnapshot, _ t: SystemThresholds, _ apps: [SystemAppLoad],
        into signals: inout [SystemSignal]
    ) {
        if sustained(t.cpuSustain, { $0.cpuPercent >= t.cpuHigh }) {
            let top = apps.max { $0.cpuPercent < $1.cpuPercent }
            let load = s.loadAverage.first ?? 0
            signals.append(SystemSignal(
                id: "cpu.saturated",
                severity: .warning,
                title: "CPU has been saturated",
                detail: "\(SystemFormat.percent(s.cpuPercent)) across \(s.coreCount) cores for "
                    + "\(Int(t.cpuSustain))s. Load average \(String(format: "%.1f", load)). "
                    + (top.map { "Top: \($0.name) at \(SystemFormat.percent($0.cpuPercent))" } ?? ""),
                advice: [
                    top.map {
                        "\($0.name) is the biggest consumer — pause or quit it if you are not using it"
                    } ?? "Check the process list below",
                    "Everything interactive will feel laggy until this drops",
                ],
                culprit: top?.name,
                since: s.sampledAt,
                // The engine cannot tell whether the culprit is one of Lookout's own discovered
                // agent processes (SPEC §18.4), so this rule never carries a Stop button.
                action: .openActivityMonitor
            ))
        }

        appendRunawaySignals(s, t, into: &signals)
        appendChromeMemorySignal(s, t, into: &signals)
        appendOrphanSignal(s, into: &signals)
    }

    /// Orphan detection must be sure
    /// about *what* it is naming. `SystemOrphans` does that work: a candidate reaches here only
    /// with an automation marker on its command line and no service path or service-ish name
    /// (see the note there — the first version of this rule offered Stop on ssh-agent).
    ///
    /// Even so the wording hedges and the severity is capped at `.warning`. The classification is
    /// evidence, not proof: the process may be abandoned, and Stop still asks first (SPEC §18.4).
    private func appendOrphanSignal(_ s: SystemSnapshot, into signals: inout [SystemSignal]) {
        guard !s.orphans.isEmpty else { return }
        let total = s.orphanCPU
        guard total >= 40 else { return }

        // A short window: these do not resolve on their own, and a minute of a dozen pinned cores
        // is already worth interrupting someone for. The sample floor rides on the cadence
        // (`sustained`), so this window survives a change to how often the engine samples.
        guard sustained(45, { $0.orphanCPU >= 40 }) else { return }

        let cores = total / 100
        let byName = Self.groupByName(s.orphans)

        let headline = byName.prefix(3)
            .map { $0.count > 1 ? "\($0.count)× \($0.name)" : $0.name }
            .joined(separator: ", ")

        let oldest: TimeInterval = s.orphans.map(\.elapsed).max() ?? 0

        var detail = "\(s.orphans.count) process\(s.orphans.count == 1 ? "" : "es") "
            + "(\(headline)) are using \(SystemFormat.percent(total)) — "
            + String(format: "%.1f of your %d cores", cores, s.coreCount)
        // Which parent exited cannot be recovered — the kernel replaces a dead parent with launchd
        // before anything can read it — so the text names the parent they have now and says what
        // that means, rather than claiming to know what left them behind.
        detail += ". They may be abandoned: their own parent has exited and launchd (pid 1) "
            + "adopted them, so nothing is waiting on their output. The oldest has been running "
            + "\(SystemFormat.duration(oldest))."

        let worst = s.orphans.max { $0.cpuPercent < $1.cpuPercent }

        signals.append(SystemSignal(
            id: "process.orphaned",
            // Never critical: this is an inference about someone else's process, and a critical
            // signal colours the menu-bar dot and sends a time-sensitive notification.
            severity: .warning,
            title: "Processes that may be abandoned are burning CPU",
            detail: detail,
            advice: [
                "Check what it is before stopping it — Stop asks first, and it only signals the "
                    + "process if the pid is still the same executable",
                byName.first.map { "\($0.name): \(reasonText(for: $0.name, in: s.orphans))" }
                    ?? "Check what launched them",
                "These usually come from scripts and agents interrupted before they could clean up",
            ],
            culprit: byName.first?.name,
            since: s.sampledAt,
            action: worst.map { .stopProcess(pid: $0.pid, name: $0.name) }
        ))
    }

    /// Orphans of the same name are one thing to a human: "4× yes", not four rows.
    private struct OrphanGroup {
        var name: String
        var count: Int
        var cpuPercent: Double
    }

    private static func groupByName(_ orphans: [OrphanedProcess]) -> [OrphanGroup] {
        var grouped: [String: OrphanGroup] = [:]
        for orphan in orphans {
            var entry = grouped[orphan.name]
                ?? OrphanGroup(name: orphan.name, count: 0, cpuPercent: 0)
            entry.count += 1
            entry.cpuPercent += orphan.cpuPercent
            grouped[orphan.name] = entry
        }
        return grouped.values.sorted {
            $0.cpuPercent == $1.cpuPercent ? $0.name < $1.name : $0.cpuPercent > $1.cpuPercent
        }
    }

    private func reasonText(for name: String, in orphans: [OrphanedProcess]) -> String {
        orphans.first { $0.name == name }?.reason ?? "no parent process left"
    }

    /// WindowServer and network extensions are invisible in normal usage but are two of the most
    /// common causes of "everything feels slow" on a machine with plenty of RAM.
    func appendHelperSignals(
        _ s: SystemSnapshot, _ t: SystemThresholds, into signals: inout [SystemSignal]
    ) {
        if s.windowServerCPU >= t.windowServerCPU,
           sustained(t.helperSustain, { $0.windowServerCPU >= t.windowServerCPU }) {
            signals.append(windowServerSignal(load: s.windowServerCPU, at: s.sampledAt))
        }

        // The aggregate is already summed by the sampler, so the marker scan — which lowercases a
        // name and searches it for seventeen tokens — only runs once the rule is otherwise sure.
        if s.networkExtensionCPU >= t.networkExtensionCPU,
           sustained(t.helperSustain, { $0.networkExtensionCPU >= t.networkExtensionCPU }),
           let worst = s.processes
               .filter({ SystemMarkers.matches($0.name, any: SystemMarkers.networkExtension) })
               .max(by: { $0.cpuPercent < $1.cpuPercent }) {
            signals.append(SystemSignal(
                id: "helper.networkextension",
                severity: .warning,
                title: "\(worst.actionableName) is eating CPU",
                detail: "This VPN or security extension is at "
                    + "\(SystemFormat.percent(s.networkExtensionCPU)). It sits in the path of every "
                    + "network packet, so it degrades calls and downloads.",
                advice: [
                    "Disconnect the VPN while you are on a video call",
                    "Quit and relaunch \(worst.actionableName) — these extensions leak CPU over time",
                ],
                culprit: worst.actionableName,
                since: s.sampledAt,
                action: .openActivityMonitor
            ))
        }
    }

    /// WindowServer's cost is per-frame, not per-window: it composites every display, every
    /// refresh, whether or not anything changed. The Sentinel app measured the exact pixel budget
    /// of the attached displays to say how much a refresh-rate change would save; Lookout has no
    /// display sampler, so the advice keeps the same order without the measured numbers.
    private func windowServerSignal(load: Double, at sampledAt: Date) -> SystemSignal {
        SystemSignal(
            id: "helper.windowserver",
            severity: .warning,
            title: "WindowServer is overloaded",
            detail: "WindowServer is at \(SystemFormat.percent(load)). It composites every display "
                + "on every refresh, so this shows up as lag in scrolling, typing and screen sharing.",
            advice: [
                "Drop a high-refresh display to 60 Hz — it cuts the frames it has to composite "
                    + "and nothing on screen moves",
                "Animated or video-heavy content in a background window is the usual cause",
                "A screen recording or screen share also keeps WindowServer at full tilt",
            ],
            culprit: "WindowServer",
            since: sampledAt,
            action: .openActivityMonitor
        )
    }
}
