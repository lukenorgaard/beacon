import XCTest
@testable import Lookout

/// The Codex bar is named by its window length — a weekly limit was labelled "5 hour" before.
final class CodexUsageWindowTitleTests: XCTestCase {
    private func window(_ minutes: Double?) -> CodexUsageWindow {
        var w = CodexUsageWindow()
        w.windowMinutes = minutes
        w.usedPercent = 1
        return w
    }

    func testTheFamiliarWindowsKeepTheirNames() {
        XCTAssertEqual(window(300).title, "5 hour")
        XCTAssertEqual(window(10080).title, "Weekly")
    }

    func testOtherWindowsAreSpelledOut() {
        XCTAssertEqual(window(60).title, "1 hour")
        XCTAssertEqual(window(90).title, "1.5 hour")
        XCTAssertEqual(window(2880).title, "2 day")
        XCTAssertEqual(window(nil).title, "Limit")
        XCTAssertEqual(window(0).title, "Limit")
    }

    /// the owner's real file: primary is the weekly window and secondary is null.
    func testARealSnapshotIsTitledWeekly() throws {
        let json = #"{"updated":"2026-09-04T08:35:05Z","limit_name":null,"plan_type":"pro","primary":{"used_percent":1.0,"window_minutes":10080,"resets_at":1789112122},"secondary":null}"#
        let snapshot = try XCTUnwrap(CodexUsageSnapshot.parse(Data(json.utf8)))
        XCTAssertEqual(snapshot.primary?.title, "Weekly")
        XCTAssertNil(snapshot.secondary)
        XCTAssertEqual(UsageView.codexCardCount(snapshot), 1)
    }
}
