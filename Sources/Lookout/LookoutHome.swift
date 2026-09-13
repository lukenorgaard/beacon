import Foundation
import os

/// Every path under `~/.lookout` the answer-from-the-widget feature touches (SPEC §11.3, §11.4),
/// in one place, with `LOOKOUT_HOME` honoured exactly as `SessionStore` honours it.
///
/// Lookout only ever writes its own files here (SPEC §5.6): answers, two append-only logs and
/// the one config key the reporter reads back.
struct LookoutHome {
    let root: URL
    /// True when `LOOKOUT_HOME` (or an explicit root) points somewhere other than `~/.lookout`.
    let isOverridden: Bool

    init(root: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let root {
            self.root = root
            isOverridden = true
        } else if let override = environment["LOOKOUT_HOME"], !override.isEmpty {
            self.root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            isOverridden = true
        } else {
            self.root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".lookout", isDirectory: true)
            isOverridden = false
        }
    }

    var requests: URL { root.appendingPathComponent("requests", isDirectory: true) }
    var answers: URL { root.appendingPathComponent("answers", isDirectory: true) }
    var sessions: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    /// SPEC §15.1: one 0600 file per session holding its messaging token, written by the
    /// reporter (which sees the token in the hook's environment) and deleted on `SessionEnd`.
    /// Lookout only ever reads from here.
    var tokens: URL { root.appendingPathComponent("tokens", isDirectory: true) }
    /// SPEC §16.2: one 0600 file per open editor window, written by the companion extension and
    /// removed when that window goes away. Lookout only ever reads from here.
    var companion: URL { root.appendingPathComponent("companion", isDirectory: true) }
    var config: URL { root.appendingPathComponent("config.json") }
    /// SPEC §15.4: the custom session names, `{ "names": …, "seen": … }`. Lookout's own file —
    /// nothing else reads or writes it.
    var names: URL { root.appendingPathComponent("names.json") }
    var sendLog: URL { root.appendingPathComponent("send.log") }
    var answersLog: URL { root.appendingPathComponent("answers.log") }
    /// SPEC §13.2 — one line per Claude suggestion: source, model, duration, outcome. Never
    /// the prompt and never the reply.
    var suggestLog: URL { root.appendingPathComponent("suggest.log") }

    /// `<agent>-<session_id>.token`, the name the reporter writes (SPEC §15.1).
    func tokenFile(agent: SessionAgent, sessionID: String) -> URL {
        tokens.appendingPathComponent("\(agent.name)-\(sessionID).token")
    }

    /// Directories are 700 — a request carries a full command line (SPEC §4).
    @discardableResult
    func ensure(_ directory: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) { return true }
        do {
            try fm.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return true
        } catch {
            return false
        }
    }
}

/// Appends one line to a log file, creating it if need be. Never throws at the call site: a log
/// that cannot be written must not take an answer down with it.
enum LogFile {
    private static let log = Logger(subsystem: "io.github.lukenorgaard.beacon", category: "answers")
    private static let queue = DispatchQueue(label: "io.github.lukenorgaard.beacon.logfile", qos: .utility)

    /// Above this the file is rotated to `<name>.1`, so two append-only logs cannot grow forever.
    static let maxBytes = 512 * 1024

    static func append(_ line: String, to url: URL) {
        queue.async { appendNow(line, to: url) }
    }

    /// Synchronous variant — the tests use it, and so does anything that has to read back what
    /// it just wrote.
    static func appendNow(_ line: String, to url: URL) {
        let stamp = ISO8601.string(Date())
        let text = "\(stamp) \(line)\n"
        guard let data = text.data(using: .utf8) else { return }

        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        rotateIfNeeded(url)

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            return
        }
        try? data.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func rotateIfNeeded(_ url: URL) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
              size.intValue > maxBytes
        else { return }
        let rolled = url.appendingPathExtension("1")
        try? fm.removeItem(at: rolled)
        try? fm.moveItem(at: url, to: rolled)
    }
}

/// `~/.lookout/config.json` — the one file the app writes *for* the reporter (SPEC §11.4).
/// Only `wait_seconds` is ours; every other key already in the file survives untouched, because
/// lane R may well add its own.
enum LookoutConfig {
    static let waitSecondsKey = "wait_seconds"
    static let defaultWaitSeconds = 45
    /// 0 = do not wait at all; the reporter's `PermissionRequest` hook timeout is 120 s, so the
    /// wait has to stay comfortably under it (SPEC §11.3).
    static let waitRange = 0...110

    /// The pure half: merge our key into whatever was already there.
    static func merged(existing: [String: Any], waitSeconds: Int) -> [String: Any] {
        var result = existing
        result[waitSecondsKey] = clamp(waitSeconds)
        return result
    }

    static func clamp(_ seconds: Int) -> Int {
        min(max(seconds, waitRange.lowerBound), waitRange.upperBound)
    }

    static func read(from url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    static func waitSeconds(in url: URL) -> Int? {
        read(from: url)[waitSecondsKey] as? Int
    }

    /// Atomic, and it never destroys a malformed file's neighbours: an unreadable config is
    /// replaced by one that holds our key alone, which is the only recoverable answer.
    @discardableResult
    static func write(waitSeconds: Int, to url: URL) -> Bool {
        let merged = merged(existing: read(from: url), waitSeconds: waitSeconds)
        guard let data = try? JSONSerialization.data(
            withJSONObject: merged, options: [.prettyPrinted, .sortedKeys]
        ) else { return false }

        let directory = url.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let temporary = url.appendingPathExtension("tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            _ = try fm.replaceItemAt(url, withItemAt: temporary)
            return true
        } catch {
            try? fm.removeItem(at: temporary)
            return false
        }
    }
}
