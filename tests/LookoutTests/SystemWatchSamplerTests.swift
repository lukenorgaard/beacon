import XCTest
@testable import Lookout

/// SPEC §18.6 / §18.7. The pure halves — naming, roll-up, the orphan test — are driven by
/// fixtures; the sampler itself is checked against the machine the suite is running on, because
/// the only way to know `host_statistics64` and `proc_pid_rusage` were wired up right is to read
/// them and see numbers that could not be accidents.
final class SystemWatchSamplerTests: XCTestCase {
    // MARK: - Machine metrics

    func testTheMachineSamplerReadsPlausibleNumbers() {
        let sampler = SystemSampler()
        _ = sampler.sample()
        // CPU is a delta between calls; the first one only lays down the baseline.
        Thread.sleep(forTimeInterval: 0.6)
        let (sample, error) = sampler.sample()

        XCTAssertNil(error)
        XCTAssertTrue(sample.hasCPUBaseline)
        XCTAssertGreaterThanOrEqual(sample.cpuPercent, 0)
        XCTAssertLessThanOrEqual(sample.cpuPercent, 100)
        XCTAssertEqual(sample.cpuPerCore.count, ProcessInfo.processInfo.processorCount)
        XCTAssertGreaterThan(sample.memoryTotal, 0)
        XCTAssertGreaterThan(sample.memoryUsed, 0)
        XCTAssertLessThanOrEqual(sample.memoryUsed, sample.memoryTotal)
        XCTAssertGreaterThan(sample.diskTotal, 0)
        XCTAssertLessThanOrEqual(sample.diskFree, sample.diskTotal)
        XCTAssertGreaterThan(sample.uptime, 0)
        XCTAssertEqual(sample.loadAverage.count, 3)
        XCTAssertTrue(sample.swapOutPerSecond.isFinite)
        XCTAssertTrue(sample.swapInPerSecond.isFinite)
        XCTAssertGreaterThanOrEqual(sample.swapOutPerSecond, 0)
    }

    func testTickDeltaTreatsAWrapAsAWrapAndNotANegative() {
        XCTAssertEqual(SystemSampler.tickDelta(120, 100), 20)
        XCTAssertEqual(SystemSampler.tickDelta(4, UInt32.max - 5), 10)
    }

    func testPressureAndThermalLevelsMapToTheContractsEnums() {
        XCTAssertEqual(SystemSampler.pressureLevel(1), .normal)
        XCTAssertEqual(SystemSampler.pressureLevel(2), .warning)
        XCTAssertEqual(SystemSampler.pressureLevel(4), .critical)
        XCTAssertEqual(SystemSampler.pressureLevel(99), .normal)
        XCTAssertEqual(SystemSampler.thermalLevel(.nominal), .nominal)
        XCTAssertEqual(SystemSampler.thermalLevel(.serious), .serious)
        XCTAssertEqual(SystemSampler.thermalLevel(.critical), .critical)
    }

    // MARK: - Processes

    func testTheProcessSamplerSeesTheMachineItIsRunningOn() {
        let sampler = SystemProcessSampler()
        let first = sampler.sample()
        XCTAssertGreaterThan(first.processCount, 50)
        XCTAssertFalse(first.hasBaseline)

        Thread.sleep(forTimeInterval: 0.6)
        let second = sampler.sample()

        XCTAssertTrue(second.hasBaseline)
        XCTAssertGreaterThan(second.processCount, 50)
        XCTAssertFalse(second.processes.isEmpty)
        XCTAssertFalse(second.topApps.isEmpty)
        XCTAssertLessThanOrEqual(second.topApps.count, 8)
        XCTAssertTrue(second.windowServerCPU.isFinite)
        XCTAssertTrue(second.networkExtensionCPU.isFinite)

        for process in second.processes {
            XCTAssertTrue(process.cpuPercent.isFinite, "\(process.name) has a non-finite CPU")
            XCTAssertGreaterThanOrEqual(process.cpuPercent, 0)
            XCTAssertFalse(process.name.isEmpty)
        }
        // Ranked, so the tab can take the first five without sorting again.
        XCTAssertEqual(second.topApps, second.topApps.sorted { $0.cpuPercent > $1.cpuPercent })
        // This process is in its own list, and it is one we know the name of.
        let ourPID = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(second.processes.contains { $0.pid == ourPID })
    }

    /// SPEC §18.6. The engine forks exactly once per process cycle, for the handful of pids
    /// `SystemPrivilegedCPUProbe` needs, and never for the general population. Timing alone cannot
    /// assert that on a machine running other builds — the noise is larger than the thing being
    /// measured — so the guard is the kernel's own child-process accounting, which a fork moves
    /// and libproc cannot. The printed line is the measurement.
    func testTheMachineCycleNeverForks() {
        let sampler = SystemSampler()
        let rules = SystemRulesEngine()
        _ = sampler.sample()

        let before = Self.childCPUSeconds()
        for _ in 0..<7 {
            var snapshot = SystemSnapshot()
            let sample = sampler.sample().sample
            snapshot.cpuPercent = sample.cpuPercent
            snapshot.memoryTotal = sample.memoryTotal
            snapshot.diskTotal = sample.diskTotal
            snapshot.diskFree = sample.diskFree
            snapshot.uptime = sample.uptime
            rules.record(snapshot)
            _ = rules.evaluate(snapshot, thresholds: .scaled(for: .balanced))
        }
        XCTAssertEqual(
            Self.childCPUSeconds(), before,
            "the 5 s machine cycle must never spawn a process"
        )
    }

    /// The probe is rate-limited inside itself, so even a caller sampling in a tight loop pays for
    /// exactly one fork — and that fork must stay far cheaper than the `ps -A` over every process
    /// that the libproc sampler replaced, which is calibrated here rather than guessed at. A
    /// regression to per-cycle shelling out would cost seven of those; this allows two.
    func testProcessCyclesForkOnceAndNeverForTheWholeProcessTable() {
        let sampler = SystemSampler()
        _ = sampler.sample()
        // Deliberately not pre-warmed: the first cycle is the one that forks, so the count below
        // is exercising the probe rather than measuring its silence.
        let processSampler = SystemProcessSampler()

        let before = Self.childCPUSeconds()
        var forkedCycles = 0
        var machine: [Double] = []
        var processes: [Double] = []

        for _ in 0..<7 {
            var began = Date()
            _ = sampler.sample()
            machine.append(Date().timeIntervalSince(began) * 1000)

            began = Date()
            let sample = processSampler.sample()
            processes.append(Date().timeIntervalSince(began) * 1000)
            if sample.privilegedMilliseconds > 0 { forkedCycles += 1 }
        }
        let spent = Self.childCPUSeconds() - before
        let wholeTable = Self.costOfScanningEveryProcessWithPS()

        XCTAssertEqual(forkedCycles, 1, "seven back-to-back cycles, exactly one fork")
        XCTAssertLessThan(
            spent, wholeTable * 2,
            "seven cycles must cost far less than seven `ps` calls over the whole process table"
        )
        print(
            String(
                format: "sentinel cycle cost (fastest of 7): machine %.2f ms, processes %.2f ms; "
                    + "child CPU %.3f s over 7 cycles (1 probe fork) vs %.3f s for one full `ps`",
                machine.min() ?? .infinity, processes.min() ?? .infinity, spent, wholeTable
            )
        )
    }

    /// CPU burned by child processes this process has reaped. One `ps` moves it by ~100 ms;
    /// libproc cannot move it at all.
    private static func childCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_CHILDREN, &usage) == 0 else { return -1 }
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    }

    /// What the engine would cost per cycle if it still shelled out for every process, measured
    /// here so the comparison above holds on any machine.
    private static func costOfScanningEveryProcessWithPS() -> Double {
        let before = childCPUSeconds()
        _ = Shell.run("/bin/ps", ["-Ao", "pid=,ppid=,pcpu=,rss=,comm="], timeout: 6)
        return childCPUSeconds() - before
    }

    // MARK: - Naming

    func testDisplayNameIsWhatAPersonWouldRecognise() {
        XCTAssertEqual(
            SystemProcessSampler.displayName(
                for: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"
            ),
            "WindowServer"
        )
        // A bundle id is not actionable; the product name is — and it still carries its marker.
        let vpn = SystemProcessSampler.displayName(for: "/Library/x/com.nordvpn.macos.Shield")
        XCTAssertEqual(vpn, "NordVPN")
        XCTAssertTrue(SystemMarkers.matches(vpn, any: SystemMarkers.networkExtension))
        // Electron rewrites argv[0] to a status line that changes every sample.
        XCTAssertEqual(
            SystemProcessSampler.displayName(for: "Cursor Helper (Plugin): extension-host [2-7]"),
            "Cursor Helper (Plugin)"
        )
    }

    func testOwningAppIsTheOutermostBundle() {
        XCTAssertEqual(
            SystemProcessSampler.owningApp(
                for: "/Users/you/Applications/Google Chrome.app/Contents/Frameworks/"
                    + "Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
            ),
            "Google Chrome"
        )
        XCTAssertNil(SystemProcessSampler.owningApp(for: "/usr/bin/node"))
        XCTAssertEqual(SystemProcessSampler.owningApp(for: "Slack Helper (Renderer)"), "Slack")
    }

    func testRollUpGroupsHelpersUnderTheAppAPersonWouldQuit() {
        let processes = [
            SystemProcessLoad(
                pid: 1, name: "Google Chrome Helper", appName: "Google Chrome",
                cpuPercent: 30, residentBytes: 100
            ),
            SystemProcessLoad(
                pid: 2, name: "Google Chrome Helper", appName: "Google Chrome",
                cpuPercent: 20, residentBytes: 200
            ),
            SystemProcessLoad(pid: 3, name: "node", appName: nil, cpuPercent: 40, residentBytes: 50),
        ]
        let apps = SystemProcessSampler.rollUp(processes)
        XCTAssertEqual(apps.map(\.name), ["Google Chrome", "node"])
        XCTAssertEqual(apps[0].cpuPercent, 50)
        XCTAssertEqual(apps[0].residentBytes, 300)
        XCTAssertEqual(apps[0].processCount, 2)
    }

    // MARK: - Orphans

    /// Built the way the sampler builds one: the name is whatever `displayName` made of the path,
    /// and the command is the path followed by argv.
    private func candidate(
        _ path: String, arguments: String = "", cpu: Double = 90
    ) -> SystemOrphanCandidate {
        SystemOrphanCandidate(
            pid: 4242,
            name: SystemProcessSampler.displayName(for: path),
            path: path,
            cpuPercent: cpu,
            elapsed: 900,
            command: arguments.isEmpty ? path : "\(path) \(arguments)"
        )
    }

    /// The regression this rule exists to never repeat.
    ///
    /// Every path below was read off a real machine, at ppid 1, over 20 % CPU — the whole of what
    /// the first version of the rule required. It called all of them abandoned, offered a Stop
    /// button on each, and told the owner "nothing will ever stop them". Each one is a service
    /// somebody is using.
    func testTheOrdinaryServicesThatLiveAtLaunchdAreNotOrphans() {
        let notOrphans: [(what: String, path: String, arguments: String)] = [
            (
                "SourceKitService — an XPC service Xcode starts on demand",
                "/Applications/Xcode.app/Contents/SharedFrameworks/SourceKitService.framework"
                    + "/Versions/A/XPCServices/SourceKitService.xpc/Contents/MacOS"
                    + "/SourceKitService",
                ""
            ),
            (
                "ollama, run as a brew service",
                "/opt/homebrew/bin/ollama", "serve"
            ),
            (
                "ollama, run from its own app bundle",
                "/Applications/Ollama.app/Contents/Resources/ollama", "serve"
            ),
            (
                "whisper-server from whisper.cpp",
                "/usr/local/bin/whisper-server", "--model /models/ggml-large-v3.bin --port 8080"
            ),
            (
                "postgres, a brew service",
                "/opt/homebrew/opt/postgresql@16/bin/postgres", "-D /opt/homebrew/var/postgresql@16"
            ),
            (
                "node, installed by fnm under ~/Library",
                NSHomeDirectory() + "/Library/Application Support/fnm/node-versions/v22.11.0"
                    + "/installation/bin/node",
                "/Users/owner/dev/api/server.js"
            ),
            (
                "ssh-agent, a LaunchAgent",
                "/usr/bin/ssh-agent", "-l"
            ),
            (
                "chrome_crashpad_handler, Chrome's own crash reporter",
                "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework"
                    + ".framework/Versions/141.0.0.0/Helpers/chrome_crashpad_handler",
                "--monitor-self --database=/Users/owner/Library/Application Support/Google/Chrome"
            ),
            (
                "a Safari web extension (.appex)",
                "/Applications/1Password.app/Contents/PlugIns/1Password Extension.appex"
                    + "/Contents/MacOS/1Password Extension",
                ""
            ),
            (
                "a nix-installed daemon",
                "/nix/store/abc123-ripgrep-14.1.0/bin/rg", "--files"
            ),
            (
                "Finder, which the owner did not launch either",
                "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", ""
            ),
            (
                "an interactive claude CLI — a runtime, but nothing says it was scripted",
                "/Users/owner/.local/bin/claude", "--model opus"
            ),
        ]

        for row in notOrphans {
            let candidate = self.candidate(row.path, arguments: row.arguments)
            XCTAssertFalse(
                SystemOrphans.isOrphan(candidate),
                "\(row.what) must never be called abandoned — it carries a Stop button"
            )
        }
        XCTAssertTrue(
            SystemOrphans.scan(notOrphans.map { self.candidate($0.path, arguments: $0.arguments) })
                .isEmpty,
            "not one of them may reach the rule"
        )
    }

    /// The other half: what the rule is actually for. Positive evidence of automation, nowhere
    /// near a package manager's prefix, and a name that is not service-ish.
    func testAutomationLeftBehindAtLaunchdIsAnOrphan() {
        let headless = candidate(
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            arguments: "--headless --remote-debugging-port=9222 --user-data-dir=/tmp/puppet"
        )
        XCTAssertTrue(SystemOrphans.isOrphan(headless))
        XCTAssertEqual(SystemOrphans.automationMarker(for: headless), "--headless")

        let orphans: [(what: String, path: String, arguments: String)] = [
            (
                "a chromedriver whose test run is gone",
                "/Users/owner/dev/e2e/drivers/chromedriver", "--port=4444"
            ),
            (
                "a Playwright browser under its own cache",
                "/Users/owner/.cache/ms-playwright/chromium-1140/chrome-mac/Chromium",
                "--headless=new"
            ),
            (
                "a node process a puppeteer harness left behind",
                "/Users/owner/dev/scrape/bin/node",
                "/Users/owner/dev/scrape/node_modules/puppeteer/lib/worker.js"
            ),
            (
                "a claude CLI a script started non-interactively",
                "/Users/owner/dev/tools/claude",
                "--print --dangerously-skip-permissions 'summarise the diff'"
            ),
        ]
        for row in orphans {
            XCTAssertTrue(
                SystemOrphans.isOrphan(candidate(row.path, arguments: row.arguments)),
                "\(row.what) is what this rule is for"
            )
        }
    }

    /// The evidence has to be all three at once — a marker alone does not survive a service path
    /// or a service-ish name, because both of those are how the false positives got in.
    func testEveryPartOfTheEvidenceIsRequired() {
        // Marker, but under a package manager's prefix.
        XCTAssertFalse(
            SystemOrphans.isOrphan(
                candidate("/opt/homebrew/bin/chromedriver", arguments: "--port=4444")
            )
        )
        // Marker, but a service-ish name.
        XCTAssertFalse(
            SystemOrphans.isOrphan(
                candidate("/Users/owner/dev/bin/selenium-agent", arguments: "--headless")
            )
        )
        XCTAssertTrue(SystemOrphans.isServiceName("configd"))
        XCTAssertTrue(SystemOrphans.isServiceName("whisper-server"))
        XCTAssertTrue(SystemOrphans.isServiceName("ssh-agent"))
        XCTAssertTrue(SystemOrphans.isServiceName("Google Chrome Helper"))
        XCTAssertTrue(SystemOrphans.isServiceName("chrome_crashpad_handler"))
        XCTAssertFalse(SystemOrphans.isServiceName("Google Chrome"))
        XCTAssertFalse(SystemOrphans.isServiceName("chromedriver"))

        // Right path, right name, no marker at all: a runtime someone is using.
        XCTAssertFalse(
            SystemOrphans.isOrphan(
                candidate("/Users/owner/dev/scrape/bin/node", arguments: "server.js")
            )
        )
        // All three, but quiet — the CPU floor is still the CPU floor.
        XCTAssertFalse(
            SystemOrphans.isOrphan(
                candidate(
                    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                    arguments: "--headless", cpu: SystemOrphans.minimumCPU - 1
                )
            )
        )
    }

    /// `~/Library` is where fnm, pyenv and nvm install their toolchains, and none of those is a
    /// literal prefix — the home directory is not a constant.
    func testAnythingUnderTheOwnersLibraryIsExcluded() {
        XCTAssertTrue(SystemOrphans.isUnderUserLibrary(NSHomeDirectory() + "/Library/x/bin/node"))
        XCTAssertTrue(
            SystemOrphans.isUnderUserLibrary(
                "/Users/someone-else/Library/pyenv/versions/bin/python"
            )
        )
        XCTAssertFalse(SystemOrphans.isUnderUserLibrary("/Users/owner/dev/bin/node"))
        XCTAssertFalse(SystemOrphans.isUnderUserLibrary("/Users/owner/Library"))
    }

    /// The reason line is what the warning quotes. It names the marker that made this automation
    /// and says what happened to the parent — which is all that can honestly be said, because by
    /// the time ppid reads 1 the dead parent has already been replaced by launchd.
    func testTheReasonNamesTheMarkerAndTheParentItHasNow() {
        let reason = SystemOrphans.reason(
            for: candidate(
                "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                arguments: "--headless"
            )
        )
        XCTAssertTrue(reason.contains("--headless"))
        XCTAssertTrue(reason.contains("launchd (pid 1)"))
        XCTAssertEqual(
            SystemOrphans.reason(for: candidate("/usr/bin/ssh-agent")),
            "no parent process left",
            "nothing that is not an orphan gets a story about why it is one"
        )
    }

    /// The Stop button re-reads the name for the pid and refuses unless it matches, so an orphan
    /// whose name was derived any other way could never be stopped at all.
    func testAnOrphanIsNamedTheSameWayTheStopCheckNamesIt() {
        let path = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let scanned = SystemOrphans.scan([candidate(path, arguments: "--headless")])
        XCTAssertEqual(scanned.first?.name, SystemProcessSampler.displayName(for: path))
        XCTAssertEqual(scanned.first?.name, "Google Chrome")
    }

    func testTheOrphanScanRanksByCPUAndDropsTheQuietOnes() {
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let scanned = SystemOrphans.scan([
            candidate("/Users/owner/dev/e2e/drivers/chromedriver", cpu: 60),
            candidate(chrome, arguments: "--headless", cpu: 140),
            // Automation, but below the floor.
            candidate(
                "/Users/owner/.cache/ms-playwright/chromium-1140/chrome-mac/Chromium",
                arguments: "--headless", cpu: 5
            ),
            // Not automation at all.
            candidate("/Applications/Safari.app/Contents/MacOS/Safari", cpu: 200),
        ])
        XCTAssertEqual(scanned.map(\.name), ["Google Chrome", "chromedriver"])
        XCTAssertEqual(scanned.first?.cpuPercent, 140)
    }
}
