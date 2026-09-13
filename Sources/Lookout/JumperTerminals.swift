import AppKit
import ApplicationServices
import Foundation
import os

extension Jumper {
    // MARK: - Terminals

    /// Select the tab whose tty matches, raise its window, activate. macOS follows to that Space.
    static func focusTerminal(tty: String?) -> Bool {
        guard let device = devicePath(tty) else { return false }
        let script = """
        tell application "Terminal"
            set matched to false
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if tty of t is "\(device)" then
                            set selected tab of w to t
                            set index of w to 1
                            set matched to true
                            exit repeat
                        end if
                    end try
                end repeat
                if matched then exit repeat
            end repeat
            activate
            return matched
        end tell
        """
        return runAppleScript(script)
    }

    /// `ITERM_SESSION_ID` looks like `w0t0p0:6E4A…` — iTerm's session id is the part after the colon.
    static func focusITerm(reference: String?) -> Bool {
        let identifier = itermSessionID(reference)
        guard let identifier else {
            return runAppleScript("tell application \"iTerm\" to activate")
        }
        let script = """
        tell application "iTerm"
            set matched to false
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            if id of s is "\(identifier)" then
                                select w
                                select t
                                select s
                                set matched to true
                                exit repeat
                            end if
                        end try
                    end repeat
                    if matched then exit repeat
                end repeat
                if matched then exit repeat
            end repeat
            activate
            return matched
        end tell
        """
        return runAppleScript(script)
    }

    // MARK: - Typing into a tab (SPEC §15.5)

    /// An AppleScript string literal escapes exactly two characters. A session name is the owner's
    /// own text, so it goes through this before it is ever pasted into a script — and a newline
    /// is flattened, because it would end the command early and run whatever followed it.
    static func appleScriptLiteral(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// SPEC §15.5: run one line in the Terminal tab this session owns, exactly as if it had been
    /// typed there — `do script … in <tab>` presses return for us.
    static func typeIntoTerminal(tty: String?, command: String) -> Bool {
        guard let device = devicePath(tty), let text = Session.text(command) else { return false }
        let script = """
        tell application "Terminal"
            set matched to false
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if tty of t is "\(device)" then
                            do script "\(appleScriptLiteral(text))" in t
                            set selected tab of w to t
                            set index of w to 1
                            set matched to true
                            exit repeat
                        end if
                    end try
                end repeat
                if matched then exit repeat
            end repeat
            return matched
        end tell
        """
        return runAppleScript(script)
    }

    /// SPEC §15.5: the iTerm half — `write text` on the session sends the line and its return.
    static func typeIntoITerm(reference: String?, command: String) -> Bool {
        guard let identifier = itermSessionID(reference), let text = Session.text(command)
        else { return false }
        let script = """
        tell application "iTerm"
            set matched to false
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            if id of s is "\(identifier)" then
                                write text "\(appleScriptLiteral(text))" to s
                                set matched to true
                                exit repeat
                            end if
                        end try
                    end repeat
                    if matched then exit repeat
                end repeat
                if matched then exit repeat
            end repeat
            return matched
        end tell
        """
        return runAppleScript(script)
    }

    /// The host-agnostic entry point the rename uses (SPEC §15.5): true when the line was
    /// delivered into the session's own tab.
    static func type(command: String, into session: Session) -> Bool {
        switch session.host {
        case .terminal: return typeIntoTerminal(tty: session.tty, command: command)
        case .iterm: return typeIntoITerm(reference: session.hostRef, command: command)
        default: return false
        }
    }

    static func itermSessionID(_ reference: String?) -> String? {
        guard let reference, !reference.isEmpty else { return nil }
        guard let colon = reference.firstIndex(of: ":") else { return reference }
        let tail = String(reference[reference.index(after: colon)...])
        return tail.isEmpty ? nil : tail
    }

    /// `ttys005` and `/dev/ttys005` both arrive here; AppleScript wants the device path.
    static func devicePath(_ tty: String?) -> String? {
        guard var value = tty?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("/dev/") { return value }
        if !value.hasPrefix("tty") { value = "tty" + value }
        return "/dev/" + value
    }

    /// `osascript` rather than `NSAppleScript`: it needs no main-thread run loop, so the jump
    /// stays entirely off the main thread (SPEC §5.6).
    private static func runAppleScript(_ source: String) -> Bool {
        let result = Shell.run("/usr/bin/osascript", ["-e", source], timeout: appleScriptTimeout)
        guard result.exitCode == 0 else {
            log.error("AppleScript jump failed")
            return false
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) != "false"
    }

    // MARK: - Fallback

    /// Nothing clever left: bring the host app (or the agent's own app) forward.
    static func activate(_ session: Session) {
        let pid = session.hostPID ?? session.pid
        DispatchQueue.main.async {
            if let pid, let app = NSRunningApplication(processIdentifier: pid) {
                app.activate(options: [.activateAllWindows])
                return
            }
            if session.host == .claudeDesktop {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Claude.app"))
            }
        }
    }
}
