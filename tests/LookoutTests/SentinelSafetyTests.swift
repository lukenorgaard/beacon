import Darwin
import XCTest
@testable import Lookout

final class SentinelSafetyTests: XCTestCase {
    private func identity() -> SystemProcessIdentity {
        SystemProcessIdentity(pid: 4242, name: "Google Chrome Helper (Renderer)",
            path: "/Applications/Google Chrome.app/Contents/Frameworks/Chrome.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)",
            uid: getuid(), startedAt: 12345)
    }

    func testStopRejectsReusedPIDChangedExecutableAndOtherUsers() {
        let expected = identity()
        XCTAssertNil(SystemProcessStopper.validate(current: expected, expected: expected))
        var changed = expected
        changed.startedAt += 1
        XCTAssertNotNil(SystemProcessStopper.validate(current: changed, expected: expected))
        changed = expected
        changed.path = "/bin/sleep"
        XCTAssertNotNil(SystemProcessStopper.validate(current: changed, expected: expected))
        changed = expected
        changed.uid += 1
        XCTAssertFalse(changed.canStop())
        XCTAssertFalse(changed.isChromeHelper)
    }

    func testStopProtectsSelfSystemAndMissingStartTime() {
        var process = identity()
        process.pid = getpid()
        XCTAssertFalse(process.canStop())
        process = identity()
        process.path = "/System/Library/CoreServices/WindowServer"
        XCTAssertFalse(process.canStop())
        process = identity()
        process.startedAt = 0
        XCTAssertFalse(process.canStop())
        process = identity()
        process.pid = 1
        XCTAssertFalse(process.canStop())
    }

    private func warnings(cpu: Double = 100, pressure: MemoryPressureLevel = .normal,
                          memory: UInt64 = 0, reuse: Bool = false, duration: Int = 130) -> [SystemSignal] {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let engine = SystemRulesEngine(now: { now })
        var last = SystemSnapshot()
        for offset in stride(from: 0, through: duration, by: 5) {
            now = Date(timeIntervalSince1970: 1_700_000_000 + Double(offset))
            var snapshot = SystemSnapshot()
            snapshot.sampledAt = now
            snapshot.memoryTotal = 16 << 30
            snapshot.memoryPressure = pressure
            snapshot.diskTotal = 1000 << 30
            snapshot.diskFree = 500 << 30
            var process = identity()
            if reuse && offset > 65 { process.startedAt += 1 }
            snapshot.processes = [SystemProcessLoad(pid: process.pid, name: process.name,
                appName: "Google Chrome", cpuPercent: cpu, residentBytes: memory, identity: process)]
            engine.record(snapshot)
            last = snapshot
        }
        return engine.evaluate(last, thresholds: .scaled(for: .balanced))
    }

    func testChromeStopNeedsSustainedSameProcessAndDoesNotClaimLoop() {
        let signal = warnings().first { $0.id == "cpu.runaway.Google Chrome" }
        XCTAssertEqual(signal?.action, .stopProcess(pid: 4242, name: identity().name))
        XCTAssertTrue(signal?.detail.contains("CPU alone cannot tell") == true)
        XCTAssertNil(warnings(reuse: true).first { $0.id == "cpu.runaway.Google Chrome" })
        XCTAssertNil(warnings(duration: 10).first { $0.id == "cpu.runaway.Google Chrome" })
    }

    func testChromeMemoryRequiresSystemPressureAsWellAsLargeHelper() {
        XCTAssertNil(warnings(cpu: 3, memory: 3 << 30).first { $0.id == "memory.chrome-helper" })
        XCTAssertNotNil(warnings(cpu: 3, pressure: .warning, memory: 3 << 30)
            .first { $0.id == "memory.chrome-helper" })
        XCTAssertNil(warnings(cpu: 3, pressure: .warning, memory: 3 << 30, reuse: true)
            .first { $0.id == "memory.chrome-helper" })
    }

    func testResourceHistoryIsBoundedAndResetsAfterGaps() {
        let state = SystemWatchState()
        var sample = SystemSnapshot()
        let start = Date()
        for index in 0...1000 {
            sample.sampledAt = start.addingTimeInterval(Double(index) * 5)
            state.record(sample)
        }
        XCTAssertEqual(state.resourceHistory.count, 181)
        state.record(sample)
        XCTAssertEqual(state.resourceHistory.count, 181)
        sample.sampledAt += 40
        state.record(sample)
        XCTAssertEqual(state.resourceHistory.count, 1)
        sample.sampledAt -= 10
        state.record(sample)
        XCTAssertEqual(state.resourceHistory.count, 1)
    }

    func testMemoryRankingUsesAllProcesses() {
        var snapshot = SystemSnapshot()
        snapshot.processes = [
            SystemProcessLoad(pid: 42, name: "Build", cpuPercent: 100, residentBytes: 1 << 30),
            SystemProcessLoad(pid: 43, name: "Browser", cpuPercent: 1, residentBytes: 8 << 30),
        ]
        XCTAssertEqual(Sentinel.topApps(snapshot).first?.name, "Build")
        XCTAssertEqual(Sentinel.topApps(snapshot, byMemory: true).first?.name, "Browser")
    }
}
