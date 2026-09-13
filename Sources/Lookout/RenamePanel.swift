import AppKit
import Combine
import SwiftUI

/// Where SPEC §15.4's rename panel sits: next to the row it is about. Pure geometry, so the
/// screen-edge cases and the "card already has that side" case are testable without a window.
enum RenameDock {
    enum Side: String, Equatable {
        case right
        case left
        /// Under the row itself — what §15.4 asks for when the card is already docked beside
        /// the panel.
        case below
    }

    struct Placement: Equatable {
        var origin: NSPoint
        var side: Side
    }

    /// Beside the row when there is room (the card's own dock, but aligned with the row rather
    /// than the panel's top edge), under the row when the card is out.
    static func place(
        panel: NSRect,
        row: NSRect,
        size: NSSize,
        screen: NSRect,
        cardVisible: Bool,
        gap: CGFloat = Theme.Metrics.standard.dockGap
    ) -> Placement {
        var side: Side
        var x: CGFloat

        if cardVisible {
            side = .below
            x = panel.minX
        } else {
            let rightX = panel.maxX + gap
            let leftX = panel.minX - gap - size.width
            if rightX + size.width <= screen.maxX {
                side = .right
                x = rightX
            } else if leftX >= screen.minX {
                side = .left
                x = leftX
            } else {
                // Neither side fits: under the row is still fully on the screen.
                side = .below
                x = panel.minX
            }
        }

        var y: CGFloat
        switch side {
        case .below: y = row.minY - gap - size.height
        case .right, .left: y = row.maxY - size.height
        }

        let maxX = max(screen.minX, screen.maxX - size.width)
        x = min(max(x, screen.minX), maxX)
        let maxY = max(screen.minY, screen.maxY - size.height)
        y = min(max(y, screen.minY), maxY)

        return Placement(origin: NSPoint(x: x, y: y), side: side)
    }

    /// A row's frame as SwiftUI reports it (`.global`: origin top-left, y downwards) turned into
    /// screen coordinates. Pure, because the conversion is the part that is easy to get wrong.
    static func screenRect(row: CGRect, contentHeight: CGFloat, windowFrame: NSRect) -> NSRect {
        NSRect(
            x: windowFrame.minX + row.minX,
            y: windowFrame.minY + (contentHeight - row.maxY),
            width: row.width,
            height: row.height
        )
    }
}

/// The rename panel's window: the card's style exactly (SPEC §15.4), so it takes key focus
/// without activating the app and Escape cancels.
final class RenameWindow: NonActivatingKeyPanel {}

/// Owns the rename window. One at a time, opened by the row's context menu, closed by Save,
/// Cancel, Escape or the panel going away.
final class RenameController {
    private let state: AppState
    private let settings: Settings
    private let model: RenameModel
    private let anchor: () -> NSWindow?
    private let cardVisible: () -> Bool

    private var window: RenameWindow?
    private var hosting: NSHostingView<RenameView>?
    private var cancellables = Set<AnyCancellable>()
    /// The row the open panel is about, in screen coordinates.
    private var rowFrame: NSRect = .zero
    private var resizeScheduled = false

    private var metrics: Theme.Metrics { settings.metrics }

    init(
        state: AppState,
        settings: Settings,
        anchor: @escaping () -> NSWindow?,
        cardVisible: @escaping () -> Bool
    ) {
        self.state = state
        self.settings = settings
        self.model = state.renameModel
        self.anchor = anchor
        self.cardVisible = cardVisible
    }

    func start() {
        model.onClose = { [weak self] in self?.hide() }

        state.$renameTarget
            .receive(on: RunLoop.main)
            .sink { [weak self] target in self?.sync(target) }
            .store(in: &cancellables)

        model.objectWillChange
            .sink { [weak self] _ in self?.scheduleResize() }
            .store(in: &cancellables)

        settings.$appearance
            .sink { [weak self] _ in self?.scheduleResize() }
            .store(in: &cancellables)
    }

    // MARK: - Presenting

    private func sync(_ target: AppState.RenameTarget?) {
        guard let target else {
            hide()
            return
        }
        guard let panel = anchor() else { return }
        let content = panel.contentView?.bounds.height ?? panel.frame.height
        rowFrame = RenameDock.screenRect(
            row: target.rowFrame, contentHeight: content, windowFrame: panel.frame
        )
        model.begin(target.session)
        show()
    }

    private func show() {
        let panel = makeWindowIfNeeded()
        resize()
        reposition()
        panel.orderFrontRegardless()
        // Key without activating — the session the owner is looking at keeps its own focus
        // (SPEC §11.4's trick, §15.4's requirement).
        panel.makeKeyAndOrderFront(nil)
        // SPEC §15.4: the current name arrives selected, so typing replaces it.
        DispatchQueue.main.async { [weak panel] in
            (panel?.firstResponder as? NSTextView)?.selectAll(nil)
        }
    }

    private func hide() {
        window?.orderOut(nil)
        // The published target is what re-opens the panel; leaving it set would make the next
        // Rename… on the same row a no-op.
        state.endRename()
    }

    private func makeWindowIfNeeded() -> RenameWindow {
        if let window { return window }

        let hostingView = NSHostingView(rootView: RenameView(model: model))
        hostingView.appearance = NSAppearance(named: .darkAqua)

        let created = RenameWindow(
            contentRect: NSRect(x: 0, y: 0, width: metrics.renameWidth, height: 160)
        )
        created.contentView = hostingView
        created.onCancel = { [weak self] in self?.model.cancel() }

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

    /// The panel is exactly as tall as its content: a status line appears and it grows, a
    /// checkbox is hidden and it shrinks.
    private func resize() {
        guard let window, let hosting else { return }
        let width = metrics.renameWidth
        if abs(hosting.frame.width - width) > 0.5 {
            hosting.setFrameSize(NSSize(width: width, height: hosting.frame.height))
        }
        hosting.layoutSubtreeIfNeeded()
        let height = max(hosting.fittingSize.height, metrics.renameFieldHeight)
        guard abs(window.frame.height - height) > 0.5 || abs(window.frame.width - width) > 0.5
        else { return }
        // Keep the top edge where it is, so a growing status line pushes downwards.
        let top = window.frame.maxY
        var frame = window.frame
        frame.size = NSSize(width: width, height: height)
        frame.origin.y = top - height
        window.setFrame(frame, display: true, animate: false)
    }

    private func reposition() {
        guard let window else { return }
        let panel = anchor()
        let visible = (panel?.screen ?? window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let fallback = CardDock.defaultAnchor(in: visible, width: metrics.width)
        let anchorFrame = panel.map { $0.isVisible ? $0.frame : fallback } ?? fallback
        let row = rowFrame == .zero ? anchorFrame : rowFrame

        let placement = RenameDock.place(
            panel: anchorFrame,
            row: row,
            size: window.frame.size,
            screen: visible,
            cardVisible: cardVisible(),
            gap: metrics.dockGap
        )
        window.setFrameOrigin(placement.origin)
    }
}
