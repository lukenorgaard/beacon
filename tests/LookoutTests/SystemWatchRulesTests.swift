import XCTest
@testable import Lookout

/// SPEC §18.2 / §18.7. Every rule is driven by hand-built snapshots on a hand-wound clock, so
/// nothing here sleeps and a 120-second sustain window costs no wall time at all.
final class SystemWatchRulesTests: XCTestCase {
    /// A clock the test moves by hand. The rules read it for "now", the history cutoff and the
    /// `since` stamps, so moving it is the only thing that makes time pass.
    final class TestClock {
        var now: Date
        init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { self.now = start }
    }

    var clock = TestClock()
    var engine = SystemRulesEngine()

    override func setUp() {
        super.setUp()
        clock = TestClock()
        let clock = self.clock
        engine = SystemRulesEngine(now: { clock.now })
    }

    // MARK: - Snapshot fixtures

    /// A machine with nothing wrong with it. Each test breaks exactly one thing.
    func healthy(at moment: Date) -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        snapshot.sampledAt = moment
        snapshot.cpuPercent = 12
        snapshot.cpuPerCore = Array(repeating: 12, count: 8)
        snapshot.memoryTotal = 64 * 1024 * 1024 * 1024
        snapshot.memoryUsed = 20 * 1024 * 1024 * 1024
        snapshot.memoryPressure = .normal
        snapshot.swapUsed = 0
        snapshot.swapOutPerSecond = 0
        snapshot.diskTotal = 1000 * 1024 * 1024 * 1024
        snapshot.diskFree = 500 * 1024 * 1024 * 1024
        snapshot.thermal = .nominal
        snapshot.uptime = 3600
        snapshot.loadAverage = [2, 2, 2]
        snapshot.processCount = 420
        return snapshot
    }

    func process(
        _ pid: Int32, _ name: String, cpu: Double, app: String? = nil, rss: UInt64 = 0
    ) -> SystemProcessLoad {
        SystemProcessLoad(pid: pid, name: name, appName: app, cpuPercent: cpu, residentBytes: rss)
    }

    // MARK: - Driver

    /// Records one snapshot every `step` seconds across the last `duration` seconds, leaving the
    /// clock where it started, then evaluates the newest one.
    @discardableResult
    func evaluate(
        over duration: TimeInterval,
        step: TimeInterval = 5,
        sensitivity: SystemWatchSensitivity = .balanced,
        _ make: (Date) -> SystemSnapshot
    ) -> [SystemSignal] {
        let end = clock.now
        var offset = -duration
        while offset <= 0 {
            clock.now = end.addingTimeInterval(offset)
            engine.record(make(clock.now))
            offset += step
        }
        clock.now = end
        return engine.evaluate(make(end), thresholds: .scaled(for: sensitivity))
    }

    func signal(_ id: String, in signals: [SystemSignal]) -> SystemSignal? {
        signals.first { $0.id == id }
    }

    func assertFires(
        _ id: String, _ signals: [SystemSignal],
        _ file: StaticString = #filePath, _ line: UInt = #line
    ) -> SystemSignal {
        guard let found = signal(id, in: signals) else {
            XCTFail("expected \(id), got \(signals.map(\.id))", file: file, line: line)
            return SystemSignal(
                id: id, severity: .info, title: "", detail: "", advice: [], since: Date()
            )
        }
        return found
    }

    // MARK: - Memory

    func testMemoryWarningFiresOncePressureHoldsForItsWindow() {
        let signals = evaluate(over: 70) { moment in
            var snapshot = self.healthy(at: moment)
            snapshot.memoryPressure = .warning
            snapshot.processes = [self.process(11, "Google Chrome", cpu: 4, rss: 9 << 30)]
            return snapshot
        }
        let memory = assertFires("memory.warning", signals)
        XCTAssertEqual(memory.severity, .warning)
        XCTAssertEqual(memory.culprit, "Google Chrome")
        XCTAssertEqual(memory.action, .openActivityMonitor)
        XCTAssertNil(signal("memory.critical", in: signals))
    }

    func testMemoryCriticalFiresOnItsShorterWindowAndNamesTheBiggestApp() {
        let signals = evaluate(over: 30) { moment in
            var snapshot = self.healthy(at: moment)
            snapshot.memoryPressure = .critical
            snapshot.memoryUsed = 60 * 1024 * 1024 * 1024
            snapshot.processes = [
                self.process(11, "Helper", cpu: 40, app: "Xcode", rss: 2 << 30),
                self.process(12, "Google Chrome", cpu: 1, rss: 30 << 30),
            ]
            return snapshot
        }
        let memory = assertFires("memory.critical", signals)
        XCTAssertEqual(memory.severity, .critical)
        // Named by memory, not by CPU — the reason the rules roll up the full process list.
        XCTAssertEqual(memory.culprit, "Google Chrome")
        XCTAssertNil(signal("memory.warning", in: signals))
    }

    func testMemoryPressureSpikeDoesNotFire() {
        let end = clock.now
        for offset in stride(from: -70.0, through: -5.0, by: 5.0) {
            clock.now = end.addingTimeInterval(offset)
            engine.record(healthy(at: clock.now))
        }
        clock.now = end
        var spike = healthy(at: end)
        spike.memoryPressure = .critical
        engine.record(spike)

        let signals = engine.evaluate(spike, thresholds: .scaled(for: .balanced))
        XCTAssertNil(signal("memory.critical", in: signals))
        XCTAssertNil(signal("memory.warning", in: signals))
    }

    // MARK: - Swap

    func testSwapThrashIsWarningAtTheHighRateAndCriticalAboveIt() {
        let warning = evaluate(over: 40) { moment in
            var snapshot = self.healthy(at: moment)
            snapshot.swapUsed = 3 * 1024 * 1024 * 1024
            snapshot.swapOutPerSecond = 500
            return snapshot
        }
        XCTAssertEqual(assertFires("swap.thrash", warning).severity, .warning)

        setUp()
        let critical = evaluate(over: 40) { moment in
            var snapshot = self.healthy(at: moment)
            snapshot.swapUsed = 3 * 1024 * 1024 * 1024
            snapshot.swapOutPerSecond = 2000
            return snapshot
        }
        let signal = assertFires("swap.thrash", critical)
        XCTAssertEqual(signal.severity, .critical)
        XCTAssertEqual(signal.action, .openActivityMonitor)
    }

    func testSwapThrashStaysQuietWhileSwapIsSmall() {
        let signals = evaluate(over: 40) { moment in
            var snapshot = self.healthy(at: moment)
            snapshot.swapUsed = 100 * 1024 * 1024
            snapshot.swapOutPerSecond = 2000
            return snapshot
        }
        XCTAssertNil(signal("swap.thrash", in: signals))
    }

    // MARK: - CPU

    func testCPUSaturatedFiresAfterItsWindowAndCarriesNoStopButton() {
        let signals = evaluate(over: 95) { moment in
            var snapshot = self.healthy(at: moment)
            snapshot.cpuPercent = 92
            snapshot.cpuPerCore = Array(repeating: 92, count: 8)
            snapshot.processes = [self.process(21, "swift-frontend", cpu: 380)]
            return snapshot
        }
        let cpu = assertFires("cpu.saturated", signals)
        XCTAssertEqual(cpu.severity, .warning)
        XCTAssertEqual(cpu.culprit, "swift-frontend")
        // SPEC §18.4: the engine cannot tell whether the culprit is one of Lookout's own agents.
        XCTAssertEqual(cpu.action, .openActivityMonitor)
        XCTAssertNil(cpu.sessionID)
    }

    func testCPUSpikeIsWorkNotTrouble() {
        let end = clock.now
        for offset in stride(from: -95.0, through: -5.0, by: 5.0) {
            clock.now = end.addingTimeInterval(offset)
            engine.record(healthy(at: clock.now))
        }
        clock.now = end
        var spike = healthy(at: end)
        spike.cpuPercent = 99
        engine.record(spike)

        XCTAssertNil(
            signal("cpu.saturated", in: engine.evaluate(spike, thresholds: .scaled(for: .balanced)))
        )
    }

    /// Covering the window in time is not the same as having watched it. One stale sample at the
    /// far edge plus twenty seconds of recent ones spans ninety seconds and says nothing at all
    /// about the seventy in between — the sample floor is what refuses that, and it is now the
    /// cadence's worth (eighteen samples at 5 s) rather than a flat three.
    func testASustainWindowNeedsItsCadenceWorthOfSamplesAndNotJustItsSpan() {
        let end = clock.now
        let busy: (Date) -> SystemSnapshot = { moment in
            var snapshot = self.healthy(at: moment)
            snapshot.cpuPercent = 92
            return snapshot
        }

        clock.now = end.addingTimeInterval(-90)
        engine.record(busy(clock.now))
        for offset in stride(from: -20.0, through: 0.0, by: 5.0) {
            clock.now = end.addingTimeInterval(offset)
            engine.record(busy(clock.now))
        }
        clock.now = end

        XCTAssertEqual(engine.sampleInterval, 5, accuracy: 0.001)
        XCTAssertEqual(engine.minimumSamples(for: 90), 18)
        XCTAssertNil(
            signal("cpu.saturated", in: engine.evaluate(busy(end), thresholds: .scaled(for: .balanced))),
            "six samples do not cover a ninety-second window at a five-second cadence"
        )

        // The same window, actually watched.
        setUp()
        XCTAssertNotNil(signal("cpu.saturated", in: evaluate(over: 95, busy)))
    }

    func testSensitivityMovesTheCPUThreshold() {
        let busy: (Date) -> SystemSnapshot = { moment in
            var snapshot = self.healthy(at: moment)
            snapshot.cpuPercent = 80
            return snapshot
        }

        // 80 % is under Balanced's 85 and over Early warning's 75.
        XCTAssertNil(signal("cpu.saturated", in: evaluate(over: 95, sensitivity: .balanced, busy)))
        setUp()
        XCTAssertNotNil(signal("cpu.saturated", in: evaluate(over: 95, sensitivity: .early, busy)))
    }

    func testSensitivityScalesTheSustainWindow() {
        let busy: (Date) -> SystemSnapshot = { moment in
            var snapshot = self.healthy(at: moment)
            snapshot.cpuPercent = 92
            return snapshot
        }

        // Critical only stretches the 90 s window to 144 s, so 95 s of evidence is not enough.
        XCTAssertNil(
            signal("cpu.saturated", in: evaluate(over: 95, sensitivity: .criticalOnly, busy))
        )
        setUp()
        XCTAssertNotNil(
            signal("cpu.saturated", in: evaluate(over: 150, sensitivity: .criticalOnly, busy))
        )
    }

    func testRunawayNamesTheAppAndOnlyCountsASinglePinnedCore() {
        let signals = evaluate(over: 130) { moment in
            var snapshot = self.healthy(at: moment)
            snapshot.cpuPercent = 40
            snapshot.processes = [
                self.process(31, "node", cpu: 101),
                self.process(32, "swift-frontend", cpu: 640),
            ]
            return snapshot
        }
        let runaway = assertFires("cpu.runaway.node", signals)
        XCTAssertEqual(runaway.severity, .warning)
        XCTAssertEqual(runaway.action, .openActivityMonitor)
        // 640 % is eight cores of real parallel work, not a hung process.
        XCTAssertNil(signal("cpu.runaway.swift-frontend", in: signals))
    }
}
