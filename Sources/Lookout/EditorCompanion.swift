import Foundation
import os

/// One live editor window's companion server (SPEC §16.2), as written to
/// `~/.lookout/companion/<app>-<extension host pid>.json`.
///
/// The token is a `SecretToken`, so it cannot be logged or interpolated by accident — it only
/// ever leaves this file inside an `Authorization` header.
struct CompanionInstance: Equatable, Identifiable {
    let app: String
    let pid: Int32
    let port: Int
    let token: SecretToken
    let windowTitle: String?
    let folders: [String]
    let startedAt: Date?
    let version: String?
    /// Where the state file was read from, for diagnostics.
    let file: URL

    var id: String { "\(app)-\(pid)" }

    /// A state file bigger than this is not one of ours and is never read into memory.
    static let maxFileBytes = 64 * 1024

    /// Tolerant, and strict where it matters: the app slug, the port and the token all end up in
    /// a request, so anything that is not plainly well formed is dropped rather than repaired.
    static func decode(json data: Data, file: URL) -> CompanionInstance? {
        guard data.count <= maxFileBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        guard let app = slug(root["app"] as? String),
              let pid = integer(root["pid"]), pid > 0,
              let port = integer(root["port"]), (1...65_535).contains(port),
              let raw = Session.text(root["token"] as? String)
        else { return nil }

        let token = SecretToken(raw)
        guard LocalHTTP.isHeaderSafe(token) else { return nil }

        let folders = ((root["folders"] as? [Any]) ?? [])
            .compactMap { Session.text($0 as? String) }
            .filter { $0.hasPrefix("/") }

        return CompanionInstance(
            app: app,
            pid: Int32(pid),
            port: port,
            token: token,
            windowTitle: Session.text(root["windowTitle"] as? String),
            folders: folders,
            startedAt: Session.text(root["started_at"] as? String).flatMap(ISO8601.date),
            version: Session.text(root["version"] as? String),
            file: file
        )
    }

    /// `cursor`, `devin`, `vscode` — or any other slug the extension invented. Lower case,
    /// ASCII letters, digits and dashes only.
    static func slug(_ raw: String?) -> String? {
        guard let value = Session.text(raw)?.lowercased(), value.count <= 64 else { return nil }
        let allowed = value.allSatisfy { character in
            guard character.isASCII else { return false }
            return character.isLetter || character.isNumber || character == "-"
        }
        return allowed ? value : nil
    }

    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: return number.intValue
        case let text as String: return Int(text)
        default: return nil
        }
    }
}

/// One integrated terminal, as `GET /terminals` reports it (SPEC §16.2).
struct CompanionTerminal: Equatable {
    let index: Int
    let name: String?
    /// The terminal's shell pid — the key everything here matches on. Null when the extension
    /// host could not await it.
    let processId: Int32?
    let cwd: String?
    let isActive: Bool

    static func decode(_ value: Any) -> CompanionTerminal? {
        guard let object = value as? [String: Any] else { return nil }
        let index = (object["index"] as? NSNumber)?.intValue ?? -1
        var pid: Int32?
        if let number = object["processId"] as? NSNumber, number.intValue > 0 {
            pid = Int32(truncatingIfNeeded: number.intValue)
        }
        let creationCwd = (object["creationOptions"] as? [String: Any])?["cwd"] as? String
        return CompanionTerminal(
            index: index,
            name: Session.text(object["name"] as? String),
            processId: pid,
            cwd: Session.text(object["cwd"] as? String) ?? Session.text(creationCwd),
            isActive: (object["isActive"] as? NSNumber)?.boolValue ?? false
        )
    }

    static func decodeList(_ data: Data) -> [CompanionTerminal] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return array.compactMap(CompanionTerminal.decode)
    }
}

/// The terminal a session was resolved to, and which of §16.2's two rules found it.
struct CompanionMatch: Equatable {
    enum Rule: String, Equatable {
        /// `shell_pid` equals the terminal's `processId` — the only exact rule.
        case pid
        /// Exactly one terminal in this app is named after the agent (`claude`, `codex`).
        case name
    }

    let instance: CompanionInstance
    let terminal: CompanionTerminal
    let rule: Rule
}

/// What Jumper, the card and the rename panel need from a companion — the seam their tests stub.
protocol CompanionChannel: AnyObject {
    func match(app: String, shellPid: Int32?, agentCommand: String?) -> CompanionMatch?
    func focus(app: String, shellPid: Int32?, agentCommand: String?) -> CompanionMatch?
    func send(app: String, shellPid: Int32?, agentCommand: String?, text: String) -> CompanionMatch?
    /// True when at least one live companion file exists for that app. No HTTP, no waiting.
    func hasLiveInstance(app: String) -> Bool
}

extension CompanionChannel {
    /// The session-shaped calls. Nil host app → nil, without touching the disk.
    func focus(session: Session) -> CompanionMatch? {
        guard let app = EditorCompanion.app(for: session.host) else { return nil }
        return focus(
            app: app, shellPid: session.shellPid, agentCommand: session.agent.name
        )
    }

    func send(text: String, session: Session) -> CompanionMatch? {
        guard let app = EditorCompanion.app(for: session.host) else { return nil }
        return send(
            app: app, shellPid: session.shellPid, agentCommand: session.agent.name, text: text
        )
    }
}

/// Lookout's half of the editor companion (SPEC §16.3): find the live windows, ask each one for
/// its terminals, and then focus or type into the one this session runs in.
///
/// Everything here does blocking I/O — never call it on the main thread.
final class EditorCompanion: CompanionChannel {
    /// The app-wide client. A `LOOKOUT_HOME` override gets its own, so a test never reads the
    /// real `~/.lookout`.
    static let shared = EditorCompanion()

    static func client(home: LookoutHome) -> EditorCompanion {
        home.isOverridden ? EditorCompanion(home: home) : shared
    }

    /// SPEC §16.3: 2 s for a companion call, the same budget §9.2 gives the whole click path.
    static let timeout: TimeInterval = 2

    private static let log = Logger(subsystem: "io.github.lukenorgaard.beacon", category: "companion")

    typealias Transport = (
        _ instance: CompanionInstance, _ method: String, _ path: String, _ body: Data?
    ) -> LocalHTTP.Outcome

    private let home: LookoutHome
    private let isAlive: (Int32) -> Bool
    private let transport: Transport
    private let lock = NSLock()
    /// Parsed state files, keyed by path — a scan that finds the same file unchanged never
    /// re-reads or re-parses it (SPEC §16.3's "cache per instance").
    private var cache: [String: (modified: Date, size: Int, instance: CompanionInstance)] = [:]

    init(
        home: LookoutHome = LookoutHome(),
        isAlive: @escaping (Int32) -> Bool = EditorCompanion.processIsAlive,
        transport: Transport? = nil
    ) {
        self.home = home
        self.isAlive = isAlive
        self.transport = transport ?? EditorCompanion.httpTransport
    }

    // MARK: - The state files (SPEC §16.2)

    var directory: URL { home.companion }

    /// `kill(pid, 0)` — the liveness test §16.3 names. `EPERM` means the process exists but
    /// belongs to somebody else, which still counts as alive.
    static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Every live companion, newest window first. Dead pids are dropped and forgotten.
    func instances(app: String? = nil) -> [CompanionInstance] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let contents = (try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []

        var found: [CompanionInstance] = []
        var seen = Set<String>()
        for url in contents where url.pathExtension == "json" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let modified = values?.contentModificationDate ?? .distantPast
            let size = values?.fileSize ?? -1
            seen.insert(url.path)

            var instance: CompanionInstance?
            lock.lock()
            if let cached = cache[url.path], cached.modified == modified, cached.size == size {
                instance = cached.instance
            }
            lock.unlock()

            if instance == nil {
                guard let data = try? Data(contentsOf: url),
                      let decoded = CompanionInstance.decode(json: data, file: url)
                else { continue }
                instance = decoded
                lock.lock()
                cache[url.path] = (modified, size, decoded)
                lock.unlock()
            }
            guard let instance else { continue }
            // §16.2: a file whose extension host is gone is stale — the editor crashed, or the
            // window closed before `deactivate` could unlink it.
            guard isAlive(instance.pid) else { continue }
            if let app, instance.app != app { continue }
            found.append(instance)
        }

        lock.lock()
        cache = cache.filter { seen.contains($0.key) }
        lock.unlock()

        return found.sorted { left, right in
            let a = left.startedAt ?? .distantPast
            let b = right.startedAt ?? .distantPast
            if a != b { return a > b }
            return left.pid < right.pid
        }
    }

    func hasLiveInstance(app: String) -> Bool {
        !instances(app: app).isEmpty
    }

    // MARK: - Terminals

    /// The union of every live window's terminals for that app, each tagged with its window.
    func terminals(for app: String) -> [(instance: CompanionInstance, terminal: CompanionTerminal)] {
        var result: [(CompanionInstance, CompanionTerminal)] = []
        for instance in instances(app: app) {
            switch transport(instance, "GET", "/terminals", nil) {
            case .response(let response) where response.status == 200:
                for terminal in CompanionTerminal.decodeList(response.body) {
                    result.append((instance, terminal))
                }
            case .response(let response):
                EditorCompanion.log.notice(
                    "companion \(app, privacy: .public) /terminals -> \(response.status, privacy: .public)"
                )
            case .failure(let failure):
                EditorCompanion.log.notice(
                    "companion \(app, privacy: .public) /terminals failed: \(failure.text, privacy: .public)"
                )
            }
        }
        return result
    }

    // MARK: - Matching (SPEC §16.2)

    /// The rule, pure: the shell pid wins; failing that, exactly one terminal named after the
    /// agent; failing that, nothing — and the caller falls back to the window-only jump.
    static func match(
        shellPid: Int32?,
        agentCommand: String?,
        in terminals: [(instance: CompanionInstance, terminal: CompanionTerminal)]
    ) -> CompanionMatch? {
        if let shellPid, shellPid > 0 {
            for entry in terminals where entry.terminal.processId == shellPid {
                return CompanionMatch(
                    instance: entry.instance, terminal: entry.terminal, rule: .pid
                )
            }
        }
        guard let needle = Session.text(agentCommand)?.lowercased() else { return nil }
        let named = terminals.filter {
            ($0.terminal.name ?? "").lowercased().contains(needle)
        }
        guard named.count == 1, let only = named.first else { return nil }
        return CompanionMatch(instance: only.instance, terminal: only.terminal, rule: .name)
    }

    func match(app: String, shellPid: Int32?, agentCommand: String?) -> CompanionMatch? {
        EditorCompanion.match(
            shellPid: shellPid, agentCommand: agentCommand, in: terminals(for: app)
        )
    }

    // MARK: - Focus and send

    @discardableResult
    func focus(app: String, shellPid: Int32?, agentCommand: String?) -> CompanionMatch? {
        guard let found = match(app: app, shellPid: shellPid, agentCommand: agentCommand)
        else { return nil }
        let body = try? JSONSerialization.data(
            withJSONObject: ["processId": Int(found.terminal.processId ?? 0)]
        )
        return post("/focus", body: body, match: found)
    }

    @discardableResult
    func send(
        app: String, shellPid: Int32?, agentCommand: String?, text: String
    ) -> CompanionMatch? {
        guard let found = match(app: app, shellPid: shellPid, agentCommand: agentCommand)
        else { return nil }
        let body = try? JSONSerialization.data(withJSONObject: [
            "processId": Int(found.terminal.processId ?? 0),
            "text": text,
            "newline": true,
        ])
        return post("/send", body: body, match: found)
    }

    /// A 404 means the terminal disappeared between the listing and the call — no match, so the
    /// caller falls back exactly as if there had never been a companion.
    private func post(_ path: String, body: Data?, match: CompanionMatch) -> CompanionMatch? {
        guard let body else { return nil }
        switch transport(match.instance, "POST", path, body) {
        case .response(let response) where response.status == 200:
            return match
        case .response(let response):
            EditorCompanion.log.notice(
                "companion \(match.instance.app, privacy: .public) \(path, privacy: .public) -> \(response.status, privacy: .public)"
            )
            return nil
        case .failure(let failure):
            EditorCompanion.log.notice(
                "companion \(match.instance.app, privacy: .public) \(path, privacy: .public) failed: \(failure.text, privacy: .public)"
            )
            return nil
        }
    }

    // MARK: - Wiring

    /// The live transport. The token goes into one header and nowhere else.
    static func httpTransport(
        instance: CompanionInstance, method: String, path: String, body: Data?
    ) -> LocalHTTP.Outcome {
        LocalHTTP.request(
            port: instance.port, method: method, path: path, token: instance.token,
            body: body, timeout: EditorCompanion.timeout
        )
    }

    /// The three hosts §16.3 covers, and the slug the extension writes for each.
    static func app(for host: SessionHost) -> String? {
        switch host {
        case .cursor: return "cursor"
        case .devin: return "devin"
        case .vscode: return "vscode"
        default: return nil
        }
    }

    static func host(for app: String) -> SessionHost? {
        switch app {
        case "cursor": return .cursor
        case "devin": return .devin
        case "vscode": return .vscode
        default: return nil
        }
    }
}
