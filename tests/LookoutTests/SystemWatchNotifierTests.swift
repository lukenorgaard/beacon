import XCTest
@testable import Lookout

/// SPEC §18.5 / §18.7: 20 minutes of silence per rule id, nothing below the sensitivity's
/// threshold, and nothing at all while notifications are off.
final class SystemWatchNotifierTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)

    private func signal(_ id: String, _ severity: SignalSeverity) -> SystemSignal {
        SystemSignal(
            id: id, severity: severity, title: id, detail: "detail",
            advice: ["do the thing"], since: clock
        )
    }

    /// A notifier whose only side effect is appending to `delivered`.
    private func notifier(
        sensitivity: SystemWatchSensitivity = .balanced,
        enabled: Bool = true,
        delivered: @escaping (SystemSignal) -> Void
    ) -> SystemWatchNotifier {
        SystemWatchNotifier(
            sensitivity: { sensitivity },
            notificationsEnabled: { enabled },
            now: { self.clock },
            deliver: delivered
        )
    }

    func testTheSameRuleIsDeliveredOnceInsideItsCooldown() {
        var delivered: [String] = []
        let center = notifier { delivered.append($0.id) }

        center.process([signal("cpu.saturated", .warning)])
        clock.addTimeInterval(5 * 60)
        center.process([signal("cpu.saturated", .warning)])
        clock.addTimeInterval(14 * 60)
        center.process([signal("cpu.saturated", .warning)])

        XCTAssertEqual(delivered, ["cpu.saturated"])

        // Past twenty minutes it is allowed to speak again.
        clock.addTimeInterval(2 * 60)
        center.process([signal("cpu.saturated", .warning)])
        XCTAssertEqual(delivered, ["cpu.saturated", "cpu.saturated"])
    }

    func testDifferentRulesEachGetTheirOwnCooldown() {
        var delivered: [String] = []
        let center = notifier { delivered.append($0.id) }

        center.process([signal("cpu.saturated", .warning), signal("disk.low", .critical)])
        XCTAssertEqual(Set(delivered), ["cpu.saturated", "disk.low"])
    }

    func testARuleThatGetsWorseBreaksItsOwnCooldown() {
        var delivered: [SignalSeverity] = []
        let center = notifier { delivered.append($0.severity) }

        center.process([signal("swap.thrash", .warning)])
        clock.addTimeInterval(60)
        center.process([signal("swap.thrash", .warning)])
        clock.addTimeInterval(60)
        center.process([signal("swap.thrash", .critical)])

        XCTAssertEqual(delivered, [.warning, .critical])
    }

    func testNothingBelowTheSensitivitysThresholdIsDelivered() {
        var delivered: [String] = []
        let center = notifier(sensitivity: .criticalOnly) { delivered.append($0.id) }

        center.process([signal("uptime.restart", .info), signal("cpu.saturated", .warning)])
        XCTAssertTrue(delivered.isEmpty)

        center.process([signal("call.atrisk", .critical)])
        XCTAssertEqual(delivered, ["call.atrisk"])
    }

    func testEarlyWarningLetsEvenInformationThrough() {
        var delivered: [String] = []
        let center = notifier(sensitivity: .early) { delivered.append($0.id) }
        center.process([signal("uptime.restart", .info)])
        XCTAssertEqual(delivered, ["uptime.restart"])
    }

    func testNothingIsDeliveredWhileNotificationsAreOff() {
        var delivered: [String] = []
        let center = notifier(enabled: false) { delivered.append($0.id) }
        center.process([signal("call.atrisk", .critical)])
        XCTAssertTrue(delivered.isEmpty)
    }

    // MARK: - The cooldown on its own

    func testASignalThatFlickersCannotResetItsOwnCooldown() {
        var cooldown = SystemSignalCooldown(window: 20 * 60)
        let first = cooldown.admit(
            [signal("memory.warning", .warning)], minimum: .warning, enabled: true, now: clock
        )
        XCTAssertEqual(first.count, 1)

        // Gone for a cycle, back the next one: the entry expires by age, never by absence.
        clock.addTimeInterval(10)
        _ = cooldown.admit([], minimum: .warning, enabled: true, now: clock)
        clock.addTimeInterval(10)
        let again = cooldown.admit(
            [signal("memory.warning", .warning)], minimum: .warning, enabled: true, now: clock
        )
        XCTAssertTrue(again.isEmpty)
    }

    func testTurningNotificationsBackOnDoesNotLandInsideACooldownNobodySaw() {
        var cooldown = SystemSignalCooldown(window: 20 * 60)
        _ = cooldown.admit(
            [signal("disk.low", .critical)], minimum: .warning, enabled: false, now: clock
        )
        clock.addTimeInterval(30)
        let admitted = cooldown.admit(
            [signal("disk.low", .critical)], minimum: .warning, enabled: true, now: clock
        )
        XCTAssertEqual(admitted.map(\.id), ["disk.low"])
    }

    func testAnEntryOlderThanThreeCooldownsIsForgotten() {
        var cooldown = SystemSignalCooldown(window: 60)
        _ = cooldown.admit(
            [signal("thermal.pressure", .warning)], minimum: .warning, enabled: true, now: clock
        )
        clock.addTimeInterval(200)
        let admitted = cooldown.admit(
            [signal("thermal.pressure", .warning)], minimum: .warning, enabled: true, now: clock
        )
        XCTAssertEqual(admitted.count, 1)
    }
}
