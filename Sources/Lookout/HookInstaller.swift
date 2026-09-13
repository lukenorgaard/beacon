import Combine
import Foundation

/// Where a hook entry's `lookout-report.py` command points (SPEC §10.2).
enum HookStatus: Equatable {
    /// No hook entry mentions the reporter at all.
    case notInstalled
    /// A hook entry points at the reporter inside *this* bundle.
    case installedHere
    /// A hook entry points at a reporter somewhere else — typically the owner's repo checkout.
    case installedElsewhere(String)

    var isInstalledHere: Bool { self == .installedHere }

    var isInstalledElsewhere: Bool {
        if case .installedElsewhere = self { return true }
        return false
    }
}

/// The reporter side that `scripts/build.sh` copies into the bundle (SPEC §10.1). The layout
/// mirrors the repository on purpose: `install-hooks.py` derives its `REPO_ROOT` from the parent
/// of its own `scripts/` directory, so dropping it in `Resources/scripts/` makes it write hook
/// commands pointing at `Resources/hooks/lookout-report.py` with no changes to the installer.
enum BundleLayout {
    static let reporter = "hooks/lookout-report.py"
    static let claudeFragment = "hooks/claude-hooks.json"
    static let codexFragment = "hooks/codex-hooks.json"
    static let installer = "scripts/install-hooks.py"

    /// Exactly what has to exist under `Contents/Resources` for the setup page to work.
    /// `tests` assert this list; the real bundle is checked by `missingFiles(in:)`.
    static let bundledFiles = [claudeFragment, codexFragment, reporter, installer]

    /// The two files that have to keep their executable bit.
    static let executableFiles = [reporter, installer]

    /// SPEC §16.3: the editor companion's half of the bundle. Deliberately *not* in
    /// `bundledFiles` — a build without it must still be able to install the hooks.
    static let companionVsix = "companion/lookout-companion.vsix"
    static let companionScript = "companion/install-companion.sh"
    static let companionFiles = [companionVsix, companionScript]

    static func url(_ relativePath: String, in resources: URL) -> URL {
        relativePath.split(separator: "/").reduce(resources) { $0.appendingPathComponent(String($1)) }
    }

    static func reporterURL(in resources: URL) -> URL { url(reporter, in: resources) }
    static func installerURL(in resources: URL) -> URL { url(installer, in: resources) }

    /// Relative paths from `bundledFiles` that are not on disk under `resources`, in order.
    static func missingFiles(in resources: URL?) -> [String] {
        guard let resources else { return bundledFiles }
        return bundledFiles.filter { !FileManager.default.fileExists(atPath: url($0, in: resources).path) }
    }
}

/// Reads `~/.claude/settings.json` / `~/.codex/hooks.json` without caring whether they exist,
/// parse, or have the shape the docs promise — a setup page that crashes on a hand-edited config
/// is worse than one that says "not installed".
enum HookStatusReader {
    /// Folder-name independent, exactly like `install-hooks.py`'s own `MARKER`.
    static let marker = "hooks/lookout-report.py"

    /// The reporter path inside one command string, e.g.
    /// `/usr/bin/python3 /Applications/Lookout.app/…/hooks/lookout-report.py --agent claude` →
    /// `/Applications/Lookout.app/…/hooks/lookout-report.py`.
    static func reporterPath(inCommand command: String) -> String? {
        guard command.contains(marker) else { return nil }
        for token in command.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
            guard let end = token.range(of: marker)?.upperBound else { continue }
            let path = token[token.startIndex..<end]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !path.isEmpty { return path }
        }
        return nil
    }

    /// Every reporter path mentioned by a `{"hooks": {Event: [{"hooks": [{"command": …}]}]}}`
    /// document, in file order. Anything that is not shaped like that is skipped silently.
    static func reporterPaths(inJSON data: Data?) -> [String] {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data),
              let hooks = (root as? [String: Any])?["hooks"] as? [String: Any]
        else { return [] }

        var paths: [String] = []
        for eventName in hooks.keys.sorted() {
            guard let groups = hooks[eventName] as? [Any] else { continue }
            for group in groups {
                guard let entries = (group as? [String: Any])?["hooks"] as? [Any] else { continue }
                for entry in entries {
                    guard let command = (entry as? [String: Any])?["command"] as? String,
                          let path = reporterPath(inCommand: command)
                    else { continue }
                    paths.append(path)
                }
            }
        }
        return paths
    }

    static func status(inJSON data: Data?, reporterPath: String?) -> HookStatus {
        let found = reporterPaths(inJSON: data)
        guard let first = found.first else { return .notInstalled }
        if let reporterPath, found.contains(reporterPath) { return .installedHere }
        return .installedElsewhere(first)
    }

    static func status(ofFileAt url: URL, reporterPath: String?) -> HookStatus {
        status(inJSON: try? Data(contentsOf: url), reporterPath: reporterPath)
    }
}

/// Runs the bundled `install-hooks.py` and reports what the two config files currently say
/// (SPEC §10.2). Every filesystem probe and every shell-out happens off the main thread.
final class HookInstaller: ObservableObject {
    /// What one installer run produced: the exit status plus the last line worth showing.
    struct Outcome: Equatable {
        var exitCode: Int32
        var message: String
        var timedOut: Bool

        var succeeded: Bool { exitCode == 0 && !timedOut }
    }

    /// One consistent read of both config files — computed off the main thread, published on it.
    struct Snapshot: Equatable {
        var claude: HookStatus = .notInstalled
        var codex: HookStatus = .notInstalled
        var codexPresent = false
    }

    static let pythonPath = "/usr/bin/python3"
    private static let xcodeSelectPath = "/usr/bin/xcode-select"
    /// SPEC §10.2: the installer gets 5 s, and `Shell` guarantees the call returns soon after.
    static let installTimeout: TimeInterval = 5

    @Published private(set) var claude: HookStatus = .notInstalled
    @Published private(set) var codex: HookStatus = .notInstalled
    @Published private(set) var codexPresent = false
    /// `/usr/bin/python3` exists *and* the Command Line Tools are selected — the shim at that
    /// path exits non-zero with a "no developer tools" error otherwise.
    @Published private(set) var pythonAvailable = false
    @Published private(set) var busy = false
    /// Last line the installer printed, kept for the setup page's status line.
    @Published private(set) var lastOutcome: Outcome?

    let resourcesURL: URL?
    let claudeSettingsURL: URL
    let codexHooksURL: URL
    let codexDirectoryURL: URL

    private let queue = DispatchQueue(label: "io.github.lukenorgaard.beacon.hookinstaller", qos: .userInitiated)

    init(
        resources: URL? = Bundle.main.resourceURL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        resourcesURL = resources
        claudeSettingsURL = home.appendingPathComponent(".claude/settings.json")
        codexDirectoryURL = home.appendingPathComponent(".codex")
        codexHooksURL = codexDirectoryURL.appendingPathComponent("hooks.json")
    }

    // MARK: - Bundled paths

    var reporterURL: URL? { resourcesURL.map { BundleLayout.reporterURL(in: $0) } }
    var installerURL: URL? { resourcesURL.map { BundleLayout.installerURL(in: $0) } }
    var reporterPath: String? { reporterURL?.path }

    /// Empty when the bundle carries everything §10.1 requires.
    var missingBundledFiles: [String] { BundleLayout.missingFiles(in: resourcesURL) }

    // MARK: - Status

    /// Synchronous, filesystem-only. Safe to call from a background queue or a test.
    func probe() -> Snapshot {
        let path = reporterPath
        return Snapshot(
            claude: HookStatusReader.status(ofFileAt: claudeSettingsURL, reporterPath: path),
            codex: HookStatusReader.status(ofFileAt: codexHooksURL, reporterPath: path),
            codexPresent: FileManager.default.fileExists(atPath: codexDirectoryURL.path)
        )
    }

    func apply(_ snapshot: Snapshot) {
        claude = snapshot.claude
        codex = snapshot.codex
        codexPresent = snapshot.codexPresent
    }

    /// Re-reads both config files and re-checks python, off the main thread.
    func refresh(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.probe()
            let python = HookInstaller.checkPython()
            DispatchQueue.main.async {
                self.apply(snapshot)
                self.pythonAvailable = python
                completion?()
            }
        }
    }

    /// One `stat` plus one short shell-out; called only from `refresh`.
    static func checkPython() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: pythonPath) else { return false }
        return Shell.run(xcodeSelectPath, ["-p"], timeout: 3).exitCode == 0
    }

    // MARK: - Install / remove

    func install(replaceOsascript: Bool, completion: ((Outcome) -> Void)? = nil) {
        var arguments: [String] = []
        if replaceOsascript { arguments.append("--replace-osascript") }
        run(arguments, completion: completion)
    }

    func remove(completion: ((Outcome) -> Void)? = nil) {
        run(["--remove"], completion: completion)
    }

    private func run(_ extraArguments: [String], completion: ((Outcome) -> Void)?) {
        guard !busy else { return }
        guard let installerPath = installerURL?.path,
              FileManager.default.fileExists(atPath: installerPath)
        else {
            let outcome = Outcome(
                exitCode: -1,
                message: "The installer is missing from this copy of Beacon — rebuild the app.",
                timedOut: false
            )
            lastOutcome = outcome
            completion?(outcome)
            return
        }

        busy = true
        let arguments = [installerPath,
                         "--claude-settings", claudeSettingsURL.path,
                         "--codex-hooks", codexHooksURL.path] + extraArguments

        queue.async { [weak self] in
            guard let self else { return }
            let result = Shell.run(
                HookInstaller.pythonPath,
                arguments,
                timeout: HookInstaller.installTimeout,
                mergeStandardError: true
            )
            let outcome = Outcome(
                exitCode: result.exitCode,
                message: HookInstaller.summarise(result),
                timedOut: result.timedOut
            )
            let snapshot = self.probe()
            DispatchQueue.main.async {
                self.apply(snapshot)
                self.lastOutcome = outcome
                self.busy = false
                completion?(outcome)
            }
        }
    }

    /// The last non-empty line the installer printed — it ends with either the "updated …"
    /// summary or the error that stopped it, which is exactly what the row should say.
    static func summarise(_ result: Shell.Result) -> String {
        if result.timedOut {
            return "Timed out after \(Int(installTimeout)) s."
        }
        let line = lastNonEmptyLine(result.stdout)
        if !line.isEmpty { return line }
        return result.exitCode == 0 ? "Done." : "Failed (exit \(result.exitCode))."
    }

    static func lastNonEmptyLine(_ output: String) -> String {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
    }

    // MARK: - When the setup page opens itself

    /// SPEC §10.2: automatic on a machine with no hooks, once more when they point at some other
    /// copy of Lookout, and never again after that unless the user asks for it. Codex only counts
    /// when `~/.codex` exists — a machine without Codex is not half-installed.
    static func shouldPresentSetup(
        claude: HookStatus,
        codex: HookStatus,
        codexPresent: Bool,
        setupSeen: Bool
    ) -> Bool {
        let relevant = codexPresent ? [claude, codex] : [claude]
        if relevant.contains(.notInstalled) { return true }
        if !setupSeen, relevant.contains(where: \.isInstalledElsewhere) { return true }
        return false
    }

    func shouldPresentSetup(setupSeen: Bool) -> Bool {
        HookInstaller.shouldPresentSetup(
            claude: claude, codex: codex, codexPresent: codexPresent, setupSeen: setupSeen
        )
    }
}

/// Version strings for the setup page and the pkg name, read from the bundle at runtime.
enum AppInfo {
    /// Unbundled, `Bundle.main` is whatever binary is hosting us (the xctest runner, say), whose
    /// version has nothing to do with Lookout — say "dev" rather than lie.
    static var shortVersion: String {
        guard isBundledApp,
              let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String
        else { return "dev" }
        return version
    }

    /// `UNUserNotificationCenter.current()` raises rather than returning nil when the process is
    /// not an app bundle — which is every `swift test` run and every raw-binary run. A bundle
    /// identifier alone is not enough: the xctest runner has one.
    static var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }
}
