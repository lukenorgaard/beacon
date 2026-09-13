import AppKit
import Combine
import Foundation

extension AppState {
    // MARK: - Sentinel (SPEC §18)

    /// SPEC §18.1: one engine, made by the factory, started and stopped by the Enabled switch.
    /// The two closures are read on every cycle, so a sensitivity or notification change applies
    /// without rebuilding anything.
    func applySentinel(enabled: Bool) {
        if enabled {
            if systemWatchEngine == nil {
                let engine = SystemWatch.makeEngine(
                    state: systemWatch,
                    sensitivity: { [settings] in settings.sentinelSensitivity },
                    notificationsEnabled: { [settings] in settings.sentinelNotifications }
                )
                systemWatchEngine = engine
                engine.start()
            }
        } else {
            systemWatchEngine?.stop()
            systemWatchEngine = nil
            // Nothing is sampling any more, so nothing on screen may claim to know: stale
            // warnings would keep colouring the menu-bar dot long after the switch went off.
            systemWatch.signals = []
            systemWatch.snapshot = nil
            systemWatch.lastError = nil
        }
        resolveTabIfNeeded()
        updateSystemWatchVisibility()
    }

    /// SPEC §18.6: visible means *the Sentinel tab is the one on screen* — not merely selected
    /// in a panel that is collapsed to the menu bar.
    func updateSystemWatchVisibility(tab: PanelTab? = nil) {
        let selected = tab ?? self.tab
        let visible = settings.sentinelEnabled && panelIsOnScreen && selected == .sentinel
        if systemWatch.isVisible != visible { systemWatch.isVisible = visible }
    }

    /// Called by `PanelController` on every show and hide. The window rides along because the
    /// Stop… confirmation is a sheet on it (SPEC §18.4) and this is the one place the panel is
    /// already telling `AppState` about itself — `NSApp.keyWindow` would be a guess, and the
    /// wrong one for a non-activating panel.
    func setPanelOnScreen(_ onScreen: Bool, window: NSWindow? = nil) {
        if let window { panelWindow = window }
        guard panelIsOnScreen != onScreen else { return }
        panelIsOnScreen = onScreen
        updateSystemWatchVisibility()
    }

    /// SPEC §18.4: the Stop… button's target, once the user has confirmed. Routed through
    /// `AppState` so the engine itself stays private — and so "Sentinel is off" is an error the
    /// row can show rather than a silent no-op.
    ///
    /// `completion` is called on the main thread, whether the engine answered or there was no
    /// engine to ask.
    func stopSystemProcess(
        pid: Int32, expectedName: String, expectedIdentity: SystemProcessIdentity? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let systemWatchEngine else {
            DispatchQueue.main.async {
                completion(.failure(NSError(
                    domain: "io.github.lukenorgaard.beacon.sentinel", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Sentinel is not running"]
                )))
            }
            return
        }
        systemWatchEngine.stopProcess(
            pid: pid, expectedName: expectedName, expectedIdentity: expectedIdentity, completion: completion
        )
    }

    /// SPEC §18.5: the critical signal the menu-bar dot is allowed to speak for — nil when the
    /// tab is off, when the dot setting is off, or when nothing critical is firing.
    var sentinelCriticalSignal: SystemSignal? {
        guard settings.sentinelEnabled, settings.sentinelMenuBarDot else { return nil }
        return systemWatch.signals
            .filter { $0.severity == .critical }
            .min { $0.since < $1.since }
    }

    /// The menu bar dot (SPEC §5.1; SPEC §18.5 for the critical case).
    var statusColor: NSColor {
        if needsYouCount > 0 { return .systemRed }
        // A machine in trouble outranks a finished or a working session — but never a session
        // that is actually waiting for the owner.
        if sentinelCriticalSignal != nil { return Theme.signalCriticalNSColor }
        if unseenDoneCount > 0 { return .systemGreen }
        if workingCount > 0 { return .systemBlue }
        return .systemGray
    }

    var statusTitle: String {
        switch settings.statusText {
        case .none:
            return ""
        case .needsCount:
            return needsYouCount > 0 ? "\(needsYouCount)" : ""
        case .full:
            var parts: [String] = ["\(allSessions.count)"]
            if let session = usage.snapshot?.sessionPercent {
                parts.append("\(Int(session.rounded()))%")
            }
            if let weekly = usage.snapshot?.weeklyPercent {
                parts.append("\(Int(weekly.rounded()))%")
            }
            return parts.joined(separator: " · ")
        }
    }

    var statusTooltip: String {
        var lines = [summaryText]
        if needsYouCount > 0 { lines.append("\(needsYouCount) need you") }
        if workingCount > 0 { lines.append("\(workingCount) working") }
        // SPEC §18.5: a dot that changed colour without saying why would be a riddle.
        if let signal = sentinelCriticalSignal { lines.append(signal.title) }
        return lines.joined(separator: " · ")
    }

    // MARK: - Actions

    func jump(to session: Session) {
        if session.state == .done { seen.markSeen(session.id) }
        notifier.clear(sessionID: session.sessionID)
        Jumper.jump(to: session)
        objectWillChange.send()
    }

    func jump(sessionID: String) {
        guard let session = allSessions.first(where: { $0.sessionID == sessionID }) else { return }
        jump(to: session)
    }

    func markAllDoneSeen() {
        seen.markAllSeen(allSessions)
        objectWillChange.send()
    }
}
