import AppKit
import ApplicationServices
import Foundation
import os

/// Lands the user in a session (SPEC §2.4). Everything here runs off the main thread: a wedged
/// `osascript` or CLI must never freeze the panel.
enum Jumper {
    static let log = Logger(subsystem: "io.github.lukenorgaard.beacon", category: "jump")

    /// SPEC §16.3's editor companion. A `var` so a test can put a stub in front of it — nothing
    /// in this file may open a socket to a real editor window during `swift test`.
    static var companion: CompanionChannel = EditorCompanion.shared

    /// Plain-file mirror of the desktop-jump diagnostics (`~/.lookout/jump.log`). The unified log
    /// could not be read back on the owner's Mac from the sandboxed shell, so the facts go to a file
    /// too. Titles are never written here — only counts, indices and result codes.
    static func diag(_ message: String) {
        let home = ProcessInfo.processInfo.environment["LOOKOUT_HOME"]
            ?? NSHomeDirectory() + "/.lookout"
        let path = home + "/jump.log"
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)\n"
        do {
            try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attrs[.size] as? NSNumber, size.intValue > 200_000 {
                try? FileManager.default.removeItem(atPath: path)
            }
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                handle.closeFile()
            } else {
                try line.write(toFile: path, atomically: true, encoding: .utf8)
            }
        } catch {
            // Diagnostics must never affect the jump.
        }
    }
    static let queue = DispatchQueue(label: "io.github.lukenorgaard.beacon.jump", qos: .userInitiated)

    /// SPEC §9.2: nothing on the click path may block longer than 2 s. `open` costs 0.07–0.12 s
    /// measured, so this is ~10× headroom, and `Shell.timeoutOverhead` is what a wedged child
    /// can add on top before it is killed — the two together stay under the 2 s budget.
    static let launchTimeout: TimeInterval = 1.2
    /// AppleScript has to walk every window of Terminal/iTerm, so it keeps the longer deadline
    /// §9.2 allows it.
    static let appleScriptTimeout: TimeInterval = 3

    // MARK: - Claude desktop AX budget (SPEC §9.4, §9.6)

    static let desktopBundleID = "com.anthropic.claudefordesktop"
    /// The ChatGPT desktop app, which hosts Codex sessions. Its bundle id is `com.openai.codex`
    /// even though the app is named ChatGPT — verified against `/Applications/ChatGPT.app`.
    static let codexBundleID = "com.openai.codex"
    /// The sidebar is React — the row for a session that was just activated can take a moment to
    /// exist. §9.4 gives the *whole* desktop jump 3 s and not a millisecond more; §9.6 reserves
    /// `axPostMatchReserve` of that for the press probe, the click and its verification (with one
    /// retry) — the rest (`axSearchBudget`) is what is left over for finding the row at all.
    static let axPollBudget: TimeInterval = 3
    /// How long the row is looked for before switching surfaces.
    static let axQuickSearchBudget: TimeInterval = 0.5
    static let axPollInterval: TimeInterval = 0.1
    /// The desktop app's web area is deep; the walk stops here rather than chasing an unbounded
    /// tree while the user waits.
    static let axElementCap = 3000
    /// A hung accessibility server must not eat the whole budget in one call.
    static let axMessagingTimeout: Float = 0.5

    /// §9.6 (2026-09-04 revision): `~/.lookout/jump.log` over two days showed the AXPress has
    /// never once selected the row — the click fallback has done the work every single time. The
    /// old code still waited 150 ms then 400 ms for a press that was never going to land; this
    /// waits once, briefly, so a future desktop build that does honour the press is still caught,
    /// then falls straight through to the click that actually works.
    static let axPressSelectionWait: TimeInterval = 0.05
    /// Pointer-move-to-press gap, then the mouse-down hold — real UI events an Electron sidebar
    /// has to notice, not a 0 ms blip.
    static let axClickMoveWait: TimeInterval = 0.03
    static let axClickHold: TimeInterval = 0.04
    /// After a click, how the selection poll is spaced and how many times it is tried before the
    /// row counts as "did not take" (§9.6: "a short poll, ≤ 3 × 50 ms").
    static let axClickVerifyInterval: TimeInterval = 0.05
    /// One read, for the log line only: the first live jump after the 2026-09-04 revision read
    /// `press=1 click=1 selected=0` although the jump landed — the sidebar never reports the
    /// row as selected, so polling longer buys nothing and the retry keys on the click instead.
    static let axClickVerifyAttempts = 1
    /// A retry click re-reads the row instead of reusing the first lookup, in case the sidebar
    /// scrolled (or re-rendered the row entirely) between the match and the click; this is what
    /// that second search may spend.
    static let axRetrySearchBudget: TimeInterval = 0.2

    /// One click's own wall time: move to the point, then hold the button down.
    static var axClickDuration: TimeInterval { axClickMoveWait + axClickHold }
    /// A click plus the poll that confirms (or fails to confirm) it worked.
    static var axClickCycleBudget: TimeInterval {
        axClickDuration + axClickVerifyInterval * Double(axClickVerifyAttempts)
    }
    /// Everything that can happen once the row is matched: the press's own short probe, one
    /// click-and-verify cycle, the retry's fresh lookup, and a second click-and-verify cycle for
    /// that retry. `axSearchBudget` below is whatever `axPollBudget` has left once this is set
    /// aside.
    static var axPostMatchReserve: TimeInterval {
        axPressSelectionWait + axClickCycleBudget + axRetrySearchBudget + axClickCycleBudget
    }
    /// What the search may spend so that press + verify + click + one retry still fit inside
    /// `axPollBudget`.
    static var axSearchBudget: TimeInterval { axPollBudget - axPostMatchReserve }
    /// `kAXScrollToVisibleAction` is not exported to Swift; the string behind it is stable API
    /// and is exactly what the live sidebar button lists among its actions (§9.6).
    static let scrollToVisibleAction = "AXScrollToVisible"

    static func jump(to session: Session) {
        queue.async { perform(session) }
    }

    private static func perform(_ session: Session) {
        // A session inside the desktop app cannot be reached by its deep link while the gate is
        // shut, so it is activated and then pressed in the sidebar (SPEC §9.4).
        if session.host == .claudeDesktop || session.entrypoint == "claude-desktop" {
            jumpToDesktop(session)
            return
        }

        switch session.host {
        case .cursor, .devin, .vscode:
            let path = editorJump(
                session: session,
                focus: { Jumper.companion.focus(session: $0) },
                raise: { raiseEditorWindow(host: session.host, match: $0) },
                openWindow: { openEditor(host: session.host, session: $0) }
            )
            if path != .activate { return }
        case .terminal:
            if focusTerminal(tty: session.tty) { return }
        case .iterm:
            if focusITerm(reference: session.hostRef) { return }
        case .codexApp:
            if activateCodexApp() { return }
        case .claudeDesktop, .unknown:
            break
        }

        activate(session)
    }
}

extension Jumper {
    /// SPEC line 245: a Codex desktop session is an "app activation only" jump.
    ///
    /// Two things had to be true and neither was. `activate(_:)` cannot reach the app, because
    /// the host pid the scanner records is an in-bundle helper (`cua_node/bin/node_repl` under
    /// `ChatGPT.app`) and `NSRunningApplication(processIdentifier:)` is nil for anything that is
    /// not a registered application — so the click did nothing at all. And LaunchServices is no
    /// way out either: measured on macOS 26.5, neither `open -b com.openai.codex` nor
    /// `open -a /Applications/ChatGPT.app` moves the app to the front, whether it is hidden or
    /// merely backgrounded, even though both exit 0. AppleScript activation does work, and it is
    /// the same mechanism the terminal jumps already use.
    static func codexActivationScript() -> String {
        "tell application id \"\(codexBundleID)\" to activate"
    }

    @discardableResult
    static func activateCodexApp() -> Bool {
        runAppleScript(codexActivationScript())
    }
}
