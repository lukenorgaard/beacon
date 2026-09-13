import AppKit
import SwiftUI
import XCTest
@testable import Lookout

/// Reproduces the real `SettingsWindowController.show()` path headlessly, by calling the exact
/// window-building code `show()` calls (`SettingsWindowController.makeWindow()`) without the
/// final `makeKeyAndOrderFront` — as opposed to `PanelRenderTests`, which measures `SettingsView`
/// through a bare `NSHostingView`. The two paths size very differently, which is exactly the bug
/// this test exists to catch: the live window was reported to render only its title bar and tab
/// picker, with no form below.
final class SettingsWindowTests: XCTestCase {
    private var suiteName = ""
    private var settings: Lookout.Settings!
    private var state: AppState!
    private var hotKeys: HotKeyCenter { HotKeyCenter(settings: settings) }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        suiteName = "io.github.lukenorgaard.beacon.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        settings = Lookout.Settings(defaults: defaults)
        // `state.home` becomes `SettingsWindowController.makeWindow()`'s `SettingsView.home` —
        // `Fixtures.home` rather than the real `~/.lookout`, same as `PanelRenderTests`. Nothing
        // here sets `suggestionSource = .claude`, so the one section that writes through `home`
        // (SPEC §13.2) never mounts and nothing is written to it.
        state = AppState(
            settings: settings,
            store: SessionStore(home: Fixtures.home),
            usage: UsageClient(),
            home: LookoutHome(root: Fixtures.home)
        )
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        state = nil
        settings = nil
        super.tearDown()
    }

    /// A fresh controller per tab — `makeWindow()` only ever runs once per controller, exactly
    /// like `show()` expects.
    private func makeWindow(tab: SettingsTab) -> NSWindow {
        settings.settingsTab = tab
        let controller = SettingsWindowController(
            settings: settings, usage: state.usage, state: state, hotKeys: hotKeys
        )
        let window = controller.makeWindow()
        window.layoutIfNeeded()
        return window
    }

    /// SPEC §15.2: whichever tab the window opens on, it must show the tab's form, not just its
    /// title bar and picker (roughly 50 pt — the regression this test was written to catch).
    func testSettingsWindowShowsFormContentForEveryTab() {
        for tab in SettingsTab.allCases {
            let window = makeWindow(tab: tab)
            let height = window.contentView?.frame.height ?? 0
            XCTAssertGreaterThan(
                height, 200,
                "\(tab.rawValue): the real window path must lay out the form, not just the " +
                    "title bar and tab picker (got \(height) pt)"
            )
            XCTAssertLessThanOrEqual(
                height, SettingsView.maxContentHeight, "\(tab.rawValue): capped at 600 pt"
            )
            XCTAssertEqual(
                window.contentView?.frame.width ?? 0, SettingsView.formWidth, accuracy: 1,
                tab.rawValue
            )
        }
    }
}
