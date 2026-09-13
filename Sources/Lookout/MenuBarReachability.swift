import AppKit

/// Whether the status item is somewhere the user can actually click it.
///
/// A full menu bar on a notched display parks the leftmost status items *behind the notch*.
/// The item still exists and still reports a frame — measured on a 1512 pt wide MacBook display
/// it sat at x 756–858, dead centre, with the first clickable item starting at 911 — but
/// nothing is drawn there and nothing can be clicked. Unpinning the panel in that state hid the
/// only other way in, and the app was gone until its defaults were edited by hand.
enum MenuBarReachability {

    /// Pure geometry, so the decision is testable without a menu bar.
    ///
    /// `leftArea` and `rightArea` are `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`:
    /// the two stretches of menu bar beside the notch. Both are nil on a screen without one, and
    /// then anything on screen counts. Containment, not intersection — an item straddling the
    /// notch edge is half-hidden, which is no better than fully hidden.
    static func isReachable(
        item: NSRect, leftArea: NSRect?, rightArea: NSRect?, screen: NSRect
    ) -> Bool {
        guard item.width > 1, item.height > 1 else { return false }
        guard let leftArea, let rightArea else { return screen.intersects(item) }
        return leftArea.contains(item) || rightArea.contains(item)
    }

    /// The live check for the status item's own button.
    static func isReachable(button: NSStatusBarButton?) -> Bool {
        guard let button, let window = button.window else { return false }
        let item = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard let screen = window.screen ?? NSScreen.main else { return true }
        return isReachable(
            item: item,
            leftArea: screen.auxiliaryTopLeftArea,
            rightArea: screen.auxiliaryTopRightArea,
            screen: screen.frame
        )
    }
}
