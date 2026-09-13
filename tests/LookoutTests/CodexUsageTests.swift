import XCTest
@testable import Lookout

/// SPEC §17.7: parsing `~/.lookout/codex-usage.json`, including the common real-machine shape —
/// `secondary` and `limit_name` both null — which must render the 5-hour bar alone and never
/// crash.
final class CodexUsageTests: XCTestCase {
    // MARK: - The checked-in fixture: the common, degraded shape

    func testTheCheckedInFixtureParsesWithOnlyThePrimaryWindow() throws {
        let data = try Data(contentsOf: Fixtures.codexUsageJSON)
        let snapshot = try XCTUnwrap(CodexUsageSnapshot.parse(data))

        XCTAssertNotNil(snapshot.primary)
        XCTAssertNil(snapshot.secondary, "secondary is null on a real machine (SPEC §17.7)")
        XCTAssertNil(snapshot.limitName)
        XCTAssertNil(snapshot.planType)
        XCTAssertNil(snapshot.caption, "both caption halves are null, so there is no caption")

        let primary = try XCTUnwrap(snapshot.primary)
        XCTAssertEqual(primary.usedPercent, 42)
        XCTAssertEqual(primary.windowMinutes, 300)
        XCTAssertNotNil(primary.resetsAt)
    }

    // MARK: - The full shape

    func testAFullSnapshotParsesBothWindowsAndBothCaptionHalves() throws {
        let json = """
        {
          "updated": "2026-09-03T18:00:00Z",
          "limit_name": "5h-window",
          "plan_type": "pro",
          "primary": {"used_percent": 61, "window_minutes": 300, "resets_at": 1788465600},
          "secondary": {"used_percent": 8, "window_minutes": 10080, "resets_at": 1789000000}
        }
        """
        let snapshot = try XCTUnwrap(CodexUsageSnapshot.parse(Data(json.utf8)))
        XCTAssertEqual(snapshot.caption, "5h-window · pro")
        XCTAssertEqual(snapshot.primary?.usedPercent, 61)
        XCTAssertEqual(snapshot.secondary?.usedPercent, 8)
        XCTAssertNotNil(snapshot.updated)
    }

    /// SPEC §17.7: only one of `limit_name`/`plan_type` present still makes a caption.
    func testACaptionWithOnlyOneHalfOmitsTheOtherRatherThanShowingAGap() throws {
        let json = #"{"limit_name":"5h-window","plan_type":null,"primary":null,"secondary":null}"#
        let snapshot = try XCTUnwrap(CodexUsageSnapshot.parse(Data(json.utf8)))
        XCTAssertEqual(snapshot.caption, "5h-window")
    }

    // MARK: - Tolerance / never crash

    func testMalformedJSONParsesToNilRatherThanThrowing() {
        XCTAssertNil(CodexUsageSnapshot.parse(Data("not json".utf8)))
        XCTAssertNil(CodexUsageSnapshot.parse(Data()))
    }

    /// An empty `{}` window object carries nothing usable — treated the same as absent.
    func testAWindowObjectWithNothingUsableInItIsTreatedAsAbsent() throws {
        let json = #"{"primary":{},"secondary":{"foo":"bar"}}"#
        let snapshot = try XCTUnwrap(CodexUsageSnapshot.parse(Data(json.utf8)))
        XCTAssertNil(snapshot.primary)
        XCTAssertNil(snapshot.secondary)
    }

    func testNumbersArriveAsIntDoubleOrString() throws {
        let json = #"{"primary":{"used_percent":"55","window_minutes":300,"resets_at":1788465600.0}}"#
        let snapshot = try XCTUnwrap(CodexUsageSnapshot.parse(Data(json.utf8)))
        XCTAssertEqual(snapshot.primary?.usedPercent, 55)
    }

    // MARK: - CodexUsageWindow

    func testFractionIsClampedZeroToOne() {
        XCTAssertEqual(CodexUsageWindow(usedPercent: 140, windowMinutes: nil, resetsAt: nil).fraction, 1)
        XCTAssertEqual(CodexUsageWindow(usedPercent: -5, windowMinutes: nil, resetsAt: nil).fraction, 0)
        XCTAssertEqual(CodexUsageWindow(usedPercent: nil, windowMinutes: nil, resetsAt: nil).fraction, 0)
    }

    func testLevelFollowsTheSameThresholdsAsTheClaudeUsageCards() {
        XCTAssertEqual(CodexUsageWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil).level, .ok)
        XCTAssertEqual(CodexUsageWindow(usedPercent: 60, windowMinutes: nil, resetsAt: nil).level, .warn)
        XCTAssertEqual(CodexUsageWindow(usedPercent: 95, windowMinutes: nil, resetsAt: nil).level, .critical)
    }

    func testResetsTextIsNilWithoutAResetsAtAndSpelledLikeTheClaudeCards() {
        XCTAssertNil(CodexUsageWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil).resetsText())

        let soon = CodexUsageWindow(
            usedPercent: 10, windowMinutes: 300, resetsAt: Date().addingTimeInterval(3661)
        )
        XCTAssertEqual(soon.resetsText(), "resets in 1h 1m")

        let past = CodexUsageWindow(
            usedPercent: 10, windowMinutes: 300, resetsAt: Date().addingTimeInterval(-10)
        )
        XCTAssertEqual(past.resetsText(), "resetting now")

        // 4.5 days out — clear of the day/hour rounding boundary a test's own elapsed
        // milliseconds could otherwise flip (SPEC: same "Nd Nh" spelling the Claude cards use).
        let weekAway = CodexUsageWindow(
            usedPercent: 10, windowMinutes: 10080, resetsAt: Date().addingTimeInterval(4.5 * 86_400)
        )
        let weekAwayText = weekAway.resetsText()
        XCTAssertTrue(weekAwayText?.hasPrefix("resets in 4d") ?? false, "\(weekAwayText ?? "nil")")
    }

    // MARK: - Reading the file (SPEC §17.7: "hidden when the file is missing")

    func testReaderReturnsNilWhenTheFileDoesNotExist() {
        let home = LookoutHome(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-codexusage-\(UUID().uuidString)"))
        XCTAssertNil(CodexUsageReader.read(home: home))
    }

    func testReaderParsesARealFileOnDisk() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-codexusage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = LookoutHome(root: root)

        try Data(contentsOf: Fixtures.codexUsageJSON).write(to: root.appendingPathComponent("codex-usage.json"))
        let snapshot = try XCTUnwrap(CodexUsageReader.read(home: home))
        XCTAssertNotNil(snapshot.primary)
        XCTAssertNil(snapshot.secondary)
    }

    // MARK: - Usage tab card count (SPEC §17.7: "render the 5-hour bar alone")

    func testCardCountIsZeroNilOneOrTwo() {
        XCTAssertEqual(UsageView.codexCardCount(nil), 0)

        var onlyPrimary = CodexUsageSnapshot()
        onlyPrimary.primary = CodexUsageWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil)
        XCTAssertEqual(UsageView.codexCardCount(onlyPrimary), 1)

        var both = onlyPrimary
        both.secondary = CodexUsageWindow(usedPercent: 5, windowMinutes: 10080, resetsAt: nil)
        XCTAssertEqual(UsageView.codexCardCount(both), 2)

        // A snapshot with neither window (only `updated`/`limit_name`) still renders zero bars,
        // never a crash.
        var neither = CodexUsageSnapshot()
        neither.limitName = "5h-window"
        XCTAssertEqual(UsageView.codexCardCount(neither), 0)
    }
}
