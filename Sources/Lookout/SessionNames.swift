import Combine
import Foundation
import os

/// SPEC §15.4: the names the owner gives sessions, kept in `~/.lookout/names.json` (or under
/// `LOOKOUT_HOME`, exactly as every other file the app owns).
///
/// ```json
/// { "names": { "<session_id>": "Nova v2 mobil" },
///   "seen":  { "<session_id>": "2026-09-03T08:12:00Z" } }
/// ```
///
/// The `seen` half is what makes pruning possible: a name whose session has not been reported
/// for 30 days is dropped, so the file cannot grow forever on a machine that starts a session a
/// minute. `names` is `@Published`, so a rename lands in the rows on the next frame — nothing
/// reloads anything.
///
/// Writes are atomic (temp + `replaceItemAt`) and the file is 0600: a session name is the owner's
/// own text about his own work.
final class SessionNames: ObservableObject {
    /// The custom name per session id. Read by `decorate`, written by `setName`.
    @Published private(set) var names: [String: String] = [:]
    /// When each *named* session was last seen alive. Ids without a name are never stamped —
    /// the stamp exists only to date the name.
    private(set) var seen: [String: Date] = [:]

    /// Ids seen this run and the pid behind them. In memory only: a pid means nothing after a
    /// reboot, and this exists for one job — following a rename across the id change that
    /// happens when a hook file replaces a discovered row (SPEC §9.1, §15.4).
    private var pids: [String: Int32] = [:]

    let url: URL

    private let log = Logger(subsystem: "io.github.lukenorgaard.beacon", category: "names")

    /// SPEC §15.4: gone for 30 days, and the name goes with it.
    static let pruneAfter: TimeInterval = 30 * 24 * 60 * 60
    /// A stamp is only rewritten when it is this stale, so a 5 s refresh does not rewrite the
    /// file 720 times an hour.
    static let seenResolution: TimeInterval = 60 * 60
    /// A defensive cap. A row shows ~90 characters; nothing sane needs more than this stored.
    static let nameLimit = 120

    init(home: LookoutHome = LookoutHome(), loadsNow: Bool = true) {
        url = home.names
        if loadsNow { load() }
    }

    /// Test seam: point straight at a file.
    init(url: URL, loadsNow: Bool = true) {
        self.url = url
        if loadsNow { load() }
    }

    // MARK: - Reading

    func name(for id: String) -> String? { Session.text(names[id]) }

    var isEmpty: Bool { names.isEmpty }

    /// Puts the custom name onto a session, so everything downstream — rows, the card, the
    /// notification, the Agents tab — reads one property and nothing has to know this store
    /// exists.
    func decorate(_ session: Session) -> Session {
        guard let name = Session.text(names[session.sessionID]) else { return session }
        var copy = session
        copy.customName = name
        return copy
    }

    func decorate(_ sessions: [Session]) -> [Session] {
        guard !names.isEmpty else { return sessions }
        return sessions.map(decorate)
    }

    // MARK: - Writing

    /// The whole of Rename…: a name to set, or nil/blank to remove the override (SPEC §15.4).
    /// Returns true when anything changed.
    @discardableResult
    func setName(_ raw: String?, for id: String, now: Date = Date()) -> Bool {
        guard !id.isEmpty else { return false }
        let wanted = Session.text(raw).map { String($0.prefix(SessionNames.nameLimit)) }

        var next = names
        if let wanted {
            guard next[id] != wanted else { return false }
            next[id] = wanted
            seen[id] = now
        } else {
            guard next[id] != nil else { return false }
            next.removeValue(forKey: id)
            seen.removeValue(forKey: id)
        }
        names = next
        persist()
        return true
    }

    /// Every refresh: carry names across a pid merge, keep the stamps fresh, prune what is 30
    /// days gone. One `names` assignment at the end, so a refresh publishes at most once.
    func observe(_ sessions: [Session], now: Date = Date()) {
        var next = names
        var stamps = seen
        var changed = false

        // SPEC §15.4: a discovered row the owner renamed, then replaced by a hook file for the same
        // pid, keeps its name — stored under the new id too, so the old one may expire quietly.
        for move in SessionNames.carryOvers(pids: pids, names: next, sessions: sessions) {
            guard let name = next[move.from] else { continue }
            next[move.to] = name
            stamps[move.to] = now
            changed = true
        }

        for session in sessions {
            guard let pid = session.pid, pid > 0 else { continue }
            pids[session.sessionID] = pid
        }

        for session in sessions where next[session.sessionID] != nil {
            let last = stamps[session.sessionID]
            if last == nil || now.timeIntervalSince(last!) > SessionNames.seenResolution {
                stamps[session.sessionID] = now
                changed = true
            }
        }

        if SessionNames.prune(names: &next, seen: &stamps, now: now) { changed = true }

        guard changed else { return }
        seen = stamps
        if next != names { names = next } else { objectWillChange.send() }
        persist()
    }

    /// SPEC §15.4's 30 days, as a pure function so the test does not have to wait a month.
    @discardableResult
    static func prune(
        names: inout [String: String], seen: inout [String: Date], now: Date = Date()
    ) -> Bool {
        var changed = false
        for id in names.keys.sorted() {
            let last = seen[id] ?? now
            guard now.timeIntervalSince(last) > pruneAfter else { continue }
            names.removeValue(forKey: id)
            seen.removeValue(forKey: id)
            changed = true
        }
        // A stamp whose name is gone is dead weight.
        for id in seen.keys.sorted() where names[id] == nil {
            seen.removeValue(forKey: id)
            changed = true
        }
        return changed
    }

    /// Which renames have to follow a row whose session id changed. A discovered row carries an
    /// invented id until the hooks report the real one; the pid is the only thing that is the
    /// same on both sides of that swap (SPEC §9.1).
    static func carryOvers(
        pids: [String: Int32], names: [String: String], sessions: [Session]
    ) -> [(from: String, to: String)] {
        guard !names.isEmpty else { return [] }
        var byPID: [Int32: [String]] = [:]
        for (id, pid) in pids where names[id] != nil { byPID[pid, default: []].append(id) }
        guard !byPID.isEmpty else { return [] }

        var result: [(from: String, to: String)] = []
        for session in sessions {
            guard let pid = session.pid, pid > 0 else { continue }
            guard names[session.sessionID] == nil else { continue }
            guard let candidates = byPID[pid] else { continue }
            guard let from = candidates.filter({ $0 != session.sessionID }).sorted().first
            else { continue }
            result.append((from: from, to: session.sessionID))
        }
        return result.sorted { $0.to < $1.to }
    }

    // MARK: - Disk

    /// Tolerant on purpose: the `{ "names": …, "seen": … }` shape this writes, and the flat
    /// `{ "<id>": "name" }` SPEC §15.4 spells out first, both load.
    func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.error("Unreadable names file at \(self.url.path, privacy: .public)")
            return
        }

        var loaded: [String: String] = [:]
        var stamps: [String: Date] = [:]
        if let nested = object["names"] as? [String: Any] {
            for (id, value) in nested { if let text = value as? String { loaded[id] = text } }
            if let raw = object["seen"] as? [String: Any] {
                for (id, value) in raw {
                    if let text = value as? String, let date = ISO8601.date(text) {
                        stamps[id] = date
                    }
                }
            }
        } else {
            for (id, value) in object { if let text = value as? String { loaded[id] = text } }
        }

        var changed = false
        // A name with no stamp starts its 30 days now rather than being pruned on sight.
        for id in loaded.keys.sorted() where stamps[id] == nil {
            stamps[id] = Date()
            changed = true
        }
        for id in stamps.keys.sorted() where loaded[id] == nil {
            stamps.removeValue(forKey: id)
            changed = true
        }
        if SessionNames.prune(names: &loaded, seen: &stamps, now: Date()) { changed = true }

        names = loaded
        seen = stamps
        if changed { persist() }
    }

    @discardableResult
    func persist() -> Bool {
        let fm = FileManager.default
        // Never bring the file into existence just to say there is nothing in it.
        if names.isEmpty, !fm.fileExists(atPath: url.path) { return true }

        let payload: [String: Any] = [
            "names": names,
            "seen": seen.mapValues(ISO8601.string),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        ) else { return false }

        let directory = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let temporary = url.appendingPathExtension("tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: temporary)
            } else {
                try fm.moveItem(at: temporary, to: url)
            }
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            try? fm.removeItem(at: temporary)
            log.error("Could not write names.json: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
