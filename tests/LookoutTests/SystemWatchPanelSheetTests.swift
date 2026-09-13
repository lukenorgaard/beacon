import AppKit
import XCTest
@testable import Lookout

/// SPEC §18.4: the Stop… confirmation is a sheet on the panel, and the panel has to survive it.
///
/// The transient (menu-bar) panel hides the moment it resigns key — that is what makes
/// click-outside close it. Attaching a sheet resigns key too, so the confirmation used to take
/// its own parent off screen: the alert stood over nothing, and the inline failure it produced
/// landed on a row that was no longer visible. `PanelController` now asks whether the resign came
/// from its own sheet before hiding.
final class SystemWatchPanelSheetTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    /// The decision itself, as a table — it is a two-input rule and both inputs matter.
    func testOnlyATransientPanelWithNoSheetOnItHidesWhenItResignsKey() {
        XCTAssertTrue(
            PanelController.shouldHideOnResignKey(isTransient: true, isPresentingSheet: false),
            "click-outside still closes the menu-bar panel"
        )
        XCTAssertFalse(
            PanelController.shouldHideOnResignKey(isTransient: true, isPresentingSheet: true),
            "a sheet is the panel being used, not the panel being dismissed"
        )
        XCTAssertFalse(
            PanelController.shouldHideOnResignKey(isTransient: false, isPresentingSheet: false),
            "the pinned panel never hides on resign"
        )
        XCTAssertFalse(
            PanelController.shouldHideOnResignKey(isTransient: false, isPresentingSheet: true)
        )
    }

    /// And the seam the decision reads, against a real window with a real sheet on it — the part
    /// a table of booleans cannot vouch for.
    func testARealAttachedSheetIsWhatTheDecisionSees() {
        let panel = PanelWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240))
        panel.keyable = true
        XCTAssertFalse(panel.isPresentingSheet, "nothing is attached to a fresh panel")

        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        panel.beginSheet(sheet) { _ in }
        defer { panel.endSheet(sheet) }

        XCTAssertTrue(panel.isPresentingSheet, "the panel knows the confirmation is up")
        XCTAssertFalse(
            PanelController.shouldHideOnResignKey(
                isTransient: true, isPresentingSheet: panel.isPresentingSheet
            ),
            "the resign the sheet itself caused must not hide the panel under it"
        )
    }

    func testThePanelIsBackToHidingOnceTheSheetGoesAway() {
        let panel = PanelWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240))
        panel.keyable = true
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        panel.beginSheet(sheet) { _ in }
        panel.endSheet(sheet)

        XCTAssertFalse(panel.isPresentingSheet)
        XCTAssertTrue(
            PanelController.shouldHideOnResignKey(
                isTransient: true, isPresentingSheet: panel.isPresentingSheet
            )
        )
    }
}
