import XCTest
@testable import Lookout

final class UsageModelTests: XCTestCase {
    private func snapshot() throws -> UsageSnapshot {
        let data = try Data(contentsOf: Fixtures.usageJSON)
        return try UsageSnapshot.parse(data)
    }

    func testParsesEveryLimitFromTheRealResponse() throws {
        let usage = try snapshot()
        XCTAssertEqual(usage.limits.count, 3)
        XCTAssertEqual(usage.limits.map(\.kind), ["session", "weekly_all", "weekly_scoped"])
        XCTAssertEqual(usage.limits.map(\.percent), [10, 8, 3])
        XCTAssertEqual(usage.sessionPercent, 10)
        XCTAssertEqual(usage.weeklyPercent, 8)
    }

    func testLabelsIncludingTheScopedModelName() throws {
        let usage = try snapshot()
        XCTAssertEqual(usage.limits[0].label, "Session (5h)")
        XCTAssertEqual(usage.limits[1].label, "Weekly")
        XCTAssertEqual(usage.limits[2].label, "Fable")
        XCTAssertTrue(usage.limits[2].isScoped)
        XCTAssertEqual(usage.scopedModelNames, ["Fable"])
    }

    func testHidingAScopedModelDropsOnlyThatCard() throws {
        let usage = try snapshot()
        XCTAssertEqual(usage.visibleLimits(hidden: []).count, 3)
        let visible = usage.visibleLimits(hidden: ["Fable"])
        XCTAssertEqual(visible.count, 2)
        XCTAssertFalse(visible.contains { $0.modelName == "Fable" })
    }

    func testResetsAtParsesSixDigitFractionalSecondsAndOffset() throws {
        let usage = try snapshot()
        let session = usage.limits[0]
        let resets = try XCTUnwrap(session.resetsAt)
        XCTAssertEqual(
            resets.timeIntervalSince1970,
            ISO8601.date("2026-09-02T11:10:00Z")!.timeIntervalSince1970,
            accuracy: 1
        )

        // 2h 41m before the reset — exactly the spelling the card shows.
        let now = resets.addingTimeInterval(-(2 * 3600 + 41 * 60))
        XCTAssertEqual(session.resetsText(now: now), "resets in 2h 41m")
        // Whole minutes, floored — a countdown never claims more time than is left.
        XCTAssertEqual(
            session.resetsText(now: resets.addingTimeInterval(-90)), "resets in 1m"
        )
        XCTAssertEqual(
            session.resetsText(now: resets.addingTimeInterval(-45)), "resets in 45s"
        )
        XCTAssertEqual(session.resetsText(now: resets.addingTimeInterval(60)), "resetting now")
    }

    func testPercentColoursFollowTheThresholds() {
        XCTAssertEqual(UsageLimit.level(percent: 0, severity: "normal"), .ok)
        XCTAssertEqual(UsageLimit.level(percent: 49.9, severity: "normal"), .ok)
        XCTAssertEqual(UsageLimit.level(percent: 50, severity: "normal"), .warn)
        XCTAssertEqual(UsageLimit.level(percent: 79, severity: "normal"), .warn)
        XCTAssertEqual(UsageLimit.level(percent: 80, severity: "normal"), .critical)
        // Any severity but `normal` is red whatever the number says.
        XCTAssertEqual(UsageLimit.level(percent: 3, severity: "warning"), .critical)
    }

    func testExtraUsageIsReadButNotShownWhenDisabled() throws {
        let usage = try snapshot()
        XCTAssertFalse(usage.extraUsageEnabled)
    }

    func testFractionIsClamped() {
        let limit = UsageLimit(
            kind: "session", group: "session", percent: 140, severity: "normal",
            resetsAt: nil, modelName: nil, isActive: true
        )
        XCTAssertEqual(limit.fraction, 1)
    }

    func testMissingLimitsArrayStillParses() throws {
        let data = Data(#"{"five_hour": null}"#.utf8)
        let usage = try UsageSnapshot.parse(data)
        XCTAssertTrue(usage.limits.isEmpty)
        XCTAssertNil(usage.sessionPercent)
    }

    func testKeychainPayloadYieldsTheAccessTokenAndNothingElse() {
        let json = Data(#"{"claudeAiOauth":{"accessToken":"sk-test","refreshToken":"r"}}"#.utf8)
        XCTAssertEqual(Keychain.token(fromCredentialsJSON: json), "sk-test")
        XCTAssertNil(Keychain.token(fromCredentialsJSON: Data(#"{"mcpOAuth":{}}"#.utf8)))
        XCTAssertNil(Keychain.token(fromCredentialsJSON: Data("not json".utf8)))
    }
}
