import AppKit
import Combine
import SwiftUI

/// SPEC §9.5: the five family colours in one static row, so the panel's tints can be read
/// without guessing. Every swatch keeps its label beside it — nothing overlaps, nothing wraps.
struct FamilyLegend: View {
    var body: some View {
        HStack(spacing: 9) {
            ForEach(SessionFamily.allCases, id: \.self) { family in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Theme.color(for: family))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
                        )
                        .frame(width: 10, height: 10)
                    Text(family.label)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Row colours: " + SessionFamily.allCases.map(\.label).joined(separator: ", ")
        )
    }
}

/// A single settings window, opened from the panel's gear or the status item menu.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// Set by the status-item controller, which owns the setup window too.
    var onOpenSetup: (() -> Void)?

    var window: NSWindow?
    /// Kept so a tab change can re-measure it — `NSHostingController`'s default sizing options
    /// (`.standardBounds`) drive `preferredContentSize` from the content's `intrinsicContentSize`,
    /// which a `ScrollView` never reports (it is designed to *fill* whatever space AppKit gives
    /// it, not to report one); left to that, the window collapses to a sliver and only the
    /// picker above the `ScrollView` shows. `.fittingSize` — the same call `AttentionCardWindow`
    /// already uses to size the attention card — measures the content directly instead.
    private var hosting: NSHostingController<SettingsView>?
    private var tabCancellable: AnyCancellable?
    private var resizeScheduled = false
    let settings: Settings
    let usage: UsageClient
    let state: AppState?
    let hotKeys: HotKeyCenter

    init(
        settings: Settings, usage: UsageClient, state: AppState? = nil,
        hotKeys: HotKeyCenter? = nil
    ) {
        self.settings = settings
        self.usage = usage
        self.state = state
        self.hotKeys = hotKeys ?? HotKeyCenter(settings: settings)
    }

    func show() {
        if let window {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let created = makeWindow()

        // A dock icon while settings are open, none when they are closed.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        created.makeKeyAndOrderFront(nil)
    }

    /// Everything `show()` does short of activating the app and ordering the window front — its
    /// own method so `SettingsWindowTests` can build and measure the exact window AppKit would
    /// show, headlessly (SPEC §15.2).
    func makeWindow() -> NSWindow {
        let hostingController = NSHostingController(
            rootView: SettingsView(
                settings: settings,
                usage: usage,
                hotKeys: hotKeys,
                onOpenSetup: { [weak self] in self?.onOpenSetup?() },
                ollamaModels: state?.suggester.models ?? [],
                sessions: state?.allSessions ?? [],
                home: state?.home ?? LookoutHome()
            )
        )
        let created = NSWindow(contentViewController: hostingController)
        created.title = "Beacon Settings"
        created.styleMask = [.titled, .closable]
        // SPEC §15.2: the window is 460 wide and never taller than 600, whichever tab is on —
        // the tab's own form scrolls when it needs more.
        created.contentMinSize = NSSize(width: SettingsView.formWidth, height: 200)
        created.contentMaxSize = NSSize(
            width: SettingsView.formWidth, height: SettingsView.maxContentHeight
        )
        created.isReleasedWhenClosed = false
        created.delegate = self
        created.center()
        window = created
        hosting = hostingController

        // The window opens at the current tab's natural height (see `hosting`'s doc comment for
        // why it is not left to `NSWindow(contentViewController:)`'s own sizing), and again
        // whenever the tab picker changes — `settings.settingsTab` is `@Published`, and every
        // segment picks a differently tall form (SPEC §15.2).
        resizeToFitContent()
        tabCancellable = settings.$settingsTab
            .sink { [weak self] _ in self?.scheduleResize() }

        return created
    }

    /// `settingsTab`'s change reaches `SettingsView.body` through SwiftUI's own invalidation,
    /// which lands on a later turn of the run loop — measuring `fittingSize` synchronously here
    /// would still see the *previous* tab's content. `AttentionCardWindow.scheduleResize()` hits
    /// the same ordering problem and fixes it the same way.
    private func scheduleResize() {
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            self.resizeToFitContent()
        }
    }

    private func resizeToFitContent() {
        guard let window, let hosting else { return }
        hosting.view.layoutSubtreeIfNeeded()
        let wanted = hosting.view.fittingSize.height
        guard wanted > 0 else { return }
        let height = min(max(wanted, 200), SettingsView.maxContentHeight)
        window.setContentSize(NSSize(width: SettingsView.formWidth, height: height))
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}
