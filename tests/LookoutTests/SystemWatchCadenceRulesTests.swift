import XCTest
@testable import Lookout

extension SystemWatchRulesTests {
    // MARK: - Cadence (SPEC §18.6)

    /// One aligned grid of snapshots the way `SystemWatcher` actually produces them: the machine
    /// half moves every `machine` seconds, and the process half — the process list, the orphans,
    /// the process count — is refreshed only every `process` seconds and carried over in between,
    /// which is exactly what a `SystemProcessSample` held across cycles looks like to the rules.
    private func grid(
        over duration: TimeInterval,
        machine: TimeInterval = 5,
        process: TimeInterval = 15,
        end: Date,
        _ make: (Date) -> SystemSnapshot
    ) -> [SystemSnapshot] {
        var snapshots: [SystemSnapshot] = []
        var carried: SystemSnapshot?
        var lastProcessAt: Date?
        var offset = -duration
        while offset <= 0 {
            let moment = end.addingTimeInterval(offset)
            var snapshot = make(moment)
            let due = lastProcessAt.map { moment.timeIntervalSince($0) >= process } ?? true
            if due {
                carried = snapshot
                lastProcessAt = moment
            } else if let carried {
                snapshot.processes = carried.processes
                snapshot.orphans = carried.orphans
                snapshot.processCount = carried.processCount
                snapshot.topApps = carried.topApps
                snapshot.windowServerCPU = carried.windowServerCPU
                snapshot.networkExtensionCPU = carried.networkExtensionCPU
            }
            snapshots.append(snapshot)
            offset += machine
        }
        return snapshots
    }

    /// Records a whole grid into a fresh engine on the hand-wound clock and evaluates the last
    /// snapshot — a fresh engine each time so two sensitivities can be run over the same history.
    func signals(
        for snapshots: [SystemSnapshot], sensitivity: SystemWatchSensitivity
    ) -> [SystemSignal] {
        let clock = self.clock
        let end = clock.now
        let engine = SystemRulesEngine(now: { clock.now })
        for snapshot in snapshots {
            clock.now = snapshot.sampledAt
            engine.record(snapshot)
        }
        clock.now = end
        defer { clock.now = end }
        return engine.evaluate(
            snapshots[snapshots.count - 1], thresholds: .scaled(for: sensitivity)
        )
    }

    /// The bug: the machine cadence used to drop to 15 s whenever the Sentinel tab was not the one
    /// on screen — which is nearly always — and the sample floor was a fixed 3. A 20-second window
    /// at 15 s holds two samples, so `call.atrisk` and `memory.critical` could not fire at all
    /// while the owner was looking at any other tab. The machine half now stays at 5 s and only
    /// the expensive process half is throttled.
    func testTheTwentySecondRulesFireOnTheMachineGridWhileProcessSamplingIsThrottled() {
        let end = clock.now
        let snapshots = grid(over: 60, machine: 5, process: 15, end: end) { moment in
            var snapshot = self.healthy(at: moment)
            snapshot.cpuPercent = 78
            snapshot.memoryPressure = .critical
            snapshot.memoryUsed = 60 * 1024 * 1024 * 1024
            snapshot.processes = [
                self.process(61, "cameracaptured", cpu: 3),
                self.process(62, "Google Chrome", cpu: 20, rss: 30 << 30),
            ]
            return snapshot
        }
        // 5 s apart, not 15: the machine half is what every sustain window is measured in.
        XCTAssertEqual(
            snapshots[1].sampledAt.timeIntervalSince(snapshots[0].sampledAt), 5, accuracy: 0.001
        )

        let fired = signals(for: snapshots, sensitivity: .balanced)
        _ = assertFires("call.atrisk", fired)
        _ = assertFires("memory.critical", fired)
    }

    /// And the second half of the fix: the floor moves with the cadence, so a future change to how
    /// often the engine samples cannot silently re-open the same hole. At 15 s the same two rules
    /// still fire — the floor drops to 2 rather than staying at an unreachable 3.
    func testTheSameRulesStillFireIfTheCadenceEverGoesBackToFifteen() {
        let end = clock.now
        let snapshots = grid(over: 90, machine: 15, process: 15, end: end) { moment in
            var snapshot = self.healthy(at: moment)
            snapshot.cpuPercent = 78
            snapshot.memoryPressure = .critical
            snapshot.processes = [self.process(61, "cameracaptured", cpu: 3)]
            return snapshot
        }
        let fired = signals(for: snapshots, sensitivity: .balanced)
        _ = assertFires("call.atrisk", fired)
        _ = assertFires("memory.critical", fired)
    }

    /// The floor is `max(2, window / interval)`, and a window of `w` at cadence `i` holds
    /// `floor(w / i) + 1` samples — so it always leaves one sample of slack and can never be
    /// unsatisfiable, whatever cadence the engine is fed at.
    func testTheSampleFloorIsAlwaysReachableAtEveryCadence() {
        for interval in [1.0, 5.0, 15.0, 30.0] {
            let end = clock.now
            let clock = self.clock
            let engine = SystemRulesEngine(now: { clock.now })
            let snapshots = grid(over: 300, machine: interval, process: interval, end: end) {
                self.healthy(at: $0)
            }
            for snapshot in snapshots {
                clock.now = snapshot.sampledAt
                engine.record(snapshot)
            }
            clock.now = end

            XCTAssertEqual(engine.sampleInterval, interval, accuracy: 0.001)
            for window in [20.0, 30.0, 45.0, 60.0, 90.0, 120.0] {
                let floor = engine.minimumSamples(for: window)
                XCTAssertGreaterThanOrEqual(floor, 2, "one sample is never 'sustained'")
                // A window shorter than two samples is unprovable by design — you cannot claim
                // twenty seconds of anything while sampling every thirty. The machine half of the
                // engine is fixed at 5 s precisely so that never applies to a real rule.
                guard window >= 2 * interval else { continue }
                XCTAssertLessThanOrEqual(
                    floor, Int(window / interval) + 1,
                    "a \(window)s window at \(interval)s cadence cannot hold \(floor) samples"
                )
            }
        }
    }

    /// "Early warning" lowers thresholds and halves sustain windows, so on one and the same
    /// history it can only ever say more than "Balanced" — never less. A sample floor that did not
    /// move with the cadence could break that (a halved window holding fewer samples than the
    /// floor), which is the property this pins.
    func testEarlyWarningNeverFiresFewerRulesThanBalancedOnTheSameHistory() {
        let end = clock.now
        let snapshots = grid(over: 300, machine: 5, process: 15, end: end) { moment in
            var snapshot = self.healthy(at: moment)
            snapshot.cpuPercent = 92
            snapshot.cpuPerCore = Array(repeating: 92, count: 8)
            snapshot.memoryPressure = .critical
            snapshot.memoryUsed = 60 * 1024 * 1024 * 1024
            snapshot.swapUsed = 6 * 1024 * 1024 * 1024
            snapshot.swapOutPerSecond = 900
            snapshot.diskFree = 20 * 1024 * 1024 * 1024
            snapshot.thermal = .serious
            snapshot.uptime = 10 * 86400
            snapshot.processCount = 980
            snapshot.windowServerCPU = 44
            snapshot.networkExtensionCPU = 30
            snapshot.processes = [
                self.process(61, "cameracaptured", cpu: 3),
                self.process(62, "NordVPN", cpu: 30),
                self.process(63, "node", cpu: 100),
                // Between the two runaway thresholds: 85 at Early, 95 at Balanced.
                self.process(64, "worker", cpu: 88),
                self.process(65, "Google Chrome", cpu: 20, app: "Google Chrome", rss: 30 << 30),
            ]
            return snapshot
        }

        let balanced = signals(for: snapshots, sensitivity: .balanced)
        let early = signals(for: snapshots, sensitivity: .early)

        XCTAssertGreaterThanOrEqual(
            early.count, balanced.count,
            "Early warning fired \(early.map(\.id)) against Balanced's \(balanced.map(\.id))"
        )
        XCTAssertTrue(
            Set(early.map(\.id)).isSuperset(of: Set(balanced.map(\.id))),
            "Balanced fired \(Set(balanced.map(\.id)).subtracting(early.map(\.id))) "
                + "and Early did not"
        )
        // Not a vacuous comparison: both said plenty, and Early found the one Balanced could not.
        XCTAssertGreaterThan(balanced.count, 5)
        XCTAssertTrue(early.contains { $0.id == "cpu.runaway.worker" })
        XCTAssertFalse(balanced.contains { $0.id == "cpu.runaway.worker" })
    }

    // MARK: - Presentation

    func testSinceStaysPutWhileARuleKeepsFiring() {
        let busy: (Date) -> SystemSnapshot = { moment in
            var snapshot = self.healthy(at: moment)
            snapshot.cpuPercent = 92
            return snapshot
        }
        let first = assertFires("cpu.saturated", evaluate(over: 95, busy))

        // Half a minute more of the same, at the engine's own cadence — a rule cannot hold its
        // streak across samples that were never taken.
        for _ in 0..<6 {
            clock.now = clock.now.addingTimeInterval(5)
            engine.record(busy(clock.now))
        }
        let second = assertFires(
            "cpu.saturated", engine.evaluate(busy(clock.now), thresholds: .scaled(for: .balanced))
        )
        XCTAssertEqual(first.since, second.since)

        // A rule that stops firing starts its streak over. The idle stretch has to be longer than
        // the window itself, or the calm sample is still inside it and nothing can fire at all.
        clock.now = clock.now.addingTimeInterval(200)
        engine.record(healthy(at: clock.now))
        XCTAssertNil(
            signal(
                "cpu.saturated",
                in: engine.evaluate(healthy(at: clock.now), thresholds: .scaled(for: .balanced))
            )
        )

        clock.now = clock.now.addingTimeInterval(120)
        let restarted = assertFires("cpu.saturated", evaluate(over: 95, busy))
        XCTAssertGreaterThan(restarted.since, first.since)
    }

    func testSignalsComeBackSortedWorstFirst() {
        let signals = evaluate(over: 130) { moment in
            var snapshot = self.healthy(at: moment)
            snapshot.diskFree = 20 * 1024 * 1024 * 1024   // critical
            snapshot.windowServerCPU = 44                  // warning
            snapshot.processCount = 980                    // info
            return snapshot
        }
        XCTAssertEqual(
            signals.map(\.severity), signals.map(\.severity).sorted(by: >),
            "severities: \(signals.map { "\($0.id)=\($0.severity)" })"
        )
        XCTAssertEqual(signals.first?.id, "disk.low")
        XCTAssertNotNil(signal("process.sprawl", in: signals))
    }

    func testAHealthyMachineReportsNothing() {
        XCTAssertTrue(evaluate(over: 200) { self.healthy(at: $0) }.isEmpty)
    }
}
