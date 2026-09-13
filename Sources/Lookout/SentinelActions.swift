import AppKit

/// SPEC §18.4: what a warning's button actually does. Every side effect goes through a closure
/// so a test can watch it happen without an alert on screen or an app being launched — the live
/// wiring is `SentinelActions.live(state:)`, and nothing else in the tab talks to AppKit.
///
/// Both halves of a Stop are asynchronous, for two different reasons. The confirmation is a
/// *sheet* on the panel: an `NSAlert.runModal()` takes key focus, and the transient panel hides
/// itself the moment it resigns key — so the alert used to appear over a panel that had just
/// vanished, and the inline failure message landed on a row nobody could see. The stop itself
/// waits up to 2.2 s on SIGTERM/SIGKILL, which is not something a button press may do on the
/// main thread. `completion` is called on the main thread in both cases.
struct SentinelActions {
    /// The confirmation sheet stopping a process always shows first. Answers `true` for "Stop".
    var confirmStop: (_ name: String, _ pid: Int32, _ completion: @escaping (Bool) -> Void) -> Void
    /// The engine's `stopProcess`, which refuses a recycled pid on its own (SPEC §18.4).
    var stopProcess: (
        _ pid: Int32, _ expectedName: String,
        _ completion: @escaping (Result<Void, Error>) -> Void
    ) -> Void
    /// `open -b com.apple.ActivityMonitor` — `false` when the launch failed.
    var openActivityMonitor: () -> Bool
    /// Opens macOS System Settings for a manual storage review; never deletes files.
    var openSystemSettings: () -> Bool
    /// The same jump a session row does, for a signal that carries a `sessionID` (SPEC §18.4).
    var jump: (_ sessionID: String) -> Void

    /// What the row shows under itself when the action failed (SPEC §18.4: an inline line, never
    /// a second alert). `nil` means it worked — or that the user cancelled, which is not a
    /// failure and must not leave a message behind.
    ///
    /// `onStopConfirmed` fires between the confirmation and the signal, and only for a Stop the
    /// user actually agreed to: it is what puts the row into its "Stopping…" state, which has to
    /// appear *after* the sheet is answered and not while it is still standing open.
    func perform(
        _ action: SystemSignalAction,
        onStopConfirmed: @escaping () -> Void = {},
        completion: @escaping (String?) -> Void
    ) {
        switch action {
        case let .stopProcess(pid, name):
            confirmStop(name, pid) { confirmed in
                guard confirmed else {
                    completion(nil)
                    return
                }
                onStopConfirmed()
                stopProcess(pid, name) { result in
                    switch result {
                    case .success: completion(nil)
                    case let .failure(error): completion(error.localizedDescription)
                    }
                }
            }
        case .openActivityMonitor:
            completion(openActivityMonitor() ? nil : "Could not open Activity Monitor")
        case .openSystemSettings:
            completion(openSystemSettings() ? nil : "Could not open System Settings")
        }
    }

    // MARK: - Live

    /// Built-in macOS tools used by the warning actions.
    static let activityMonitorBundleID = "com.apple.ActivityMonitor"
    static let systemSettingsBundleID = "com.apple.systempreferences"

    static func live(state: AppState) -> SentinelActions {
        var confirmedIdentities: [Int32: SystemProcessIdentity] = [:]
        return SentinelActions(
            confirmStop: { [weak state] name, pid, completion in
                let identity = state?.systemWatch.snapshot?.processes.first { $0.pid == pid }?.identity
                    ?? SystemProcessIdentity.read(pid)
                guard let identity, identity.name == name, identity.canStop() else {
                    completion(false)
                    return
                }
                SentinelActions.presentStopAlert(
                    name: name, pid: pid, over: state?.panelWindow
                ) { accepted in
                    if accepted { confirmedIdentities[pid] = identity }
                    completion(accepted)
                }
            },
            stopProcess: { [weak state] pid, name, completion in
                guard let state else {
                    DispatchQueue.main.async {
                        completion(.failure(NSError(
                            domain: "io.github.lukenorgaard.beacon.sentinel", code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "Beacon is shutting down"]
                        )))
                    }
                    return
                }
                guard let identity = confirmedIdentities.removeValue(forKey: pid) else {
                    completion(.failure(SystemWatchStopError.changedIdentity))
                    return
                }
                state.stopSystemProcess(pid: pid, expectedName: name,
                                        expectedIdentity: identity, completion: completion)
            },
            openActivityMonitor: { SentinelActions.open(bundleID: activityMonitorBundleID) },
            openSystemSettings: { SentinelActions.open(bundleID: systemSettingsBundleID) },
            jump: { [weak state] id in state?.jump(sessionID: id) }
        )
    }

    /// SPEC §18.4's confirmation sheet: it names the pid and the process, and it says exactly
    /// what will happen — nothing is stopped on a single click.
    ///
    /// A sheet on the panel, not a free-standing modal. `runModal()` makes the alert key, the
    /// transient panel hides on `didResignKey`, and the panel taking itself off screen is what
    /// used to leave the confirmation floating over nothing and the failure line unreadable.
    /// (`PanelController` also ignores the resign its own sheet causes — both halves are needed.)
    /// The modal path stays as the honest fallback for a panel that has not been built yet.
    private static func presentStopAlert(
        name: String, pid: Int32, over window: NSWindow?,
        completion: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stop \(name) (pid \(pid))?"
        alert.informativeText =
            "Beacon will ask this process to quit, then force it to quit if it has not exited "
            + "after two seconds. Unsaved work may be lost. A Chrome helper can serve more than "
            + "one tab; affected tabs may need reloading."
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")

        guard let window else {
            completion(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }

    /// Resolve and open an application without a shell. Missing apps produce an inline error.
    private static func open(bundleID: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return true
    }

    /// A `SentinelActions` that touches nothing — what a render test and a preview get.
    static let inert = SentinelActions(
        confirmStop: { _, _, completion in completion(false) },
        stopProcess: { _, _, completion in completion(.success(())) },
        openActivityMonitor: { true },
        openSystemSettings: { true },
        jump: { _ in }
    )
}
