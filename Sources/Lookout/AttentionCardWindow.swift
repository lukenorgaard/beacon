import AppKit
import Combine
import SwiftUI

/// Where the card sits relative to the panel (SPEC §11.4). Pure geometry, so both edges and the
/// screen-edge case are testable without a window.
enum CardDock {
    enum Side: String, Equatable {
        case right
        case left
    }

    struct Placement: Equatable {
        var origin: NSPoint
        var side: Side
    }

    /// Where the panel sits when it is not on screen: its own default corner (SPEC §5.1), so a
    /// card in menu bar mode is not stranded in a corner of its own. The width is passed in —
    /// the panel's is a setting now (SPEC §14).
    static func defaultAnchor(in screen: NSRect, width: CGFloat = Theme.Metrics.standard.width) -> NSRect {
        NSRect(
            x: screen.maxX - width - 16,
            y: screen.maxY - 320 - 16,
            width: width,
            height: 320
        )
    }

    /// Docked to the panel's right edge with an 8 pt gap; the left edge instead when the right
    /// one would put the card off the screen.
    static func place(
        panel: NSRect,
        size: NSSize,
        screen: NSRect,
        gap: CGFloat = Theme.Metrics.standard.dockGap
    ) -> Placement {
        let rightX = panel.maxX + gap
        let leftX = panel.minX - gap - size.width
        let fitsRight = rightX + size.width <= screen.maxX
        let fitsLeft = leftX >= screen.minX

        let side: Side = fitsRight ? .right : (fitsLeft ? .left : .right)
        var x = side == .right ? rightX : leftX

        // A screen too narrow for either side still gets a card that is fully on it.
        let maxX = max(screen.minX, screen.maxX - size.width)
        x = min(max(x, screen.minX), maxX)

        // Top-aligned with the panel; a card taller than the space below it slides up.
        var y = panel.maxY - size.height
        let maxY = max(screen.minY, screen.maxY - size.height)
        y = min(max(y, screen.minY), maxY)

        return Placement(origin: NSPoint(x: x, y: y), side: side)
    }
}

/// Non-activating like the panel, on every Space like the panel — but unlike the panel it *can*
/// become key, which is what makes typing in a field work without pulling focus away from the
/// session the owner is looking at (SPEC §11.4).
///
/// The attention card was the first window to need this; SPEC §15.4's rename panel needs exactly
/// the same trick, so the style lives here once and both inherit it.
class NonActivatingKeyPanel: NSPanel {
    /// Escape.
    var onCancel: () -> Void = {}

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // A card that pops up while the owner is typing elsewhere must not swallow his keystrokes:
        // it becomes key only when he clicks into the reply field (2026-09-03).
        becomesKeyOnlyIfNeeded = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
        appearance = NSAppearance(named: .darkAqua)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }
}

/// The card's own window (SPEC §11.4). Escape = Ignore.
final class AttentionCardWindow: NonActivatingKeyPanel {}

/// Owns the card window: one card at a time, docked to the panel, following it when it moves or
/// resizes, closing itself when the coordinator's queue says the card is over (SPEC §11.4).
final class AttentionCardController {
    private let state: AppState
    private let settings: Settings
    private let model: AttentionCardModel
    private let anchor: () -> NSWindow?

    private var window: AttentionCardWindow?
    private var hosting: NSHostingView<AttentionCardView>?
    private var cancellables = Set<AnyCancellable>()
    private var resizeScheduled = false

    /// The same value the card's SwiftUI tree lays itself out with (SPEC §14).
    private var metrics: Theme.Metrics { settings.metrics }

    /// SPEC §15.4: the rename panel docks below the row instead of beside the panel when the
    /// card already has that side.
    var isVisible: Bool { window?.isVisible ?? false }

    init(state: AppState, settings: Settings, anchor: @escaping () -> NSWindow?) {
        self.state = state
        self.settings = settings
        self.model = state.cardModel
        self.anchor = anchor
    }

    func start() {
        // Cards lane, 2026-09-04: the only production driver of a `done` card's own 30-minute
        // TTL — see `AttentionCardModel.tick`. Started once, here, so no test process (which
        // never calls `AttentionCardController.start()`) pays for a live timer.
        model.start()

        state.attention.$queue
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)

        state.requests.$requests
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)

        // Bug fix 2026-09-04: a Codex question can change (a new question replaces the old one
        // within the same call, or a later question in the same call gets its own answer) without
        // the session's own `detail`/`reason` moving — `state.attention.$queue` would not
        // otherwise notice, and the card would keep showing the stale question text/options.
        state.codexQuestions.$questions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)

        // The card is docked, so it follows every move and every resize of the panel.
        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didResizeNotification))
            .compactMap { $0.object as? NSWindow }
            .sink { [weak self] moved in
                guard let self, moved === self.anchor() else { return }
                self.reposition()
            }
            .store(in: &cancellables)

        model.objectWillChange
            .sink { [weak self] _ in self?.scheduleResize() }
            .store(in: &cancellables)

        // SPEC §14: the card follows the panel's width and the text size, live. `scheduleResize`
        // already defers to the next main-queue turn, which is also what makes it read the
        // appearance `@Published` has only just announced.
        settings.$appearance
            .sink { [weak self] _ in self?.scheduleResize() }
            .store(in: &cancellables)

        sync()
    }

    // MARK: - SPEC §17.2's ⌃⌥R

    /// Focuses the reply field, opening the card for the top `needs_you` session first if none
    /// is showing. Unlike every other time the card appears, this forces it key: a global
    /// shortcut asking for the field *is* the click that would normally have done that.
    func focusReplyField() {
        guard isVisible else {
            guard let session = state.topNeedsYouSession else { return }
            state.attention.present(session)
            // The queue publishes on the next run loop turn; the window has to exist before it
            // can be forced key.
            DispatchQueue.main.async { [weak self] in self?.forceFocus() }
            return
        }
        forceFocus()
    }

    private func forceFocus() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        model.requestFocus()
    }

    // MARK: - Presenting

    private func sync() {
        let item = state.attention.current
        // Bug fix 2026-09-04: the session record decides, not "newest file for this id" — see
        // `RequestStore.request(for session:)`. A `needs_you` card whose `request_id` clears or
        // changes, or whose request simply ages out, drops the request part on the very next
        // sync (both `state.attention.$queue` and `state.requests.$requests` trigger this), and
        // `AttentionCardModel.present` never clears a reply being typed for the same card. A real,
        // hook-driven request always wins — the in-memory Codex question `codexQuestionRequest`
        // builds is only ever reached for once this comes back nil (bug fix 2026-09-04, item 3).
        let request = item.flatMap { state.requests.request(for: $0.session) }
            ?? item.flatMap { state.codexQuestionRequest(for: $0.session) }
        model.present(item, request: request)
        model.pendingCount = state.attention.pendingCount

        guard item != nil else {
            hide()
            return
        }
        show()
    }

    private func show() {
        let panel = makeWindowIfNeeded()
        resize()
        reposition()
        // Shown without taking key focus: the session the owner is typing in keeps the keyboard.
        // Clicking the reply field makes the panel key (becomesKeyOnlyIfNeeded), still without
        // activating Lookout (SPEC §11.4).
        panel.orderFrontRegardless()
        Jumper.diag("card show: frame=\(Int(panel.frame.origin.x)),\(Int(panel.frame.origin.y)) \(Int(panel.frame.width))x\(Int(panel.frame.height)) visible=\(panel.isVisible ? 1 : 0) fitting=\(Int(hosting?.fittingSize.height ?? -1))")
    }

    private func hide() {
        window?.orderOut(nil)
    }

    private func makeWindowIfNeeded() -> AttentionCardWindow {
        if let window { return window }

        let hostingView = NSHostingView(rootView: AttentionCardView(model: model))
        hostingView.appearance = NSAppearance(named: .darkAqua)

        let created = AttentionCardWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: metrics.cardWidth, height: metrics.cardMaxHeight
            )
        )
        created.contentView = hostingView
        created.onCancel = { [weak self] in self?.model.ignore() }

        window = created
        hosting = hostingView
        return created
    }

    // MARK: - Geometry

    private func scheduleResize() {
        guard !resizeScheduled, window?.isVisible == true else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            self.resize()
            self.reposition()
        }
    }

    /// The card's height comes from the laid-out content — a six-line command and a one-line
    /// question do not deserve the same window — capped so it can never run off the screen.
    private func resize() {
        guard let window, let hosting else { return }
        let width = metrics.cardWidth
        // A width change has to reach the hosting view before its fitting height is asked for,
        // or the card would be measured at the width it *had*.
        if abs(hosting.frame.width - width) > 0.5 {
            hosting.setFrameSize(NSSize(width: width, height: hosting.frame.height))
        }
        hosting.layoutSubtreeIfNeeded()
        let wanted = hosting.fittingSize.height
        let height = min(max(wanted, metrics.cardMinHeight), metrics.cardMaxHeight)
        guard abs(window.frame.height - height) > 0.5 || abs(window.frame.width - width) > 0.5
        else { return }
        window.setContentSize(NSSize(width: width, height: height))
    }

    private func reposition() {
        guard let window else { return }
        let panel = anchor()
        let visible = (panel?.screen ?? window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // In menu bar mode there may be no panel on screen to dock to; the card then takes the
        // place the panel would have had, so it still lands where the eye expects it.
        let fallback = CardDock.defaultAnchor(in: visible, width: metrics.width)
        let anchorFrame = panel.map { $0.isVisible ? $0.frame : fallback } ?? fallback
        let placement = CardDock.place(
            panel: anchorFrame, size: window.frame.size, screen: visible, gap: metrics.dockGap
        )
        window.setFrameOrigin(placement.origin)
    }
}
