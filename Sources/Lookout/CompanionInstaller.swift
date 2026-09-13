import Combine
import Foundation

/// The three editors §16.3 can reach into, and where each one lives.
enum EditorApp: String, CaseIterable, Identifiable {
    case cursor
    case devin
    case vscode

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cursor: return "Cursor"
        case .devin: return "Devin"
        case .vscode: return "VS Code"
        }
    }

    /// The bundle `install-companion.sh` drives, relative to an applications directory.
    var bundleName: String {
        switch self {
        case .cursor: return "Cursor.app"
        case .devin: return "Devin.app"
        case .vscode: return "Visual Studio Code.app"
        }
    }

    /// The argument `install-companion.sh` takes — the same word as the state file's `app`.
    var argument: String { rawValue }

    var host: SessionHost {
        switch self {
        case .cursor: return .cursor
        case .devin: return .devin
        case .vscode: return .vscode
        }
    }
}

/// One row's traffic light (SPEC §16.3).
enum CompanionState: String, Equatable {
    /// A live companion file exists for that app — green.
    case live
    /// The app is installed but nothing is answering — amber, and the row says what to do.
    case installable
    /// The app is not on this Mac — grey, and there is nothing to install.
    case absent

    /// The exact rule §16.3 writes, in one testable place.
    static func state(appPresent: Bool, companionLive: Bool) -> CompanionState {
        guard appPresent else { return .absent }
        return companionLive ? .live : .installable
    }

    /// The headline dot for the whole row: the best state any app is in.
    static func summary(_ states: [CompanionState]) -> CompanionState {
        if states.contains(.live) { return .live }
        if states.contains(.installable) { return .installable }
        return .absent
    }

    var message: String {
        switch self {
        case .live:
            return "Answering. Clicking a session lands in its own terminal tab, and Send and "
                + "Rename type straight into it."
        case .installable:
            return "Install, then reload the editor window."
        case .absent:
            return "Not installed on this Mac."
        }
    }

    var canInstall: Bool { self != .absent }
}

/// One app's row in the Editor companion card.
struct CompanionAppStatus: Equatable, Identifiable {
    let app: EditorApp
    let present: Bool
    let live: Bool

    var id: String { app.id }
    var state: CompanionState { CompanionState.state(appPresent: present, companionLive: live) }
}

/// Installs the companion extension into Cursor / Devin / VS Code and says which of them is
/// answering (SPEC §16.3). Every probe and every shell-out happens off the main thread.
final class CompanionInstaller: ObservableObject {
    struct Outcome: Equatable {
        var app: EditorApp
        var exitCode: Int32
        var message: String
        var timedOut: Bool

        var succeeded: Bool { exitCode == 0 && !timedOut }
    }

    /// SPEC §16.3: an extension install unpacks a vsix and rewrites the editor's extension
    /// index — the hook installer's 5 s is far too short, so this one gets a minute.
    static let installTimeout: TimeInterval = 60
    static let bashPath = "/bin/bash"

    @Published private(set) var apps: [CompanionAppStatus] = EditorApp.allCases.map {
        CompanionAppStatus(app: $0, present: false, live: false)
    }
    /// The app whose install is running, if any.
    @Published private(set) var busy: EditorApp?
    @Published private(set) var lastOutcome: Outcome?

    let resourcesURL: URL?
    let applicationsURL: URL
    private let companion: CompanionChannel
    private let queue = DispatchQueue(label: "io.github.lukenorgaard.beacon.companioninstaller", qos: .userInitiated)

    init(
        resources: URL? = Bundle.main.resourceURL,
        applications: URL = URL(fileURLWithPath: "/Applications"),
        companion: CompanionChannel = EditorCompanion.shared
    ) {
        resourcesURL = resources
        applicationsURL = applications
        self.companion = companion
    }

    /// `Contents/Resources/companion/install-companion.sh` — what `build.sh` puts there.
    var scriptURL: URL? { resourcesURL.map { BundleLayout.url(BundleLayout.companionScript, in: $0) } }
    var vsixURL: URL? { resourcesURL.map { BundleLayout.url(BundleLayout.companionVsix, in: $0) } }

    /// Empty when the bundle carries both companion files.
    var missingBundledFiles: [String] {
        guard let resourcesURL else { return BundleLayout.companionFiles }
        return BundleLayout.companionFiles.filter {
            !FileManager.default.fileExists(atPath: BundleLayout.url($0, in: resourcesURL).path)
        }
    }

    var canInstall: Bool { busy == nil && missingBundledFiles.isEmpty }

    /// The one dot the card's headline shows.
    var summary: CompanionState { CompanionState.summary(apps.map(\.state)) }

    // MARK: - Status

    /// Synchronous, and cheap: a `stat` per app plus one directory listing. No HTTP.
    func probe() -> [CompanionAppStatus] {
        EditorApp.allCases.map { app in
            let present = FileManager.default.fileExists(
                atPath: applicationsURL.appendingPathComponent(app.bundleName).path
            )
            return CompanionAppStatus(
                app: app,
                present: present,
                live: present && companion.hasLiveInstance(app: app.argument)
            )
        }
    }

    func apply(_ statuses: [CompanionAppStatus]) {
        apps = statuses
    }

    func refresh(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let statuses = self.probe()
            DispatchQueue.main.async {
                self.apply(statuses)
                completion?()
            }
        }
    }

    // MARK: - Install

    /// Runs `Resources/companion/install-companion.sh <app>` through `/bin/bash`, so a bundle
    /// whose executable bit was lost in a copy still installs.
    func install(_ app: EditorApp, completion: ((Outcome) -> Void)? = nil) {
        guard busy == nil else { return }
        guard let script = scriptURL?.path,
              FileManager.default.fileExists(atPath: script)
        else {
            let outcome = Outcome(
                app: app, exitCode: -1,
                message: "The companion is missing from this copy of Beacon — rebuild the app.",
                timedOut: false
            )
            lastOutcome = outcome
            completion?(outcome)
            return
        }

        busy = app
        queue.async { [weak self] in
            guard let self else { return }
            let result = Shell.run(
                CompanionInstaller.bashPath,
                [script, app.argument],
                timeout: CompanionInstaller.installTimeout,
                mergeStandardError: true
            )
            let outcome = Outcome(
                app: app,
                exitCode: result.exitCode,
                message: CompanionInstaller.summarise(result, app: app),
                timedOut: result.timedOut
            )
            // The window has to be reloaded before a companion file appears, so this probe is
            // expected to still say amber — it is here so a *second* install shows green.
            let statuses = self.probe()
            DispatchQueue.main.async {
                self.apply(statuses)
                self.lastOutcome = outcome
                self.busy = nil
                completion?(outcome)
            }
        }
    }

    /// The last line the script printed, which is either its "ok" summary or the error that
    /// stopped it — plus the reload instruction, which is the part the owner has to act on.
    static func summarise(_ result: Shell.Result, app: EditorApp) -> String {
        if result.timedOut {
            return "\(app.label): timed out after \(Int(installTimeout)) s."
        }
        let line = HookInstaller.lastNonEmptyLine(result.stdout)
        if result.exitCode != 0 {
            return line.isEmpty
                ? "\(app.label): failed (exit \(result.exitCode))."
                : "\(app.label): \(line)"
        }
        return "\(app.label): installed. Reload the window (⌘⇧P → Reload Window)."
    }
}
