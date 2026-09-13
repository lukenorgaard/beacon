import XCTest
@testable import Lookout

/// SPEC §10.2: the setup page's status detection, and §10.1's bundle layout. Everything here is
/// pure or filesystem-only — no installer is ever run.
final class HookInstallerTests: XCTestCase {
    private var root: URL!

    private let bundleReporter =
        "/Applications/Lookout.app/Contents/Resources/hooks/lookout-report.py"
    private let repoReporter = "/Users/you/Desktop/Lookout/hooks/lookout-report.py"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-hookinstaller-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func hookDocument(commands: [String]) -> Data {
        let entries = commands
            .map { #"{"type": "command", "command": "\#($0)", "timeout": 5}"# }
            .joined(separator: ",")
        return Data(#"{"hooks": {"Stop": [{"hooks": [\#(entries)]}]}}"#.utf8)
    }

    private func claudeCommand(_ reporter: String) -> String {
        "/usr/bin/python3 \(reporter) --agent claude --event Stop"
    }

    @discardableResult
    private func write(_ data: Data, to relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url)
        return url
    }

    // MARK: - Status parsing (all three states)

    func testNotInstalledWhenNoCommandMentionsTheReporter() {
        let data = hookDocument(commands: [
            "osascript -e 'display notification \\\"hi\\\"'",
            "/usr/bin/python3 /Users/someone/other-tool/report.py",
        ])
        XCTAssertEqual(
            HookStatusReader.status(inJSON: data, reporterPath: bundleReporter), .notInstalled
        )
    }

    func testInstalledHereWhenACommandPointsAtThisBundle() {
        let data = hookDocument(commands: [claudeCommand(bundleReporter)])
        XCTAssertEqual(
            HookStatusReader.status(inJSON: data, reporterPath: bundleReporter), .installedHere
        )
    }

    func testInstalledElsewhereReportsTheOtherPath() {
        let data = hookDocument(commands: [claudeCommand(repoReporter)])
        XCTAssertEqual(
            HookStatusReader.status(inJSON: data, reporterPath: bundleReporter),
            .installedElsewhere(repoReporter)
        )
    }

    /// Mid-migration: the repo checkout's entries are still there next to this bundle's. Pointing
    /// at us at all counts as installed here, so the page does not nag about a fixed config.
    func testInstalledHereWinsOverAnotherPathInTheSameFile() {
        let data = hookDocument(commands: [
            claudeCommand(repoReporter), claudeCommand(bundleReporter),
        ])
        XCTAssertEqual(
            HookStatusReader.status(inJSON: data, reporterPath: bundleReporter), .installedHere
        )
    }

    func testUnbundledRunWithoutAReporterPathSeesEveryEntryAsElsewhere() {
        let data = hookDocument(commands: [claudeCommand(repoReporter)])
        XCTAssertEqual(
            HookStatusReader.status(inJSON: data, reporterPath: nil),
            .installedElsewhere(repoReporter)
        )
    }

    // MARK: - Tolerance

    func testMissingFileIsNotInstalled() {
        let missing = root.appendingPathComponent("nope/settings.json")
        XCTAssertEqual(
            HookStatusReader.status(ofFileAt: missing, reporterPath: bundleReporter), .notInstalled
        )
    }

    func testMalformedAndUnexpectedShapesAreNotInstalled() {
        let cases: [Data?] = [
            nil,
            Data(),
            Data("not json at all".utf8),
            Data("[]".utf8),
            Data(#"{"hooks": "nope"}"#.utf8),
            Data(#"{"hooks": {"Stop": "nope"}}"#.utf8),
            Data(#"{"hooks": {"Stop": [{"hooks": [{"command": 7}]}]}}"#.utf8),
            Data(#"{"hooks": {"Stop": [{"matcher": "x"}]}}"#.utf8),
            Data(#"{"permissions": {"allow": []}}"#.utf8),
        ]
        for data in cases {
            XCTAssertEqual(
                HookStatusReader.status(inJSON: data, reporterPath: bundleReporter),
                .notInstalled,
                "unexpected status for \(data.map { String(decoding: $0, as: UTF8.self) } ?? "nil")"
            )
        }
    }

    func testOtherHooksInTheFileAreIgnored() {
        let data = Data("""
        {"hooks": {
          "Stop": [{"hooks": [{"type": "command", "command": "/bin/echo hi"}]}],
          "Notification": [{"matcher": "permission_prompt", "hooks": [
            {"type": "command", "command": "\(claudeCommand(bundleReporter))"}]}]
        }}
        """.utf8)
        XCTAssertEqual(
            HookStatusReader.status(inJSON: data, reporterPath: bundleReporter), .installedHere
        )
    }

    func testReporterPathExtractionStopsAtTheScript() {
        XCTAssertEqual(
            HookStatusReader.reporterPath(inCommand: claudeCommand(repoReporter)), repoReporter
        )
        // A quoted path, and a folder that is not called "Lookout" — the marker is folder-name
        // independent, exactly like install-hooks.py's.
        XCTAssertEqual(
            HookStatusReader.reporterPath(
                inCommand: "/usr/bin/python3 \"/tmp/Lookout-main/hooks/lookout-report.py\" --agent codex"
            ),
            "/tmp/Lookout-main/hooks/lookout-report.py"
        )
        XCTAssertNil(HookStatusReader.reporterPath(inCommand: "/usr/bin/python3 /tmp/other.py"))
    }

    // MARK: - Reading the real files

    func testInstallerReadsBothConfigFilesAndNoticesCodex() throws {
        let resources = try makeResources()
        let reporter = BundleLayout.reporterURL(in: resources).path

        try write(hookDocument(commands: [claudeCommand(reporter)]), to: "home/.claude/settings.json")
        try write(hookDocument(commands: [claudeCommand(repoReporter)]), to: "home/.codex/hooks.json")

        let installer = HookInstaller(
            resources: resources, home: root.appendingPathComponent("home")
        )
        let snapshot = installer.probe()
        XCTAssertEqual(snapshot.claude, .installedHere)
        XCTAssertEqual(snapshot.codex, .installedElsewhere(repoReporter))
        XCTAssertTrue(snapshot.codexPresent)
    }

    func testCodexAbsentWhenTheDirectoryDoesNotExist() throws {
        let resources = try makeResources()
        try write(hookDocument(commands: []), to: "home/.claude/settings.json")

        let installer = HookInstaller(
            resources: resources, home: root.appendingPathComponent("home")
        )
        let snapshot = installer.probe()
        XCTAssertFalse(snapshot.codexPresent)
        XCTAssertEqual(snapshot.codex, .notInstalled)
        XCTAssertEqual(snapshot.claude, .notInstalled)
    }

    // MARK: - Bundle layout (SPEC §10.1)

    /// The exact set `scripts/build.sh` has to copy into `Contents/Resources`. The real bundle is
    /// checked by `missingBundledFiles` at runtime and by hand after a build.
    func testBundledFileListMatchesTheSpec() {
        XCTAssertEqual(BundleLayout.bundledFiles, [
            "hooks/claude-hooks.json",
            "hooks/codex-hooks.json",
            "hooks/lookout-report.py",
            "scripts/install-hooks.py",
        ])
        XCTAssertEqual(
            BundleLayout.executableFiles, ["hooks/lookout-report.py", "scripts/install-hooks.py"]
        )
    }

    func testBundledPathsResolveAgainstAResourcesDirectory() throws {
        let resources = try makeResources()
        XCTAssertEqual(
            BundleLayout.reporterURL(in: resources).path,
            resources.path + "/hooks/lookout-report.py"
        )
        XCTAssertEqual(
            BundleLayout.installerURL(in: resources).path,
            resources.path + "/scripts/install-hooks.py"
        )

        let installer = HookInstaller(resources: resources, home: root)
        XCTAssertEqual(installer.reporterPath, resources.path + "/hooks/lookout-report.py")
        XCTAssertEqual(installer.missingBundledFiles, [])

        try FileManager.default.removeItem(at: BundleLayout.installerURL(in: resources))
        XCTAssertEqual(
            HookInstaller(resources: resources, home: root).missingBundledFiles,
            ["scripts/install-hooks.py"]
        )
    }

    func testEverythingIsMissingWithoutAResourcesDirectory() {
        let installer = HookInstaller(resources: nil, home: root)
        XCTAssertNil(installer.reporterPath)
        XCTAssertNil(installer.installerURL)
        XCTAssertEqual(installer.missingBundledFiles, BundleLayout.bundledFiles)
    }

    // MARK: - Installer output

    func testSummaryTakesTheLastNonEmptyLine() {
        let output = "claude: backed up to /tmp/settings.json.bak-1\n"
            + "claude: updated /tmp/settings.json (12 Lookout hook entries)\n\n  \n"
        XCTAssertEqual(
            HookInstaller.lastNonEmptyLine(output),
            "claude: updated /tmp/settings.json (12 Lookout hook entries)"
        )
        XCTAssertEqual(HookInstaller.lastNonEmptyLine("\n \n"), "")
    }

    func testSummaryFallsBackWhenThereIsNoOutput() {
        XCTAssertEqual(
            HookInstaller.summarise(Shell.Result(stdout: "", exitCode: 0, timedOut: false)), "Done."
        )
        XCTAssertEqual(
            HookInstaller.summarise(Shell.Result(stdout: "", exitCode: 2, timedOut: false)),
            "Failed (exit 2)."
        )
        XCTAssertEqual(
            HookInstaller.summarise(Shell.Result(stdout: "half a line", exitCode: -1, timedOut: true)),
            "Timed out after 5 s."
        )
    }

    // MARK: - When the window opens itself

    func testSetupOpensItselfOnlyWhenItHasSomethingToSay() {
        // Nothing installed: always.
        XCTAssertTrue(HookInstaller.shouldPresentSetup(
            claude: .notInstalled, codex: .notInstalled, codexPresent: true, setupSeen: true
        ))
        // Pointing at the repo checkout: once.
        XCTAssertTrue(HookInstaller.shouldPresentSetup(
            claude: .installedElsewhere(repoReporter), codex: .installedHere,
            codexPresent: true, setupSeen: false
        ))
        XCTAssertFalse(HookInstaller.shouldPresentSetup(
            claude: .installedElsewhere(repoReporter), codex: .installedHere,
            codexPresent: true, setupSeen: true
        ))
        // Fully installed: never.
        XCTAssertFalse(HookInstaller.shouldPresentSetup(
            claude: .installedHere, codex: .installedHere, codexPresent: true, setupSeen: false
        ))
        // No Codex on the machine: its (absent) hooks must not force the window open.
        XCTAssertFalse(HookInstaller.shouldPresentSetup(
            claude: .installedHere, codex: .notInstalled, codexPresent: false, setupSeen: false
        ))
        XCTAssertTrue(HookInstaller.shouldPresentSetup(
            claude: .installedHere, codex: .notInstalled, codexPresent: true, setupSeen: false
        ))
    }

    // MARK: - Start at login (SPEC §10.2)

    func testLaunchAgentBootstrapsOnceFromApplications() {
        XCTAssertTrue(LaunchAgent.shouldBootstrap(
            bundlePath: "/Applications/Lookout.app", alreadyBootstrapped: false, isInstalled: false
        ))
        // Already done once — a user who turned it off keeps it off.
        XCTAssertFalse(LaunchAgent.shouldBootstrap(
            bundlePath: "/Applications/Lookout.app", alreadyBootstrapped: true, isInstalled: false
        ))
        // Already there — never rewrite someone else's plist.
        XCTAssertFalse(LaunchAgent.shouldBootstrap(
            bundlePath: "/Applications/Lookout.app", alreadyBootstrapped: false, isInstalled: true
        ))
        // A build/ or DMG run is not an installation.
        XCTAssertFalse(LaunchAgent.shouldBootstrap(
            bundlePath: "/Users/you/Desktop/Lookout/build/Lookout.app",
            alreadyBootstrapped: false, isInstalled: false
        ))
        XCTAssertFalse(LaunchAgent.shouldBootstrap(
            bundlePath: "/Volumes/Lookout 1.1/Lookout.app",
            alreadyBootstrapped: false, isInstalled: false
        ))
    }

    func testSetupFlagsPersist() {
        let suite = "io.github.lukenorgaard.beacon.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = Settings(defaults: defaults)
        XCTAssertFalse(settings.setupSeen)
        XCTAssertFalse(settings.launchAgentBootstrapped)

        settings.setupSeen = true
        settings.launchAgentBootstrapped = true

        let reopened = Settings(defaults: defaults)
        XCTAssertTrue(reopened.setupSeen)
        XCTAssertTrue(reopened.launchAgentBootstrapped)
    }

    // MARK: -

    /// A stand-in for `Lookout.app/Contents/Resources` with the four §10.1 files in it.
    private func makeResources() throws -> URL {
        let resources = root.appendingPathComponent("Resources")
        for relative in BundleLayout.bundledFiles {
            let url = BundleLayout.url(relative, in: resources)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("placeholder\n".utf8).write(to: url)
        }
        return resources
    }
}
