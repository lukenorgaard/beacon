import Foundation

extension SystemRulesEngine {
    // MARK: - Disk

    func appendDiskSignal(
        _ s: SystemSnapshot, _ t: SystemThresholds, into signals: inout [SystemSignal]
    ) {
        guard s.diskTotal > 0 else { return }

        let isCritical = s.diskFreeFraction <= t.diskCriticalFraction
            || s.diskFree <= t.diskCriticalBytes
        let isWarning = s.diskFreeFraction <= t.diskWarnFraction || s.diskFree <= t.diskWarnBytes
        guard isCritical || isWarning else { return }

        signals.append(SystemSignal(
            id: "disk.low",
            severity: isCritical ? .critical : .warning,
            title: isCritical ? "Disk is almost full" : "Disk space is low",
            detail: "\(SystemFormat.bytes(s.diskFree)) free of \(SystemFormat.bytes(s.diskTotal)) "
                + "(\(SystemFormat.percent(s.diskUsedFraction * 100)) used). macOS needs headroom "
                + "for swap and caches — below this, the whole system slows down.",
            advice: [
                "Open System Settings, then General → Storage to review disk usage",
                "Old local models and build caches are usually the biggest wins",
            ],
            culprit: nil,
            since: s.sampledAt,
            action: .openSystemSettings
        ))
    }

    func appendThermalSignal(
        _ s: SystemSnapshot, _ t: SystemThresholds, into signals: inout [SystemSignal]
    ) {
        guard s.thermal == .serious || s.thermal == .critical else { return }
        guard sustained(t.thermalSustain, { $0.thermal == .serious || $0.thermal == .critical })
        else { return }

        signals.append(SystemSignal(
            id: "thermal.pressure",
            severity: s.thermal == .critical ? .critical : .warning,
            title: "The machine is thermally throttled",
            detail: "macOS is deliberately slowing the CPU to shed heat. Performance stays reduced "
                + "until it cools down.",
            advice: [
                "Move the machine off soft surfaces so it can vent",
                "Pause heavy work — builds, model runs, exports",
                "Unplugging a hot charger sometimes helps more than you would expect",
            ],
            culprit: nil,
            since: s.sampledAt,
            action: .openActivityMonitor
        ))
    }

    // MARK: - Uptime

    func appendUptimeSignal(
        _ s: SystemSnapshot, _ t: SystemThresholds, into signals: inout [SystemSignal]
    ) {
        let days = s.uptimeDays
        guard days >= t.uptimeInfoDays else { return }

        // The Sentinel app also weighed compressed memory here; the contract's snapshot does not
        // carry a compressed figure, so pressure and swap size are what is left to judge by.
        let memoryIsStrained = s.memoryPressure != .normal || s.swapUsed > 4 * 1024 * 1024 * 1024
        let severity: SignalSeverity = (days >= t.uptimeWarnDays || memoryIsStrained)
            ? .warning : .info

        var advice = [
            "Save your work and restart — it takes two minutes and clears leaked memory",
            "A full shut down overnight is even better if you can spare it",
        ]
        if memoryIsStrained {
            advice.insert(
                "Memory is already degraded, so the restart will make an immediate difference",
                at: 0
            )
        }

        signals.append(SystemSignal(
            id: "uptime.restart",
            severity: severity,
            title: severity == .info ? "Time for a restart soon" : "This machine needs a restart",
            detail: "Up for \(SystemFormat.duration(s.uptime)) without a reboot. "
                + (memoryIsStrained
                    ? "Memory is already under pressure and swap is in use."
                    : "Long uptimes accumulate leaked memory and stale processes."),
            advice: advice,
            culprit: nil,
            since: s.sampledAt,
            action: nil
        ))
    }

    func appendSprawlSignal(
        _ s: SystemSnapshot, _ t: SystemThresholds, _ apps: [SystemAppLoad],
        into signals: inout [SystemSignal]
    ) {
        guard s.processCount >= t.processCountHigh else { return }
        guard sustained(120, { $0.processCount >= t.processCountHigh }) else { return }

        let worst = apps
            .filter { $0.processCount >= 8 }
            .max { $0.processCount < $1.processCount }

        signals.append(SystemSignal(
            id: "process.sprawl",
            severity: .info,
            title: "Unusually many processes running",
            detail: "\(s.processCount) processes are alive. "
                + (worst.map { "\($0.name) alone accounts for \($0.processCount)." } ?? ""),
            advice: [
                "Background agents and tool runs often leave processes behind after they finish",
                "Quitting and reopening the parent app clears the orphans",
            ],
            culprit: worst?.name,
            since: s.sampledAt,
            action: .openActivityMonitor
        ))
    }

    /// The rule that matters most in practice: a call is happening *right now* and the machine is
    /// in no state to carry it. Worth interrupting for, because the fix has a deadline.
    func appendCallRiskSignal(
        _ s: SystemSnapshot, _ t: SystemThresholds, into signals: inout [SystemSignal]
    ) {
        // Slack and Discord run all day; having them open is not being on a call. This rule fires
        // the loudest alert there is, so it demands evidence of actual capture: the camera is
        // open, FaceTime's conferencing daemon is up, or the audio server is doing real work
        // alongside a call app.
        let cameraActive = s.processes.contains { $0.name == "cameracaptured" }
        let conferencing = s.processes.contains { $0.name == "avconferenced" && $0.cpuPercent >= 2 }
        let audioBusy = s.processes.first { $0.name == "coreaudiod" }
            .map { $0.cpuPercent >= 8 } ?? false
        guard cameraActive || conferencing || audioBusy else { return }

        // Only now is the marker scan worth its cost: on an idle machine none of the three cheap
        // name checks above hold, and the rule costs three equality passes and nothing else.
        let callApp = s.processes.first { SystemMarkers.matches($0.name, any: SystemMarkers.callApps) }
        guard cameraActive || conferencing || (callApp != nil && audioBusy) else { return }

        var reasons: [String] = []
        if s.cpuPercent >= 70 { reasons.append("CPU at \(SystemFormat.percent(s.cpuPercent))") }
        if s.memoryPressure != .normal {
            reasons.append("memory pressure \(s.memoryPressure.label.lowercased())")
        }
        if s.windowServerCPU >= t.windowServerCPU {
            reasons.append("WindowServer at \(SystemFormat.percent(s.windowServerCPU))")
        }
        if s.networkExtensionCPU >= t.networkExtensionCPU {
            reasons.append("VPN extension at \(SystemFormat.percent(s.networkExtensionCPU))")
        }
        if s.swapOutPerSecond >= t.swapoutRateHigh { reasons.append("actively swapping") }
        if s.thermal == .serious || s.thermal == .critical { reasons.append("thermally throttled") }

        guard !reasons.isEmpty else { return }
        guard sustained(20, { $0.cpuPercent >= 60 || $0.memoryPressure != .normal })
        else { return }

        var advice = ["Quit what you are not using before the call degrades further"]
        if s.networkExtensionCPU >= t.networkExtensionCPU {
            advice.insert("Disconnect the VPN — it is the most likely cause of choppy video", at: 0)
        }
        if s.windowServerCPU >= t.windowServerCPU {
            advice.append("Stop screen sharing or close extra windows to relieve WindowServer")
        }

        signals.append(SystemSignal(
            id: "call.atrisk",
            severity: .critical,
            title: "Your call is about to suffer",
            detail: "A call is in progress and the system is struggling: "
                + reasons.joined(separator: ", ") + ".",
            advice: advice,
            culprit: callApp?.actionableName,
            since: s.sampledAt,
            action: .openActivityMonitor
        ))
    }
}
