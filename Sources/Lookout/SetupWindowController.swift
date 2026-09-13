import AppKit
import ApplicationServices
import SwiftUI
import UserNotifications

/// The setup window: opened automatically on a machine with no hooks, and on demand from the
/// status-item menu or Settings (SPEC §10.2).
final class SetupWindowController: NSObject, NSWindowDelegate {
    var window: NSWindow?
    let installer: HookInstaller
    let companion = CompanionInstaller()
    let settings: Settings

    init(installer: HookInstaller, settings: Settings) {
        self.installer = installer
        self.settings = settings
    }

    func show() {
        installer.refresh()
        companion.refresh()

        if let window {
            bringForward(window)
            return
        }

        let hosting = NSHostingController(
            rootView: SetupView(
                installer: installer,
                companion: companion,
                settings: settings,
                onDone: { [weak self] in self?.close() }
            )
        )
        let created = NSWindow(contentViewController: hosting)
        created.title = "Beacon Setup"
        created.styleMask = [.titled, .closable]
        created.isReleasedWhenClosed = false
        created.appearance = NSAppearance(named: .darkAqua)
        created.delegate = self
        created.center()
        window = created
        bringForward(created)
    }

    func close() {
        window?.performClose(nil)
    }

    private func bringForward(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        settings.setupSeen = true
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}
