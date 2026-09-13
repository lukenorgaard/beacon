import XCTest
@testable import Lookout

extension SystemWatchRulesTests {
    // MARK: - Orphans

    func testOrphanedProcessesFireWithAStopButtonForTheWorstOne() {
        let signals = evaluate(over: 50) { moment in
            var snapshot = self.healthy(at: moment)
            snapshot.orphans = [
                OrphanedProcess(
                    pid: 4242, name: "yes", cpuPercent: 99, elapsed: 3600,
                    reason: "a bare command with no parent process left"
                ),
                OrphanedProcess(
                    pid: 4243, name: "yes", cpuPercent: 60, elapsed: 1800,
                    reason: "a bare command with no parent process left"
                ),
            ]
            return snapshot
        }
        let orphaned = assertFires("process.orphaned", signals)
        XCTAssertEqual(orphaned.severity, .warning)
        XCTAssertEqual(orphaned.culprit, "yes")
        XCTAssertEqual(orphaned.action, .stopProcess(pid: 4242, name: "yes"))
        XCTAssertTrue(orphaned.detail.contains("2× yes"))
    }

    /// The classification is an inference about somebody else's process (see `SystemOrphans`), so
    /// however much CPU it is burning this rule never escalates to critical: critical colours the
    /// menu-bar dot and sends a time-sensitive notification, and being wrong about that is worse
    /// than being late about a runaway browser.
    func testOrphansNeverEscalateToCriticalHoweverMuchTheyBurn() {
        let signals = evaluate(over: 50) { moment in
            var snapshot = self.healthy(at: moment)
            snapshot.orphans = [
                OrphanedProcess(
                    pid: 7, name: "Google Chrome", cpuPercent: 240, elapsed: 900,
                    reason: "started by a script (--headless); its own parent has exited and "
                        + "launchd (pid 1) adopted it"
                )
            ]
            return snapshot
        }
        let orphaned = assertFires("process.orphaned", signals)
        XCTAssertEqual(orphaned.severity, .warning)
    }

    /// The wording, because it is the part that told the owner something untrue: the old text
    /// said "nothing will ever stop them" over a list that included ssh-agent and postgres.
    func testTheOrphanWarningHedgesAndNamesTheParentItHasNow() {
        let signals = evaluate(over: 50) { moment in
            var snapshot = self.healthy(at: moment)
            snapshot.orphans = [
                OrphanedProcess(
                    pid: 7, name: "chromedriver", cpuPercent: 90, elapsed: 900,
                    reason: "started by a script (chromedriver); its own parent has exited and "
                        + "launchd (pid 1) adopted it"
                )
            ]
            return snapshot
        }
        let orphaned = assertFires("process.orphaned", signals)
        XCTAssertTrue(orphaned.title.contains("may be abandoned"))
        XCTAssertTrue(orphaned.detail.contains("may be abandoned"))
        XCTAssertTrue(orphaned.detail.contains("launchd (pid 1)"))
        XCTAssertFalse(orphaned.detail.contains("nothing will ever stop them"))
        XCTAssertFalse(
            orphaned.advice.contains { $0.contains("always safe") },
            "Stop is behind a confirmation precisely because it is not always safe"
        )
        // The button is still there — the hedge is in the words, not in taking the action away.
        XCTAssertEqual(orphaned.action, .stopProcess(pid: 7, name: "chromedriver"))
    }

    func testASingleQuietOrphanIsNotWorthInterruptingFor() {
        let signals = evaluate(over: 50) { moment in
            var snapshot = self.healthy(at: moment)
            snapshot.orphans = [
                OrphanedProcess(pid: 7, name: "node", cpuPercent: 25, elapsed: 60, reason: "x")
            ]
            return snapshot
        }
        XCTAssertNil(signal("process.orphaned", in: signals))
    }

    // MARK: - Helpers

    func testWindowServerFiresOnItsOwnSustainedLoad() {
        let signals = evaluate(over: 70) { moment in
            var snapshot = self.healthy(at: moment)
            snapshot.windowServerCPU = 44
            return snapshot
        }
        let windowServer = assertFires("helper.windowserver", signals)
        XCTAssertEqual(windowServer.culprit, "WindowServer")
        XCTAssertEqual(windowServer.action, .openActivityMonitor)
    }

    func testNetworkExtensionFiresAndNamesTheProduct() {
        let signals = evaluate(over: 70) { moment in
            var snapshot = self.healthy(at: moment)
            snapshot.processes = [self.process(51, "NordVPN", cpu: 31)]
            snapshot.networkExtensionCPU = 31
            return snapshot
        }
        let helper = assertFires("helper.networkextension", signals)
        XCTAssertEqual(helper.culprit, "NordVPN")
        XCTAssertEqual(helper.severity, .warning)
    }

    // MARK: - Disk, thermal, uptime, sprawl

    func testDiskLowIsAWarningAndOpensSystemSettings() {
        var snapshot = healthy(at: clock.now)
        snapshot.diskFree = 80 * 1024 * 1024 * 1024
        engine.record(snapshot)
        let disk = assertFires(
            "disk.low", engine.evaluate(snapshot, thresholds: .scaled(for: .balanced))
        )
        XCTAssertEqual(disk.severity, .warning)
        XCTAssertEqual(disk.action, .openSystemSettings)
    }

    func testDiskCriticalBelowFivePercent() {
        var snapshot = healthy(at: clock.now)
        snapshot.diskFree = 40 * 1024 * 1024 * 1024
        engine.record(snapshot)
        let disk = assertFires(
            "disk.low", engine.evaluate(snapshot, thresholds: .scaled(for: .balanced))
        )
        XCTAssertEqual(disk.severity, .critical)
    }

    func testThermalPressureNeedsToHold() {
        let signals = evaluate(over: 40) { moment in
            var snapshot = self.healthy(at: moment)
            snapshot.thermal = .serious
            return snapshot
        }
        let thermal = assertFires("thermal.pressure", signals)
        XCTAssertEqual(thermal.severity, .warning)
        XCTAssertEqual(thermal.action, .openActivityMonitor)
    }

    func testUptimeIsInformationalFirstAndAWarningLater() {
        var week = healthy(at: clock.now)
        week.uptime = 8 * 86400
        engine.record(week)
        let info = assertFires("uptime.restart", engine.evaluate(week, thresholds: .scaled(for: .balanced)))
        XCTAssertEqual(info.severity, .info)
        XCTAssertNil(info.action)

        setUp()
        var fortnight = healthy(at: clock.now)
        fortnight.uptime = 15 * 86400
        engine.record(fortnight)
        let warning = assertFires(
            "uptime.restart", engine.evaluate(fortnight, thresholds: .scaled(for: .balanced))
        )
        XCTAssertEqual(warning.severity, .warning)
    }

    func testProcessSprawlIsInformationalAndNamesTheWorstOffender() {
        let signals = evaluate(over: 130) { moment in
            var snapshot = self.healthy(at: moment)
            snapshot.processCount = 980
            snapshot.processes = (0..<9).map {
                self.process(Int32(100 + $0), "Chrome Helper", cpu: 1, app: "Google Chrome")
            }
            return snapshot
        }
        let sprawl = assertFires("process.sprawl", signals)
        XCTAssertEqual(sprawl.severity, .info)
        XCTAssertEqual(sprawl.culprit, "Google Chrome")
    }

    // MARK: - Call risk

    func testCallAtRiskNeedsEvidenceOfAnActualCall() {
        let strained: (Date) -> SystemSnapshot = { moment in
            var snapshot = self.healthy(at: moment)
            snapshot.cpuPercent = 78
            return snapshot
        }
        XCTAssertNil(signal("call.atrisk", in: evaluate(over: 30, strained)))

        setUp()
        let signals = evaluate(over: 30) { moment in
            var snapshot = strained(moment)
            snapshot.processes = [self.process(61, "cameracaptured", cpu: 3)]
            return snapshot
        }
        let call = assertFires("call.atrisk", signals)
        XCTAssertEqual(call.severity, .critical)
        XCTAssertEqual(call.action, .openActivityMonitor)
    }
}
