import Foundation

extension Settings {
    // MARK: - Setup page (not @Published: nothing on screen re-renders from these)

    /// Set once the user closes the setup window or installs the hooks from it, so a config that
    /// points at another copy of Lookout stops re-opening the window (SPEC §10.2).
    var setupSeen: Bool {
        get { defaults.bool(forKey: Key.setupSeen) }
        set { defaults.set(newValue, forKey: Key.setupSeen) }
    }

    /// Set the first time the app installs the LaunchAgent for the user. Without it, someone who
    /// deliberately turns start-at-login off would get it re-installed on the next launch.
    var launchAgentBootstrapped: Bool {
        get { defaults.bool(forKey: Key.launchAgentBootstrapped) }
        set { defaults.set(newValue, forKey: Key.launchAgentBootstrapped) }
    }

    // MARK: - Panel position (not @Published: moving the window must not redraw it)

    var panelOrigin: CGPoint? {
        get {
            guard let raw = defaults.string(forKey: Key.panelOrigin) else { return nil }
            let parts = raw.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { return nil }
            return CGPoint(x: parts[0], y: parts[1])
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Key.panelOrigin)
                return
            }
            defaults.set("\(newValue.x),\(newValue.y)", forKey: Key.panelOrigin)
        }
    }
}
