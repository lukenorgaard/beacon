import Foundation

/// Start-at-login via a plain LaunchAgent plist — the same approach Beacon uses. SMAppService
/// is the modern route but is unreliable for ad-hoc-signed apps, and a plist is something the
/// user can read and delete.
enum LaunchAgent {
    static let label = "io.github.lukenorgaard.beacon"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// The plist records an absolute path. Move the app — build/ to /Applications, say — and
    /// login start breaks silently. On launch, notice a stale path and point it at ourselves.
    static func repairIfStale() {
        guard isInstalled,
              let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String],
              let recorded = arguments.first
        else { return }

        let current = Bundle.main.executablePath ?? ""
        guard !current.isEmpty, recorded != current else { return }
        guard !FileManager.default.isExecutableFile(atPath: recorded) else { return }

        install()
    }

    /// SPEC §10.2: start at login is on by default, installed the first time the app runs from
    /// /Applications — but only once, and never over a plist the user already has or deleted.
    /// Pure so the rule is testable without touching ~/Library/LaunchAgents.
    static func shouldBootstrap(
        bundlePath: String,
        alreadyBootstrapped: Bool,
        isInstalled: Bool
    ) -> Bool {
        guard !alreadyBootstrapped, !isInstalled else { return false }
        return bundlePath.hasPrefix("/Applications/")
    }

    /// Called once on launch. Returns true when it actually wrote the plist.
    @discardableResult
    static func bootstrapIfNeeded(settings: Settings) -> Bool {
        guard shouldBootstrap(
            bundlePath: Bundle.main.bundlePath,
            alreadyBootstrapped: settings.launchAgentBootstrapped,
            isInstalled: isInstalled
        ) else { return false }
        settings.launchAgentBootstrapped = true
        return install()
    }

    @discardableResult
    static func install() -> Bool {
        let executable = Bundle.main.executablePath ?? ""
        guard !executable.isEmpty else { return false }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]

        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            try data.write(to: plistURL, options: .atomic)
        } catch {
            return false
        }

        DispatchQueue.global(qos: .utility).async {
            Shell.run("/bin/launchctl", ["unload", plistURL.path], timeout: 5)
            Shell.run("/bin/launchctl", ["load", plistURL.path], timeout: 5)
        }
        return true
    }

    @discardableResult
    static func uninstall() -> Bool {
        let url = plistURL
        DispatchQueue.global(qos: .utility).async {
            Shell.run("/bin/launchctl", ["unload", url.path], timeout: 5)
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return true
        } catch {
            return false
        }
    }
}
