import AppKit
import Combine

/// The menu bar item: a coloured dot plus optional text (SPEC §5.1). Left-click shows the panel,
/// right-click opens the menu.
final class StatusItemController: NSObject {
    private let state: AppState
    private let settings: Settings
    private let panel: PanelController
    private let settingsWindow: SettingsWindowController
    private let setupWindow: SetupWindowController
    private let installer: HookInstaller
    /// SPEC §11.4: the card docks to the panel, so it is built here where the panel lives.
    private var card: AttentionCardController!
    /// SPEC §15.4: so does the rename panel — and it has to know whether the card is out.
    private var rename: RenameController!
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()

    init(state: AppState, settings: Settings, installer: HookInstaller = HookInstaller()) {
        self.state = state
        self.settings = settings
        self.installer = installer
        self.panel = PanelController(state: state, settings: settings)
        self.settingsWindow = SettingsWindowController(
            settings: settings, usage: state.usage, state: state, hotKeys: state.hotKeys
        )
        self.setupWindow = SetupWindowController(installer: installer, settings: settings)
        super.init()
        self.card = AttentionCardController(state: state, settings: settings) { [weak self] in
            self?.panel.anchorWindow
        }
        self.rename = RenameController(
            state: state,
            settings: settings,
            anchor: { [weak self] in self?.panel.anchorWindow },
            cardVisible: { [weak self] in self?.card.isVisible ?? false }
        )
    }

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        panel.onTogglePin = { [weak self] in self?.togglePin() }
        panel.onOpenSettings = { [weak self] in self?.openSettings() }
        settingsWindow.onOpenSetup = { [weak self] in self?.openSetup() }

        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateStatusItem() }
            }
            .store(in: &cancellables)

        state.usage.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateStatusItem() }
            }
            .store(in: &cancellables)

        settings.$statusText
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateStatusItem() }
            }
            .store(in: &cancellables)

        // SPEC §18.5: a critical system signal colours the dot (and names itself in the
        // tooltip), so the status item has to follow the watcher the same way it follows usage.
        state.systemWatch.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateStatusItem() }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(settings.$sentinelEnabled, settings.$sentinelMenuBarDot)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                DispatchQueue.main.async { self?.updateStatusItem() }
            }
            .store(in: &cancellables)

        settings.$mode
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.panel.apply(mode: mode, button: self.statusItem.button)
                }
            }
            .store(in: &cancellables)

        updateStatusItem()
        if settings.mode == .pinned { panel.showPinned() }
        card.start()
        rename.start()

        // SPEC §17.2: the five global shortcuts. `perform` is set before `start()` registers
        // anything, so a press that lands the instant registration succeeds is never dropped.
        state.hotKeys.perform = { [weak self] action in self?.performHotKey(action) }
        state.hotKeys.start()
    }

    /// SPEC §17.2's five actions.
    private func performHotKey(_ action: HotKeyAction) {
        switch action {
        case .togglePanel:
            panel.toggle(mode: settings.mode, button: statusItem?.button)
        case .jumpLongestWaiting:
            guard let session = state.longestWaitingSession else { return }
            state.jump(to: session)
        case .focusReply:
            card.focusReplyField()
        case .allow:
            state.cardModel.answer(.allow)
        case .deny:
            state.cardModel.answer(.deny)
        }
    }

    /// SPEC §10.2: on a machine whose hooks are missing (or point at another copy of Lookout the
    /// first time we notice), the setup window opens itself. The probe is filesystem work, so it
    /// runs off the main thread and only the decision comes back here.
    func presentSetupIfNeeded() {
        installer.refresh { [weak self] in
            guard let self, self.installer.shouldPresentSetup(setupSeen: self.settings.setupSeen)
            else { return }
            self.openSetup()
        }
    }

    /// Called when a notification is clicked — bring the panel forward too, so the user can see
    /// what else is waiting.
    /// Called when a notification is clicked, and when the app is reopened from Spotlight or
    /// Finder. This is the way back in when the menu bar icon cannot be reached, so it must work
    /// in *both* modes — it used to do nothing at all in menu-bar mode, which is exactly the
    /// state a user gets stranded in.
    func revealPanel() {
        switch settings.mode {
        case .pinned: panel.showPinned()
        case .menuBar: panel.showTransient(below: statusItem?.button)
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        let title = NSMutableAttributedString(
            string: "\u{25CF}",
            attributes: [
                .foregroundColor: state.statusColor,
                .font: NSFont.systemFont(ofSize: 9),
            ]
        )
        let text = state.statusTitle
        if !text.isEmpty {
            title.append(NSAttributedString(
                string: " " + text,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                ]
            ))
        }
        button.attributedTitle = title
        button.toolTip = state.statusTooltip
    }

    @objc private func statusItemClicked() {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true

        if isRightClick {
            showMenu()
        } else {
            panel.toggle(mode: settings.mode, button: statusItem.button)
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        let pin = NSMenuItem(
            title: settings.mode == .pinned ? "Unpin panel" : "Pin panel on every Space",
            action: #selector(togglePin), keyEquivalent: ""
        )
        pin.target = self
        menu.addItem(pin)

        let seen = NSMenuItem(
            title: "Mark finished sessions as seen", action: #selector(markSeen), keyEquivalent: ""
        )
        seen.target = self
        menu.addItem(seen)

        let refresh = NSMenuItem(
            title: "Refresh usage", action: #selector(refreshUsage), keyEquivalent: ""
        )
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())

        let preferences = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ","
        )
        preferences.target = self
        menu.addItem(preferences)

        let setup = NSMenuItem(title: "Setup…", action: #selector(openSetup), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Beacon",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        // Attaching the menu makes the NEXT click open it too, so show it once and detach.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func togglePin() {
        if settings.mode == .pinned, !MenuBarReachability.isReachable(button: statusItem?.button) {
            confirmUnpinWithHiddenStatusItem()
            return
        }
        settings.mode = settings.mode == .pinned ? .menuBar : .pinned
    }

    /// Unpinning hides the panel and leaves the status item as the only way back. When macOS has
    /// parked that item behind the notch, "unpin" is a one-way door, so the user is told before
    /// they walk through it rather than after.
    private func confirmUnpinWithHiddenStatusItem() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Beacon's menu bar icon is hidden"
        alert.informativeText =
            "The menu bar is full, so macOS has parked Beacon's icon behind the notch, "
            + "where it cannot be clicked. Unpinning hides the panel, and that icon is the "
            + "usual way to open it again.\n\n"
            + "Free up a menu bar slot to get the icon back. Either way, opening Beacon from "
            + "Spotlight always brings the panel back."
        alert.addButton(withTitle: "Keep pinned")
        alert.addButton(withTitle: "Unpin anyway")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            settings.mode = .menuBar
        }
    }

    @objc private func markSeen() {
        state.markAllDoneSeen()
    }

    @objc private func refreshUsage() {
        state.usage.refresh()
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    @objc private func openSetup() {
        setupWindow.show()
    }
}
