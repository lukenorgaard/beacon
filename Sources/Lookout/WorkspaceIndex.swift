import AppKit
import ApplicationServices
import Foundation
import os

/// The set of folders a VS Code-family editor has open, read from its `workspaceStorage`.
///
/// `~/Library/Application Support/<App>/User/workspaceStorage/*/workspace.json` holds
/// `{"folder": "file:///Users/you/Desktop/Example%20Demo%20Project"}` (SPEC §2.4).
enum WorkspaceIndex {
    // MARK: - Windows that are open right now (SPEC §12.4)

    /// `globalStorage/storage.json` holds the windows the editor has open *now*, which is what a
    /// jump must aim at. `workspaceStorage` (below) lists every workspace ever opened, and using
    /// it for jumping is what made a closed worktree open a brand-new window.
    static func globalStorageFile(app: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/\(app)/User/globalStorage/storage.json"
            )
    }

    /// `windowsState.openedWindows[].folder` plus `windowsState.lastActiveWindow.folder`, as
    /// decoded paths, in order and without duplicates.
    static func openFolders(json data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windows = root["windowsState"] as? [String: Any]
        else { return [] }

        var result: [String] = []
        func add(_ value: Any?) {
            guard let entry = value as? [String: Any],
                  let folder = entry["folder"] as? String,
                  let path = self.path(fromFileURI: folder)
            else { return }
            if !result.contains(path) { result.append(path) }
        }

        for window in (windows["openedWindows"] as? [[String: Any]]) ?? [] { add(window) }
        add(windows["lastActiveWindow"])
        return result
    }

    static func openFolders(inStorageFile url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return openFolders(json: data)
    }

    /// Where a session might live, in the order §12.4 gives: its own directory, the directory it
    /// started in, and — when it is a git worktree — the repository that worktree belongs to.
    static func candidates(for session: Session) -> [String] {
        var result: [String] = []
        func add(_ value: String?) {
            guard let path = Session.text(value) else { return }
            let normalised = normalise(path)
            guard !normalised.isEmpty, !result.contains(normalised) else { return }
            result.append(normalised)
        }
        add(session.cwd)
        add(session.originCwd)
        add(mainRepository(forWorktreeAt: session.cwd))
        if session.originCwd != nil {
            add(mainRepository(forWorktreeAt: session.originCwd ?? ""))
        }
        return result
    }

    /// How far up the tree the `.git` walk goes before giving up.
    static let worktreeWalkLimit = 24

    /// SPEC §12.4: in a git worktree `<dir>/.git` is a *file* holding
    /// `gitdir: <repo>/.git/worktrees/<name>`. Walk up from `path` until one turns up.
    static func mainRepository(
        forWorktreeAt path: String, fileManager: FileManager = .default
    ) -> String? {
        var directory = normalise(path)
        guard !directory.isEmpty else { return nil }

        for _ in 0..<worktreeWalkLimit {
            guard directory.hasPrefix("/"), directory != "/" else { return nil }
            let marker = directory + "/.git"
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: marker, isDirectory: &isDirectory) {
                // A real `.git` directory means this *is* the repository — no worktree above it.
                if isDirectory.boolValue { return nil }
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: marker)),
                      data.count < 8192
                else { return nil }
                return repository(fromGitFile: String(decoding: data, as: UTF8.self))
            }
            directory = normalise((directory as NSString).deletingLastPathComponent)
        }
        return nil
    }

    /// `gitdir: /Users/a/Acme/repo/.git/worktrees/fe2` → `/Users/a/Acme/repo`.
    static func repository(fromGitFile contents: String) -> String? {
        for line in contents.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("gitdir:") else { continue }
            let raw = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard let range = raw.range(of: "/.git/worktrees/") else { return nil }
            let repository = normalise(String(raw[raw.startIndex..<range.lowerBound]))
            return repository.isEmpty ? nil : repository
        }
        return nil
    }

    /// SPEC §12.4: the longest open-window folder that equals or contains a candidate. Nil means
    /// no window has this session's folder open — activate the app, never open a new window.
    static func bestOpenFolder(for candidates: [String], among open: [String]) -> String? {
        for candidate in candidates {
            let target = normalise(candidate)
            guard !target.isEmpty else { continue }
            var best: String?
            for folder in open {
                let normalised = normalise(folder)
                guard !normalised.isEmpty else { continue }
                guard target == normalised || target.hasPrefix(normalised + "/") else { continue }
                if best == nil || normalised.count > normalise(best!).count { best = folder }
            }
            if let best { return best }
        }
        return nil
    }

    // MARK: - Every workspace ever opened (SPEC §2.4)

    static func storageDirectory(app: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(app)/User/workspaceStorage")
    }

    static func roots(inStorage directory: URL) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }

        var roots: [String] = []
        for name in names {
            let file = directory.appendingPathComponent(name).appendingPathComponent("workspace.json")
            guard let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let folder = root["folder"] as? String,
                  let path = self.path(fromFileURI: folder)
            else { continue }
            if !roots.contains(path) { roots.append(path) }
        }
        return roots
    }

    static func path(fromFileURI uri: String) -> String? {
        guard uri.hasPrefix("file://") else { return nil }
        if let url = URL(string: uri), url.isFileURL {
            let path = url.path
            return path.isEmpty ? nil : path
        }
        let raw = String(uri.dropFirst("file://".count))
        return raw.removingPercentEncoding
    }

    /// Longest known workspace folder that is a prefix of `cwd` (SPEC §2.4). A prefix only
    /// counts on a path boundary, so `/Users/a/Desktop` never claims `/Users/a/DesktopX`.
    static func bestRoot(for cwd: String, among roots: [String]) -> String? {
        let target = normalise(cwd)
        guard !target.isEmpty else { return nil }

        var best: String?
        for root in roots {
            let candidate = normalise(root)
            guard !candidate.isEmpty else { continue }
            guard target == candidate || target.hasPrefix(candidate + "/") else { continue }
            if best == nil || candidate.count > normalise(best!).count { best = root }
        }
        return best
    }

    static func normalise(_ path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespaces)
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
