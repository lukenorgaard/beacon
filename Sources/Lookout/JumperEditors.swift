import AppKit
import ApplicationServices
import Foundation
import os

extension Jumper {
    // MARK: - VS Code family (SPEC §9.2)

    /// LaunchServices, not the editor's own CLI: `open -a Cursor <folder>` costs 0.07 s against
    /// the node CLI's 1.2 s and — verified by window counts — still reuses the window that
    /// already has the folder open. Never `-r`, and never a `--new-window`-shaped flag: the
    /// folder argument alone is what makes VS Code reuse rather than replace a workspace.
    static func launchArguments(for host: SessionHost) -> [String]? {
        switch host {
        case .cursor: return ["-a", "Cursor"]
        case .devin: return ["-b", "com.exafunction.windsurf"]
        case .vscode: return ["-b", "com.microsoft.VSCode"]
        default: return nil
        }
    }

    /// Where that editor keeps its `workspaceStorage` (SPEC §2.4).
    static func workspaceStorageApp(for host: SessionHost) -> String? {
        switch host {
        case .cursor: return "Cursor"
        case .devin: return "Devin"
        case .vscode: return "Code"
        default: return nil
        }
    }

    /// SPEC §12.4: aim at a window that is open *now*. A session in a git worktree resolves to
    /// its main repository, which is the window that actually hosts it; no open window matching
    /// any candidate means the app is merely activated — opening a folder here would spawn a
    /// second window for a worktree nobody has open.
    /// SPEC §16.3's order, with each step injected so the ordering itself is testable.
    enum EditorJumpPath: String, Equatable {
        /// The companion selected the session's own terminal tab, and the window was raised.
        case companion
        /// No companion match — the folder jump landed in the window that has it open.
        case window
        /// Neither worked; the caller activates the app.
        case activate
    }

    /// Companion focus → open-window folder jump → activate (SPEC §16.3). Every path is written
    /// to `jump.log`, because from the outside all three look like "the editor came forward".
    static func editorJump(
        session: Session,
        focus: (Session) -> CompanionMatch?,
        raise: (CompanionMatch) -> Bool,
        openWindow: (Session) -> Bool
    ) -> EditorJumpPath {
        if let match = focus(session) {
            // `terminal.show()` reveals the tab inside its own window; it does not bring that
            // window forward across Spaces, so the app is raised too (SPEC §16.3).
            let raised = raise(match)
            diag(
                "editor \(session.host.rawValue): companion focus rule=\(match.rule.rawValue) "
                    + "terminal=\(match.terminal.index) raised=\(raised ? 1 : 0)"
            )
            return .companion
        }
        if openWindow(session) {
            diag("editor \(session.host.rawValue): open-window jump")
            return .window
        }
        diag("editor \(session.host.rawValue): activate only")
        return .activate
    }

    /// Brings the window the companion just typed into forward. The matched instance names the
    /// folders that window has open, so the jump can aim at *that* window rather than whichever
    /// one the editor last had in front; a window with no folder falls back to a bare activation.
    @discardableResult
    static func raiseEditorWindow(host: SessionHost, match: CompanionMatch) -> Bool {
        guard let arguments = launchArguments(for: host) else { return false }
        var extra: [String] = []
        if let folder = match.instance.folders.first, folder.hasPrefix("/"),
           FileManager.default.fileExists(atPath: folder) {
            extra = [folder]
        }
        return Shell.run("/usr/bin/open", arguments + extra, timeout: launchTimeout).exitCode == 0
    }

    static func openEditor(host: SessionHost, session: Session) -> Bool {
        guard let arguments = launchArguments(for: host),
              let storageApp = workspaceStorageApp(for: host)
        else { return false }
        let open = WorkspaceIndex.openFolders(
            inStorageFile: WorkspaceIndex.globalStorageFile(app: storageApp)
        )
        let candidates = WorkspaceIndex.candidates(for: session)
        guard let folder = WorkspaceIndex.bestOpenFolder(for: candidates, among: open) else {
            diag("editor \(storageApp): no open window for \(candidates.count) candidate(s)")
            return false
        }
        let result = Shell.run("/usr/bin/open", arguments + [folder], timeout: launchTimeout)
        return result.exitCode == 0
    }
}
