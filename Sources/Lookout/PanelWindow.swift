import AppKit
import Combine
import SwiftUI

/// The floating panel itself. Non-activating and on every Space while pinned, so it never takes
/// the keyboard away from the session the owner is typing in (SPEC §5.1).
final class PanelWindow: NSPanel {
    /// Only the transient (menu bar) presentation may take key focus — that is what makes
    /// Esc and click-outside work without asking for input-monitoring permission.
    var keyable = false

    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }

    /// SPEC §18.4: true while a sheet — the Sentinel tab's Stop… confirmation — is up on this
    /// panel. Attaching a sheet makes the sheet key, which makes the panel resign key, which is
    /// the transient panel's cue to hide: the confirmation would take the panel it is attached to
    /// off screen with it. `PanelController` asks this before hiding.
    ///
    /// Its own property rather than `attachedSheet != nil` at the call site so a test can stand a
    /// panel up and drive the decision without an application to run a sheet in.
    var isPresentingSheet: Bool { attachedSheet != nil }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
        appearance = NSAppearance(named: .darkAqua)
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

/// Owns the panel window: sizing, placement, persistence, and the two presentation modes.
final class PanelController {
    private let state: AppState
    private let settings: Settings
    private var window: PanelWindow?
    private var hosting: NSHostingView<PanelView>?
    /// SPEC §17.3: the filter row can wrap to a second line depending on width and how many
    /// chips carry two-digit counts — measured for real, the same way `AttentionCardController`
    /// measures the card, rather than guessed at from a formula. Type-erased because the
    /// measured view is `PanelView.filterRow`'s own padded content, not the bare row.
    private var filterRowHosting: NSHostingView<AnyView>?
    private var cancellables = Set<AnyCancellable>()
    private var escapeMonitor: Any?
    private var isTransient = false
    /// Clicking the status item first makes the transient panel resign key (which hides it);
    /// without this, the same click would immediately open it again.
    private var hiddenAt: Date?

    var onTogglePin: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    /// The same value the panel's SwiftUI tree lays itself out with (SPEC §14) — the window is
    /// sized from the model, so both sides have to read the one appearance.
    private var metrics: Theme.Metrics { settings.metrics }

    init(state: AppState, settings: Settings) {
        self.state = state
        self.settings = settings
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// The window the attention card docks to (SPEC §11.4). Nil until the panel is built.
    var anchorWindow: NSWindow? { window }

    // MARK: - Building

    private func makeWindowIfNeeded() -> PanelWindow {
        if let window { return window }

        let root = PanelView(
            state: state,
            settings: settings,
            onTogglePin: { [weak self] in self?.onTogglePin() },
            onOpenSettings: { [weak self] in self?.onOpenSettings() }
        )
        let hostingView = NSHostingView(rootView: root)
        hostingView.appearance = NSAppearance(named: .darkAqua)

        let size = NSSize(width: metrics.width, height: contentHeight())
        let panel = PanelWindow(contentRect: NSRect(origin: .zero, size: size))
        panel.contentView = hostingView
        panel.setContentSize(size)

        window = panel
        hosting = hostingView
        observe()
        return panel
    }

    /// Resize from the model, never from SwiftUI's own idea of its height — a long list must
    /// not be able to make the window taller than the list cap.
    private func contentHeight() -> CGFloat {
        let snapshot = state.usage.snapshot
        let cards = snapshot?.visibleLimits(hidden: settings.hiddenUsageModels).count ?? 0
        let extraLine = snapshot?.extraUsageEnabled ?? false
        let codexCards = UsageView.codexCardCount(state.codexUsage)
        let sessionsToday = UsageView.pricedSessionsToday(state: state, settings: settings).count
        // SPEC §18.3: the Sentinel tab's height is its gauges plus a capped list, and the list's
        // rows are not all the same height — a warning that carries both an action and a Jump is
        // taller. The counts, not the signals, are what the metrics need.
        let signals = Sentinel.sorted(state.systemWatch.signals)
        return metrics.totalHeight(
            tab: state.tab,
            rows: state.visibleSessions.count,
            cards: cards,
            extraLine: extraLine,
            agents: state.subagents.count,
            historyRows: state.historyRowCount,
            historyGroups: state.historyGroups.count,
            codexCards: codexCards,
            sessionsToday: min(sessionsToday, 5),
            sentinelRows: Sentinel.layouts(signals, metrics: metrics),
            sentinelApps: Sentinel.topApps(state.systemWatch.snapshot).count,
            sentinelThermalChip: Sentinel.thermalChip(state.systemWatch.snapshot) != nil,
            sentinelError: state.systemWatch.lastError != nil,
            // SPEC §18.3: with History and Sentinel both on, the strip can need a second line.
            tabRows: PanelView.tabRows(state: state, settings: settings)
        ) + filterRowHeight()
    }

    /// SPEC §17.3: the row's real height at the panel's width, including whatever it wraps to.
    /// Zero outside the sessions tab, where the row does not exist at all. The measured view is
    /// byte-for-byte `PanelView.filterRow`'s content (same padding, same explicit width), so
    /// this can never quietly drift from what actually gets embedded.
    private func filterRowHeight() -> CGFloat {
        guard state.tab == .sessions else { return 0 }

        let content = AnyView(
            SessionFilterRow(state: state, settings: settings)
                .padding(.horizontal, metrics.padding)
                .padding(.top, metrics.scaled(2))
                .padding(.bottom, metrics.scaled(6))
                .frame(width: metrics.width)
        )
        let hostingView: NSHostingView<AnyView>
        if let existing = filterRowHosting {
            hostingView = existing
            hostingView.rootView = content
        } else {
            hostingView = NSHostingView(rootView: content)
            filterRowHosting = hostingView
        }
        hostingView.layoutSubtreeIfNeeded()
        // A row measured in its own hosting view and the same row measured as one child among
        // several in the panel's own `VStack` do not always agree to the pixel — SwiftUI's
        // fitting-size negotiation is not strictly additive across sibling views. The margin
        // below is what keeps that slack from ever under-sizing the real window; it only ever
        // adds a little empty air at the bottom, which `Spacer(minLength: 0)` already expects.
        return hostingView.fittingSize.height + PanelController.filterRowMeasurementMargin
    }

    /// See `filterRowHeight()`. Not scaled with the appearance: the worst drift measured across
    /// SPEC §14's whole range was well under this at every step.
    static let filterRowMeasurementMargin: CGFloat = 24

    private func observe() {
        state.$visibleSessions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resize() }
            .store(in: &cancellables)

        state.$subagents
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resize() }
            .store(in: &cancellables)

        state.$tab
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.resize() }
            }
            .store(in: &cancellables)

        state.usage.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resize() }
            .store(in: &cancellables)

        // SPEC §17.5: the History tab's own filtered/grouped rows.
        state.$historyGroups
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resize() }
            .store(in: &cancellables)

        // SPEC §17.7: the Codex usage section appears/disappears with the file on disk.
        state.$codexUsage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resize() }
            .store(in: &cancellables)

        // SPEC §17.5/§18.3: either switch changes how many tabs are on the strip, and with them
        // whether it needs a second line — which is part of the window's height.
        Publishers.CombineLatest(settings.$showHistoryTab, settings.$sentinelEnabled)
            .sink { [weak self] _, _ in
                DispatchQueue.main.async { self?.resize() }
            }
            .store(in: &cancellables)

        // SPEC §18.3: a warning appearing or clearing changes the tab's height. `objectWillChange`
        // fires before the value lands, so the resize takes the next main-queue hop — the same
        // ordering `settings.$appearance` below needs.
        state.systemWatch.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.resize() }
            }
            .store(in: &cancellables)

        // SPEC §14: a drag on the edge, a stepper in Settings and a preset all land here — the
        // window follows the appearance live, and the card follows the window.
        //
        // `@Published` fires *before* the property is updated, so the resize has to happen one
        // main-queue hop later or it would size the window from the appearance it just left.
        // The main queue and not `RunLoop.main`: a resize drag is delivered while the run loop
        // is tracking events, and a default-mode scheduler would hold every frame back until
        // the mouse came up.
        settings.$appearance
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.resize() }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification)
            .compactMap { $0.object as? PanelWindow }
            .sink { [weak self] moved in
                guard let self, moved === self.window, !self.isTransient else { return }
                self.settings.panelOrigin = moved.frame.origin
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)
            .compactMap { $0.object as? PanelWindow }
            .sink { [weak self] resigned in
                guard let self, resigned === self.window else { return }
                guard PanelController.shouldHideOnResignKey(
                    isTransient: self.isTransient, isPresentingSheet: resigned.isPresentingSheet
                ) else { return }
                self.hide()
            }
            .store(in: &cancellables)
    }

    /// The transient panel hides when it loses key focus — that is what makes click-outside work.
    /// But attaching a sheet to it also makes it lose key focus, and hiding then takes the sheet's
    /// own parent off screen: the Stop… confirmation (SPEC §18.4) appeared over nothing, and the
    /// inline failure it produced landed on a row that was no longer visible. A sheet is the panel
    /// still being used, not the panel being dismissed.
    static func shouldHideOnResignKey(isTransient: Bool, isPresentingSheet: Bool) -> Bool {
        isTransient && !isPresentingSheet
    }

    /// Keeps the top edge where it is while the height changes — a list that grows downwards
    /// reads as calm; one that jumps upwards does not.
    private func resize() {
        guard let window, window.isVisible else { return }
        let size = NSSize(width: metrics.width, height: contentHeight())
        guard abs(window.frame.height - size.height) > 0.5
            || abs(window.frame.width - size.width) > 0.5
        else { return }

        let top = window.frame.maxY
        var frame = window.frame
        frame.size = size
        frame.origin.y = top - size.height
        window.setFrame(frame, display: true, animate: false)
    }

    // MARK: - Presentation

    /// Pinned: floating, non-activating, on every Space.
    func showPinned() {
        let panel = makeWindowIfNeeded()
        defer { state.setPanelOnScreen(true, window: panel) }
        isTransient = false
        panel.keyable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.setContentSize(NSSize(width: metrics.width, height: contentHeight()))
        panel.setFrameOrigin(restoredOrigin(for: panel))
        panel.orderFrontRegardless()
        removeEscapeMonitor()
    }

    /// Transient: hangs under the status item and closes on Esc or click-outside.
    func showTransient(below button: NSStatusBarButton?) {
        let panel = makeWindowIfNeeded()
        defer { state.setPanelOnScreen(true, window: panel) }
        isTransient = true
        panel.keyable = true
        panel.setContentSize(NSSize(width: metrics.width, height: contentHeight()))
        panel.setFrameOrigin(transientOrigin(below: button, height: panel.frame.height))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installEscapeMonitor()
    }

    func hide() {
        removeEscapeMonitor()
        if window?.isVisible == true { hiddenAt = Date() }
        window?.orderOut(nil)
        // SPEC §18.6: collapsed to the menu bar is not visible — the engine drops to its 15 s
        // cadence even though the Sentinel tab is still the selected one.
        state.setPanelOnScreen(false)
    }

    func toggle(mode: PanelMode, button: NSStatusBarButton?) {
        if isVisible {
            hide()
            return
        }
        if let hiddenAt, Date().timeIntervalSince(hiddenAt) < 0.25 { return }
        switch mode {
        case .pinned: showPinned()
        case .menuBar: showTransient(below: button)
        }
    }

    /// Re-present after the user flips the pin, so the panel lands in the right place.
    func apply(mode: PanelMode, button: NSStatusBarButton?) {
        switch mode {
        case .pinned:
            showPinned()
        case .menuBar:
            hide()
        }
    }

    // MARK: - Placement

    private func restoredOrigin(for panel: PanelWindow) -> NSPoint {
        let screen = panel.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height = panel.frame.height

        if let saved = settings.panelOrigin {
            return clamp(NSPoint(x: saved.x, y: saved.y), height: height, in: visible)
        }
        return NSPoint(
            x: visible.maxX - metrics.width - 16,
            y: visible.maxY - height - 16
        )
    }

    private func transientOrigin(below button: NSStatusBarButton?, height: CGFloat) -> NSPoint {
        guard let button, let buttonWindow = button.window else {
            let visible = NSScreen.main?.visibleFrame ?? .zero
            return NSPoint(x: visible.maxX - metrics.width - 16, y: visible.maxY - height - 16)
        }
        let onScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let point = NSPoint(
            x: onScreen.midX - metrics.width / 2,
            y: onScreen.minY - height - 6
        )
        return clamp(point, height: height, in: visible)
    }

    private func clamp(_ point: NSPoint, height: CGFloat, in visible: NSRect) -> NSPoint {
        var result = point
        result.x = min(max(result.x, visible.minX + 8), visible.maxX - metrics.width - 8)
        result.y = min(max(result.y, visible.minY + 8), visible.maxY - height - 8)
        return result
    }

    // MARK: - Esc

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.hide()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
}
