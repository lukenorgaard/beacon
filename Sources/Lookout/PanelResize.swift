import AppKit
import SwiftUI

/// SPEC §14: the panel's right edge (8 pt) and its bottom-right corner are drag zones.
///
/// An `NSView` and not a SwiftUI gesture, because only AppKit can put the resize cursor under
/// the pointer on a borderless, non-activating panel. The zones sit in the panel's own margins —
/// the right strip is exactly the list's inset and the corner square is exactly the strip of air
/// under the content — so neither can ever take a click meant for a row.
struct PanelResizeGrip: NSViewRepresentable {
    enum Zone {
        /// Width only.
        case edge
        /// Width and list height at once.
        case corner
    }

    let zone: Zone
    let settings: Settings

    func makeNSView(context: Context) -> GripView {
        let view = GripView()
        view.zone = zone
        view.settings = settings
        return view
    }

    func updateNSView(_ view: GripView, context: Context) {
        view.zone = zone
        view.settings = settings
    }

    /// Tracks the drag in *screen* points against the width the drag started from, so a resize
    /// that moves the window under the pointer cannot feed back into itself.
    final class GripView: NSView {
        var zone: Zone = .edge
        weak var settings: Settings?

        private var origin: NSPoint = .zero
        private var startWidth: CGFloat = 0
        private var startListHeight: CGFloat = 0
        private var dragging = false
        private var tracking: NSTrackingArea?

        // MARK: Cursor

        private var cursor: NSCursor {
            switch zone {
            case .edge:
                return .resizeLeftRight
            case .corner:
                if #available(macOS 15.0, *) {
                    return .frameResize(position: .bottomRight, directions: .all)
                }
                return .resizeLeftRight
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(
                rect: bounds,
                // `.activeAlways`: Lookout is not the active app while the owner types in his
                // terminal, and the panel still has to show the arrows.
                options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            tracking = area
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursor)
        }

        override func cursorUpdate(with event: NSEvent) { cursor.set() }
        override func mouseEntered(with event: NSEvent) { cursor.set() }

        override func mouseExited(with event: NSEvent) {
            guard !dragging else { return }
            NSCursor.arrow.set()
        }

        // MARK: Drag

        override func mouseDown(with event: NSEvent) {
            guard let settings else { return }
            dragging = true
            origin = NSEvent.mouseLocation
            startWidth = settings.appearance.panelWidth
            startListHeight = settings.appearance.listMaxHeight
            // Live while the pointer moves, one defaults write when it is let go.
            settings.beginAppearanceDrag()
            cursor.set()
        }

        override func mouseDragged(with event: NSEvent) {
            guard dragging, let settings else { return }
            let point = NSEvent.mouseLocation
            let next: Appearance
            switch zone {
            case .edge:
                next = settings.appearance.resized(width: startWidth + point.x - origin.x)
            case .corner:
                // Screen y grows upwards; dragging the corner down has to make the list taller.
                next = settings.appearance.resized(
                    width: startWidth + point.x - origin.x,
                    listHeight: startListHeight + origin.y - point.y
                )
            }
            guard next != settings.appearance else { return }
            settings.appearance = next
        }

        override func mouseUp(with event: NSEvent) {
            guard dragging else { return }
            dragging = false
            settings?.endAppearanceDrag()
        }

        /// The strip lies over the list's margin; a scroll started there belongs to the list.
        override func scrollWheel(with event: NSEvent) {
            nextResponder?.scrollWheel(with: event)
        }
    }
}
