import AppKit
import XCTest
@testable import Lookout

/// Numbers taken off a live machine on 2026-09-02: a 3024 x 1964 Retina MacBook display, so
/// 1512 pt wide, menu bar full. The app's status item reported x 827 width 31, and the first
/// clickable item to the right of the notch began at 911 — the item was behind the notch, drawn
/// nowhere and clickable nowhere, while still reporting a perfectly ordinary frame.
final class MenuBarReachabilityTests: XCTestCase {

    private let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
    /// The menu bar either side of the notch: app menus on the left, status items on the right.
    private let leftArea = NSRect(x: 0, y: 944, width: 671, height: 38)
    private let rightArea = NSRect(x: 841, y: 944, width: 671, height: 38)

    private func reachable(_ item: NSRect) -> Bool {
        MenuBarReachability.isReachable(
            item: item, leftArea: leftArea, rightArea: rightArea, screen: screen
        )
    }

    func testAnItemBehindTheNotchIsNotReachable() {
        // The measured frame, and the wider one it had before the status text was shortened.
        XCTAssertFalse(reachable(NSRect(x: 827, y: 948, width: 31, height: 24)))
        XCTAssertFalse(reachable(NSRect(x: 756, y: 948, width: 102, height: 24)))
    }

    func testAnItemClearOfTheNotchIsReachable() {
        XCTAssertTrue(reachable(NSRect(x: 911, y: 948, width: 31, height: 24)))
        XCTAssertTrue(reachable(NSRect(x: 1400, y: 948, width: 60, height: 24)))
    }

    /// Half-hidden is no better than hidden: the user still cannot aim at it.
    func testAnItemStraddlingTheNotchEdgeIsNotReachable() {
        XCTAssertFalse(reachable(NSRect(x: 820, y: 948, width: 40, height: 24)))
    }

    /// A screen without a notch reports no auxiliary areas, and then anything on it counts.
    func testWithoutANotchAnythingOnScreenIsReachable() {
        XCTAssertTrue(MenuBarReachability.isReachable(
            item: NSRect(x: 756, y: 1400, width: 102, height: 24),
            leftArea: nil, rightArea: nil,
            screen: NSRect(x: 0, y: 0, width: 5120, height: 1440)
        ))
    }

    /// A zero-width button is the other way the item goes missing.
    func testACollapsedItemIsNotReachable() {
        XCTAssertFalse(reachable(NSRect(x: 1400, y: 948, width: 0, height: 24)))
    }
}
