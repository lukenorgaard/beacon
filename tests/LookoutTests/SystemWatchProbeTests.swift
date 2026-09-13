import XCTest
@testable import Lookout

/// The one fork the engine still pays for. Its job is `helper.windowserver` and
/// `helper.networkextension` — the two rules the Sentinel app was built for — so what matters is
/// that it picks the right handful of pids, never forks for the general population, and stands
/// down when it is expensive.
final class SystemWatchProbeTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)
    private let ownUID: uid_t = 501

    // MARK: - Parser

    func testTheParserReadsPidCPUAndAPathWithSpacesInIt() {
        let output = """
              405  48.8 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
              549   0.1 /Library/SystemExtensions/88BD/com.nordvpn.macos.Shield
              840  33.5 /Applications/Little Snitch.app/Contents/MacOS/Little Snitch Daemon

            """
        let readings = SystemPrivilegedCPUProbe.parse(output)
        XCTAssertEqual(readings.count, 3)
        XCTAssertEqual(readings[0], SystemProbeReading(
            pid: 405, cpuPercent: 48.8,
            path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"
        ))
        XCTAssertEqual(readings[2].pid, 840)
        XCTAssertEqual(readings[2].cpuPercent, 33.5)
        // The path is the last field and keeps every space in it.
        XCTAssertEqual(
            readings[2].path, "/Applications/Little Snitch.app/Contents/MacOS/Little Snitch Daemon"
        )
    }

    func testTheParserSkipsAnythingItCannotRead() {
        let readings = SystemPrivilegedCPUProbe.parse(
            """
            not a row
              12 notanumber /usr/bin/thing
              13   1.0
              14   2.5 /usr/bin/real
            """
        )
        XCTAssertEqual(readings.map(\.pid), [14])
    }

    // MARK: - Selection

    private func row(_ pid: Int32, uid: uid_t, comm: String, path: String?) -> SystemProbeProcess {
        SystemProbeProcess(pid: pid, uid: uid, comm: comm, path: path)
    }

    func testOnlyOtherUsersMarkedProcessesAreWorthAFork() {
        let processes = [
            row(405, uid: 88, comm: "WindowServer",
                path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"),
            // A system extension's comm is a truncated bundle id, so the path is what identifies it.
            row(549, uid: 0, comm: "com.acme.netwo",
                path: "/Library/SystemExtensions/88BD/com.acme.network.systemextension"),
            row(560, uid: 0, comm: "com.nordvpn.ma",
                path: "/Library/PrivilegedHelperTools/com.nordvpn.macos.helper"),
            // Ours already: rusage covers it, and it is both cheaper and more precise.
            row(840, uid: 501, comm: "NordVPN", path: "/Applications/NordVPN.app/Contents/MacOS/NordVPN"),
            row(900, uid: 0, comm: "syslogd", path: "/usr/libexec/syslogd"),
        ]
        let candidates = SystemPrivilegedCPUProbe.candidates(in: processes, ownUID: ownUID)
        XCTAssertEqual(candidates.map(\.pid), [405, 549, 560])
    }

    func testAMachineWithNothingToProbeCostsNoFork() {
        let processes = [
            row(900, uid: 0, comm: "syslogd", path: "/usr/libexec/syslogd"),
            row(901, uid: 501, comm: "WindowServer", path: "/usr/bin/decoy"),
        ]
        XCTAssertTrue(SystemPrivilegedCPUProbe.candidates(in: processes, ownUID: ownUID).isEmpty)

        var forks = 0
        let probe = SystemPrivilegedCPUProbe(now: { self.clock }) { _ in
            forks += 1
            return SystemProbeRun(output: "", elapsed: 0)
        }
        let result = probe.sample([])
        XCTAssertEqual(forks, 0)
        XCTAssertTrue(result.readings.isEmpty)
        XCTAssertEqual(result.milliseconds, 0)
        XCTAssertNil(probe.lastError)
    }

    func testTheCandidateListIsBounded() {
        let processes = (0..<40).map {
            row(Int32(1000 + $0), uid: 0, comm: "x",
                path: "/Library/SystemExtensions/\($0)/thing")
        }
        XCTAssertEqual(
            SystemPrivilegedCPUProbe.candidates(in: processes, ownUID: ownUID).count,
            SystemPrivilegedCPUProbe.maximumCandidates
        )
    }

    // MARK: - Rate limiting and backoff

    private func fakeProbe(
        elapsed: TimeInterval = 0.02, forks: @escaping () -> Void = {}
    ) -> SystemPrivilegedCPUProbe {
        SystemPrivilegedCPUProbe(now: { self.clock }) { pids in
            forks()
            let rows = pids.map { "  \($0)  12.5 /System/x/WindowServer" }.joined(separator: "\n")
            return SystemProbeRun(output: rows, elapsed: elapsed)
        }
    }

    func testTheProbeForksAtMostOncePerIntervalHoweverOftenItIsAsked() {
        var forks = 0
        let probe = fakeProbe { forks += 1 }
        let candidates = [SystemProbeCandidate(pid: 405)]

        for _ in 0..<7 { _ = probe.sample(candidates) }
        XCTAssertEqual(forks, 1, "a burst of process samples must still cost one fork")

        // The cached reading is what the cycles in between see, so WindowServer does not blink out.
        XCTAssertEqual(probe.sample(candidates).readings.first?.cpuPercent, 12.5)

        clock.addTimeInterval(SystemPrivilegedCPUProbe.minimumInterval + 1)
        _ = probe.sample(candidates)
        XCTAssertEqual(forks, 2)
    }

    func testAnExpensiveForkStandsTheProbeDownForTwoCycles() {
        var forks = 0
        let probe = fakeProbe(elapsed: 0.8) { forks += 1 }
        let candidates = [SystemProbeCandidate(pid: 405)]

        _ = probe.sample(candidates)
        XCTAssertEqual(forks, 1)
        XCTAssertNotNil(probe.lastError)
        XCTAssertTrue(probe.lastError?.contains("0.8s") == true, "\(probe.lastError ?? "nil")")

        // Two cycles skipped even once the interval has passed.
        for _ in 0..<SystemPrivilegedCPUProbe.backoffCycles {
            clock.addTimeInterval(SystemPrivilegedCPUProbe.minimumInterval + 1)
            _ = probe.sample(candidates)
            XCTAssertEqual(forks, 1)
        }
        clock.addTimeInterval(SystemPrivilegedCPUProbe.minimumInterval + 1)
        _ = probe.sample(candidates)
        XCTAssertEqual(forks, 2)
    }

    func testAProbeThatCannotRunSaysSoInsteadOfReportingZero() {
        let probe = SystemPrivilegedCPUProbe(now: { self.clock }) { _ in
            SystemProbeRun(output: nil, elapsed: 2.0)
        }
        let result = probe.sample([SystemProbeCandidate(pid: 405)])
        XCTAssertTrue(result.readings.isEmpty)
        XCTAssertEqual(probe.lastError, "Could not read system process CPU.")
    }

    func testAHealthyForkClearsAnEarlierComplaint() {
        var elapsed = 0.8
        let probe = SystemPrivilegedCPUProbe(now: { self.clock }) { pids in
            SystemProbeRun(
                output: pids.map { "  \($0)  1.0 /System/x/WindowServer" }.joined(separator: "\n"),
                elapsed: elapsed
            )
        }
        let candidates = [SystemProbeCandidate(pid: 405)]
        _ = probe.sample(candidates)
        XCTAssertNotNil(probe.lastError)

        elapsed = 0.02
        for _ in 0...SystemPrivilegedCPUProbe.backoffCycles {
            clock.addTimeInterval(SystemPrivilegedCPUProbe.minimumInterval + 1)
            _ = probe.sample(candidates)
        }
        XCTAssertNil(probe.lastError)
    }

    // MARK: - The real thing

    /// SPEC §18.2: this is the whole point. If this stops finding WindowServer, the two rules
    /// the owner built Sentinel for cannot fire at all.
    func testTheRealProbeFindsWindowServerOnThisMachine() throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/bin/ps"), "no /bin/ps on this machine"
        )
        let sampler = SystemProcessSampler()
        // The first cycle is the one that forks; the second reuses its reading, which is exactly
        // how the watcher sees it between process cycles.
        let forked = sampler.sample()
        Thread.sleep(forTimeInterval: 0.6)
        let sample = sampler.sample()
        XCTAssertGreaterThan(forked.privilegedMilliseconds, 0, "the first cycle must probe")
        XCTAssertEqual(sample.privilegedMilliseconds, 0, "the second must reuse the reading")

        guard let windowServer = sample.processes.first(where: { $0.name == "WindowServer" }) else {
            throw XCTSkip("no WindowServer on this machine (headless CI)")
        }
        XCTAssertGreaterThanOrEqual(windowServer.cpuPercent, 0)
        XCTAssertTrue(windowServer.cpuPercent.isFinite)
        XCTAssertEqual(sample.windowServerCPU, windowServer.cpuPercent, accuracy: 0.001)
        XCTAssertNil(sample.probeError)
        print(
            String(
                format: "sentinel probe: WindowServer %.1f%%, extensions %.1f%%, fork %.1f ms",
                sample.windowServerCPU, sample.networkExtensionCPU, forked.privilegedMilliseconds
            )
        )
    }
}
