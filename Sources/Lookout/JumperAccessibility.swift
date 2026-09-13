import AppKit
import ApplicationServices
import Foundation
import os

extension Jumper {
    static func desktopSessionButton(
        named desktopTitle: String, before deadline: Date, seen: inout Int
    ) -> DesktopButton? {
        guard let pid = desktopAppPID() else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, axMessagingTimeout)

        guard let windows = axElements(application, kAXWindowsAttribute), !windows.isEmpty else {
            return nil
        }

        var buttons: [AXUIElement] = []
        var names: [String] = []
        collectButtons(from: windows, into: &buttons, names: &names, before: deadline)
        seen = names.count

        guard let index = matchIndex(desktopTitle: desktopTitle, in: names) else { return nil }
        return DesktopButton(element: buttons[index], index: index)
    }

    /// The desktop app has two surfaces at the top of its window, exposed as `AXRadioButton`s
    /// described `Chat and Cowork` and `Code` (read off the live AX tree, 2026-09-02). Code
    /// sessions are only in the sidebar while `Code` is selected, and a collapsed sidebar shows
    /// a `Show sidebar` button instead of the rows. Both are put right before the row search.
    static func ensureCodeSurface(before deadline: Date, useMenu: Bool = true) {
        guard let pid = desktopAppPID() else { return }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, axMessagingTimeout)

        // Coordinate-free first: the app's own View menu has "Next Sidebar Tab" (read off its
        // menu bar, 2026-09-02), which flips between the Chat and Code surfaces.
        if useMenu, let item = menuItem(in: application, menu: "View", titled: "Next Sidebar Tab") {
            let pressed = AXUIElementPerformAction(item, kAXPressAction as CFString)
            diag("desktop jump: View > Next Sidebar Tab press=\(pressed.rawValue)")
            Thread.sleep(forTimeInterval: 0.45)
            return
        }
        guard let windows = axElements(application, kAXWindowsAttribute), !windows.isEmpty else {
            return
        }

        var codeRadio: AXUIElement?
        var showSidebar: AXUIElement?
        var stack = windows.reversed().map { $0 }
        var visited = 0
        while visited < axElementCap, let element = stack.popLast() {
            visited += 1
            if visited % 64 == 0, Date() >= deadline { break }
            let role = axString(element, kAXRoleAttribute)
            if role == kAXRadioButtonRole, codeRadio == nil,
               axString(element, kAXDescriptionAttribute) == "Code" {
                codeRadio = element
            } else if role == kAXButtonRole, showSidebar == nil,
                      axString(element, kAXDescriptionAttribute) == "Show sidebar" {
                showSidebar = element
            }
            if codeRadio != nil, showSidebar != nil { break }
            if let children = axElements(element, kAXChildrenAttribute) {
                stack.append(contentsOf: children.reversed())
            }
        }

        guard let codeRadio else {
            diag("desktop jump: code surface switch not found")
            return
        }
        // Neither AXValue nor AXSelected reflects the selected surface (verified 2026-09-02), so
        // the switch is unconditional: pressing Code while already on Code changes nothing.
        if let position = axPoint(codeRadio, kAXPositionAttribute), let size = axSize(codeRadio, kAXSizeAttribute) {
            diag("desktop jump: code radio at \(Int(position.x)),\(Int(position.y)) size \(Int(size.width))x\(Int(size.height))")
        }
        let pressed = AXUIElementPerformAction(codeRadio, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.15)
        let clicked = clickDesktopButton(codeRadio)
        Thread.sleep(forTimeInterval: 0.4)
        diag("desktop jump: code surface press=\(pressed.rawValue) click=\(clicked ? 1 : 0)")
        if let showSidebar {
            let pressed = AXUIElementPerformAction(showSidebar, kAXPressAction as CFString)
            diag("desktop jump: show sidebar press=\(pressed.rawValue)")
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// A menu item by menu title and item title, through the app's AX menu bar.
    static func menuItem(in application: AXUIElement, menu menuTitle: String, titled itemTitle: String) -> AXUIElement? {
        var barValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXMenuBarAttribute as CFString, &barValue) == .success,
              let bar = barValue else { return nil }
        let menuBar = bar as! AXUIElement
        guard let menus = axElements(menuBar, kAXChildrenAttribute) else { return nil }
        for menu in menus where axString(menu, kAXTitleAttribute) == menuTitle {
            guard let submenus = axElements(menu, kAXChildrenAttribute) else { continue }
            for submenu in submenus {
                guard let items = axElements(submenu, kAXChildrenAttribute) else { continue }
                for item in items where axString(item, kAXTitleAttribute) == itemTitle {
                    return item
                }
            }
        }
        return nil
    }

    private static func axNumber(_ element: AXUIElement, _ attribute: String) -> NSNumber? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? NSNumber
    }

    /// Polls the sidebar for the row until `deadline` (100 ms apart). Returns nil when it never
    /// appears — after a surface switch the rows arrive asynchronously, hence the polling.
    static func searchDesktopSession(
        named title: String, until deadline: Date, seen: inout Int
    ) -> DesktopButton? {
        repeat {
            if let found = desktopSessionButton(named: title, before: deadline, seen: &seen) {
                return found
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            Thread.sleep(forTimeInterval: min(axPollInterval, remaining))
        } while Date() < deadline
        return nil
    }

    static func desktopAppPID() -> pid_t? {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: desktopBundleID)
            .first?
            .processIdentifier
    }

    /// Depth-first, explicit stack (the tree is deep enough to matter), children pushed in
    /// reverse so `names` comes out in tree order and "ambiguous → first" means what it says.
    ///
    /// Two brakes, because either can be the one that bites: the element cap, and the caller's
    /// own deadline — an app whose accessibility server has gone slow must not stretch the 2 s
    /// budget by however long one pass happens to take. The clock is only read every 64
    /// elements; a measured pass over the real app visits ~420.
    private static func collectButtons(
        from roots: [AXUIElement], into buttons: inout [AXUIElement], names: inout [String],
        before deadline: Date
    ) {
        var stack = roots.reversed().map { $0 }
        var visited = 0

        while visited < axElementCap, let element = stack.popLast() {
            visited += 1
            if visited % 64 == 0, Date() >= deadline { return }
            if axString(element, kAXRoleAttribute) == kAXButtonRole,
               let name = buttonName(element) {
                buttons.append(element)
                names.append(name)
            }
            if let children = axElements(element, kAXChildrenAttribute) {
                stack.append(contentsOf: children.reversed())
            }
        }
    }

    /// `kAXTitleAttribute`, or the description when the title is empty (SPEC §9.4).
    private static func buttonName(_ element: AXUIElement) -> String? {
        Session.text(axString(element, kAXTitleAttribute))
            ?? Session.text(axString(element, kAXDescriptionAttribute))
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func axElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? [AXUIElement]
    }

    /// `CFBoolean` is toll-free bridged to `NSNumber`, which is what `AXSelected` arrives as.
    static func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let raw = value
        else { return nil }
        return (raw as? NSNumber)?.boolValue
    }

    /// `AXPosition` and `AXSize` come back boxed in an `AXValue`, not as plain CF types.
    private static func axStructure(
        _ element: AXUIElement, _ attribute: String
    ) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        return (raw as! AXValue)
    }

    static func axPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let boxed = axStructure(element, attribute) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(boxed, .cgPoint, &point) else { return nil }
        return point
    }

    static func axSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let boxed = axStructure(element, attribute) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(boxed, .cgSize, &size) else { return nil }
        return size
    }
}
