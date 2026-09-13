import AppKit

/// Lookout is a menu bar app: no dock icon, no main window (`LSUIElement` in the bundle,
/// `.accessory` here so an unbundled run behaves the same).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private var state: AppState!
    private var controller: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        state = AppState(settings: settings)
        controller = StatusItemController(state: state, settings: settings)

        // `--tab usage` opens on a given tab; used for visual verification and screenshots.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--tab"), index + 1 < arguments.count,
           let tab = PanelTab(rawValue: arguments[index + 1]) {
            state.tab = tab
        }

        state.notifier.onActivate = { [weak self] id in
            guard let self else { return }
            self.state.jump(sessionID: id)
            self.controller.revealPanel()
        }

        LaunchAgent.repairIfStale()
        // SPEC §10.2: a fresh install from /Applications turns start-at-login on for the user,
        // once. Turning it off afterwards sticks.
        LaunchAgent.bootstrapIfNeeded(settings: settings)

        controller.start()
        state.start()
        controller.presentSetupIfNeeded()
    }

    /// Launching from Finder or Spotlight brings the panel back rather than doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        controller.revealPanel()
        return true
    }
}

/// Two copies means two menu bar icons and two sets of notifications for the same session.
func terminateIfAlreadyRunning() {
    let identifier = Bundle.main.bundleIdentifier ?? "io.github.lukenorgaard.beacon"
    let mine = ProcessInfo.processInfo.processIdentifier
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        .filter { $0.processIdentifier != mine }
    guard let existing = others.first else { return }
    existing.activate()
    exit(0)
}

terminateIfAlreadyRunning()

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
