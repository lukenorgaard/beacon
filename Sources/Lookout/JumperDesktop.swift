import AppKit
import ApplicationServices
import Foundation
import os

extension Jumper {
    // MARK: - Claude desktop (SPEC §9.1)

    /// The desktop app's URL handler validates the id against `^local_[A-Za-z0-9-]{1,64}$` and
    /// then looks it up by `sessionId`. A Claude Code UUID fails that check silently, which is
    /// why the old link only ever brought the app to the front. The desktop id arrives as
    /// `CLAUDE_CODE_HOST_SESSION_ID` and is stored in `host_ref`.
    static func desktopSessionID(_ hostRef: String?) -> String? {
        guard let raw = hostRef?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.hasPrefix("local_")
        else { return nil }
        let tail = raw.dropFirst("local_".count)
        guard (1...64).contains(tail.count) else { return nil }
        let allowed = tail.allSatisfy { character in
            guard character.isASCII else { return false }
            return character.isLetter || character.isNumber || character == "-"
        }
        return allowed ? raw : nil
    }

    /// The deep link for a desktop session, or nil when there is no usable id — in which case
    /// the caller falls back to activating the app.
    static func desktopLink(hostRef: String?) -> String? {
        guard let id = desktopSessionID(hostRef) else { return nil }
        return "claude://code/continue?session=\(id)&source=lookout"
    }

    @discardableResult
    static func openDesktopSession(hostRef: String?) -> Bool {
        guard let link = desktopLink(hostRef: hostRef) else { return false }
        return Shell.run("/usr/bin/open", [link], timeout: launchTimeout).exitCode == 0
    }

    /// `open -b com.anthropic.claudefordesktop` — the activation SPEC §9.4 relies on. The
    /// sidebar is only Accessibility-visible once the app is frontmost.
    @discardableResult
    static func activateDesktopApp() -> Bool {
        Shell.run("/usr/bin/open", ["-b", desktopBundleID], timeout: launchTimeout).exitCode == 0
    }

    /// SPEC §9.4. The deep link still goes out — it is validated but gated off in this build, so
    /// today it only activates, and it starts selecting the session for free the day the gate
    /// opens. Then the app is activated for certain, and the sidebar button carrying the
    /// session's `desktop_title` is pressed through the Accessibility API. Anything that fails
    /// leaves the user in the activated app, which is exactly the old behaviour.
    static func jumpToDesktop(_ session: Session) {
        diag("desktop jump: start hostRef=\(session.hostRef == nil ? 0 : 1) title=\(Session.text(session.desktopTitle) == nil ? 0 : 1)")
        openDesktopSession(hostRef: session.hostRef)
        let activated = activateDesktopApp()
        diag("desktop jump: activated=\(activated ? 1 : 0)")

        if let title = Session.text(session.desktopTitle), pressDesktopSession(named: title) {
            return
        }
        // Discovered desktop processes have no `desktop_title` at all (SPEC §9.4): activation is
        // the whole jump for them.
        if !activated { activate(session) }
    }

    // MARK: - Claude desktop sidebar (SPEC §9.4)

    /// Statuses the desktop sidebar puts in front of a session's title
    /// (`Running Terminal session overlay widget`). A button whose prefix is one of these is a
    /// better match than one whose prefix is anything else.
    ///
    /// `Running`, `Idle` and `Unread response` were read straight off the live sidebar's AX tree
    /// on 2026-09-02 (the third one is not in SPEC §9.4's list, which was written from a smaller
    /// sample); the rest are §9.4's. An unlisted status still matches — it just ranks below a
    /// listed one — so a new word in a future build costs preference, never the jump.
    static let desktopStatusPrefixes = [
        "Running", "Idle", "Unread response", "Needs input", "Waiting", "Finished", "Error",
    ]

    /// The pure half of the sidebar search, so the matching rules are testable without a
    /// running desktop app. Ranked best-first:
    ///
    /// 0. `<status> <desktop_title>` — what the sidebar actually renders,
    /// 1. `<desktop_title>` exactly,
    /// 2. `<anything> <desktop_title>` — a suffix match with a prefix that is not a status word.
    ///
    /// Ties go to the first button in tree order.
    static func matchIndex(desktopTitle: String, in names: [String]) -> Int? {
        guard let target = Session.text(desktopTitle) else { return nil }

        var best: (rank: Int, index: Int)?
        for (index, raw) in names.enumerated() {
            guard let name = Session.text(raw),
                  let rank = matchRank(name: name, target: target)
            else { continue }
            if best == nil || rank < best!.rank { best = (rank, index) }
        }
        return best?.index
    }

    static func matchRank(name: String, target: String) -> Int? {
        if name == target { return 1 }
        guard name.hasSuffix(" " + target) else { return nil }
        let prefix = String(name.dropLast(target.count + 1))
        return desktopStatusPrefixes.contains(prefix) ? 0 : 2
    }

    /// `AXIsProcessTrustedWithOptions` with the prompt option, once per launch: the first jump
    /// to a desktop session is what puts Lookout in System Settings → Accessibility. Later calls
    /// only ask, so a user who said no is never nagged again in this run.
    private static let trustLock = NSLock()
    private static var trustPrompted = false

    static func accessibilityTrusted() -> Bool {
        trustLock.lock()
        let alreadyPrompted = trustPrompted
        trustPrompted = true
        trustLock.unlock()

        if alreadyPrompted { return AXIsProcessTrusted() }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// The sidebar row that was matched, and how many named buttons the pass had to choose from.
    struct DesktopButton {
        let element: AXUIElement
        let index: Int
    }

    /// Polls the desktop app's AX tree, presses the session's sidebar button, checks that the
    /// press actually selected it and falls back to a real click when it did not (SPEC §9.6).
    /// Runs on the jump queue — never the main thread.
    ///
    /// Every step is logged at `.notice`, which is the lowest level `os_log` persists: the first
    /// implementation failed for the owner and left nothing behind at all, because `.info` lines are
    /// dropped as soon as the buffer wraps. `log show --predicate 'process == "Lookout"'` now
    /// shows the whole path. Only the title is `.private`.
    @discardableResult
    static func pressDesktopSession(named desktopTitle: String) -> Bool {
        // No title, nothing to press — and in particular no reason to ask for Accessibility.
        guard let title = Session.text(desktopTitle) else { return false }

        let trusted = accessibilityTrusted()
        log.notice("desktop jump: accessibility trusted=\(trusted ? 1 : 0, privacy: .public)")
        diag("desktop jump: accessibility trusted=\(trusted ? 1 : 0)")
        guard trusted else { return false }

        // Sessions only exist in the sidebar while the Code surface is showing (the owner, 2026-09-02:
        // "if I'm in Chat and not Code it doesn't work"). The app does not expose which surface
        // is selected (both radios read value="" selected=false), so the row itself is the test:
        // look for it briefly, and only if it is absent switch to Code and look again.
        let started = Date()
        var seen = 0
        var match = searchDesktopSession(named: title, until: started.addingTimeInterval(axQuickSearchBudget), seen: &seen)
        if match == nil {
            diag("desktop jump: row absent among \(seen) buttons; switching to the Code surface")
            ensureCodeSurface(before: Date().addingTimeInterval(0.6))
            match = searchDesktopSession(named: title, until: started.addingTimeInterval(axSearchBudget * 0.6), seen: &seen)
            if match == nil {
                diag("desktop jump: rows still absent (\(seen)); switching once more via the Code control")
                ensureCodeSurface(before: Date().addingTimeInterval(0.6), useMenu: false)
                match = searchDesktopSession(named: title, until: started.addingTimeInterval(axSearchBudget), seen: &seen)
            }
        }

        guard let match else {
            diag("desktop jump: no match among \(seen) sidebar buttons")
            log.notice(
                """
                desktop jump: no match among \(seen, privacy: .public) sidebar buttons \
                for \(title, privacy: .private)
                """
            )
            return false
        }
        log.notice(
            """
            desktop jump: matched button #\(match.index, privacy: .public) \
            of \(seen, privacy: .public) for \(title, privacy: .private)
            """
        )
        diag("desktop jump: matched button #\(match.index) of \(seen)")

        return pressAndVerify(match, title: title)
    }

    /// §9.6 (2026-09-04): press, give it one short chance to have worked, and otherwise click for
    /// real and verify that — retrying the click once, against a freshly looked-up row, before
    /// giving up. Everything past the match happens here so the whole path ends in exactly one
    /// summary line (`emitJumpSummary`) instead of the old scattering of intermediate lines.
    private static func pressAndVerify(_ match: DesktopButton, title: String) -> Bool {
        let stepStart = Date()

        // §9.6: a row that scrolled out of the sidebar is brought back before it is pressed —
        // AXScrollToVisible is in the button's own action list.
        let scrolled = AXUIElementPerformAction(match.element, scrollToVisibleAction as CFString)
        let pressed = AXUIElementPerformAction(match.element, kAXPressAction as CFString)
        diag("desktop jump: scrollToVisible=\(scrolled.rawValue) press=\(pressed.rawValue)")
        log.notice(
            """
            desktop jump: scrollToVisible=\(scrolled.rawValue, privacy: .public) \
            press=\(pressed.rawValue, privacy: .public)
            """
        )

        // The press has never once selected the row in two days of logs (SPEC §9.6, 2026-09-04):
        // one short probe is enough to catch a desktop build that fixes this, without making
        // every jump pay for the long wait that has never once paid off.
        if selectedState(match.element, after: axPressSelectionWait) == 1 {
            emitJumpSummary(press: true, click: false, selected: true, since: stepStart)
            return true
        }

        // The press was accepted (or not) and the row still is not selected: click it for real.
        // Idempotent for a sidebar row, so a false negative here costs nothing.
        var clicked = clickDesktopButton(match.element)
        var selected = pollSelected(match.element)

        if shouldRetryClick(clicked: clicked) {
            // The sidebar may have scrolled — or re-rendered the row entirely — between the match
            // and this click, so the retry re-finds the button instead of trusting the first
            // lookup's position.
            var retrySeen = 0
            let retryDeadline = Date().addingTimeInterval(axRetrySearchBudget)
            if let fresh = desktopSessionButton(named: title, before: retryDeadline, seen: &retrySeen) {
                diag("desktop jump: retry click against a fresh row (#\(fresh.index) of \(retrySeen))")
                let retryClicked = clickDesktopButton(fresh.element)
                clicked = clicked || retryClicked
                selected = pollSelected(fresh.element)
            } else {
                diag("desktop jump: retry click skipped — row no longer found among \(retrySeen)")
            }
        }

        let succeeded = clicked || pressed == .success
        emitJumpSummary(press: pressed == .success, click: clicked, selected: selected == 1, since: stepStart)
        return succeeded
    }

    /// Polls `AXSelected` up to `axClickVerifyAttempts` times, `axClickVerifyInterval` apart,
    /// stopping the moment it reads selected (§9.6: "a short poll, ≤ 3 × 50 ms"). Returns the
    /// last observed value: 1 selected, 0 not selected, -1 the sidebar exposes neither attribute.
    static func pollSelected(_ element: AXUIElement) -> Int {
        var state = -1
        for _ in 0..<axClickVerifyAttempts {
            state = selectedState(element, after: axClickVerifyInterval)
            if state == 1 { return state }
        }
        return state
    }

    /// §9.6: whether the click fallback is worth trying a second time. Only when the click could
    /// not be delivered at all (no usable rectangle) — a fresh lookup can hand the retry an
    /// element the first reference did not have. A delivered click is never repeated: the
    /// sidebar reads `selected=0` even after a jump that worked, so selection cannot decide it.
    static func shouldRetryClick(clicked: Bool) -> Bool {
        !clicked
    }

    /// The one line a desktop jump's click path leaves behind, replacing the old pair of
    /// "selected after 150ms" / "after 400ms" lines — a single line keeps `jump.log` readable
    /// even after weeks of use, while still saying exactly what happened.
    static func jumpSummaryLine(press: Bool, click: Bool, selected: Bool, elapsed: TimeInterval) -> String {
        let ms = Int((elapsed * 1000).rounded())
        return "desktop jump: press=\(press ? 1 : 0) click=\(click ? 1 : 0) selected=\(selected ? 1 : 0) total=\(ms)ms"
    }

    private static func emitJumpSummary(press: Bool, click: Bool, selected: Bool, since start: Date) {
        let line = jumpSummaryLine(
            press: press, click: click, selected: selected,
            elapsed: Date().timeIntervalSince(start)
        )
        diag(line)
        log.notice("\(line, privacy: .public)")
    }

    /// 1 selected, 0 not selected, -1 unreadable — after waiting `delay`. `AXValue` is the
    /// fallback §9.6 allows for a sidebar that exposes selection under the other name.
    static func selectedState(_ element: AXUIElement, after delay: TimeInterval = 0) -> Int {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if let selected = axBool(element, kAXSelectedAttribute) { return selected ? 1 : 0 }
        if let value = axBool(element, kAXValueAttribute) { return value ? 1 : 0 }
        return -1
    }

    /// SPEC §9.6: a real left click at the button's centre, with the cursor put back where the
    /// user left it. A button with no usable rectangle is never clicked — a stray click
    /// somewhere else on screen is far worse than a jump that did not happen.
    @discardableResult
    static func clickDesktopButton(_ element: AXUIElement) -> Bool {
        guard let position = axPoint(element, kAXPositionAttribute),
              let size = axSize(element, kAXSizeAttribute)
        else {
            log.notice("desktop jump: no position/size on the matched button, no click")
            diag("desktop jump: no position/size, no click")
            return false
        }
        guard let point = clickPoint(position: position, size: size) else {
            log.notice("desktop jump: zero-sized button, no click")
            return false
        }
        guard isOnScreen(point, in: activeDisplayBounds()) else {
            log.notice("desktop jump: click point is off-screen, no click")
            diag("desktop jump: click point off-screen, no click")
            return false
        }

        let restore = CGEvent(source: nil)?.location
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let move = CGEvent(
                mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: point, mouseButton: .left),
              let down = CGEvent(
                mouseEventSource: source, mouseType: .leftMouseDown,
                mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(
                mouseEventSource: source, mouseType: .leftMouseUp,
                mouseCursorPosition: point, mouseButton: .left)
        else {
            log.notice("desktop jump: could not build the click events")
            return false
        }

        // A real pointer arrives before it presses; a web view may ignore a press with no hover.
        move.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: axClickMoveWait)
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: axClickHold)
        up.post(tap: .cghidEventTap)
        if let restore { CGWarpMouseCursorPosition(restore) }
        diag("desktop jump: clicked at \(Int(point.x)),\(Int(point.y)) cursorRestored=\(restore == nil ? 0 : 1)")

        log.notice(
            """
            desktop jump: clicked at \(Int(point.x), privacy: .public),\
            \(Int(point.y), privacy: .public) cursorRestored=\(restore == nil ? 0 : 1, privacy: .public)
            """
        )
        return true
    }

    /// The centre of the button's rectangle, or nil when there is no rectangle to aim at.
    static func clickPoint(position: CGPoint, size: CGSize) -> CGPoint? {
        guard size.width > 0, size.height > 0,
              position.x.isFinite, position.y.isFinite,
              size.width.isFinite, size.height.isFinite
        else { return nil }
        return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
    }

    /// AX positions and `CGDisplayBounds` share one top-left-origin global space, so this is a
    /// plain containment test — and it needs no main thread, unlike `NSScreen`.
    static func isOnScreen(_ point: CGPoint, in bounds: [CGRect]) -> Bool {
        bounds.contains { $0.contains(point) }
    }

    static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map(CGDisplayBounds)
    }

    /// One pass over the app's windows. The sidebar lives inside the web area, so the walk goes
    /// through everything and is bounded by `axElementCap` instead of by role. `seen` comes back
    /// with how many named buttons the pass collected — the number §9.6 wants in the log.
}
