import Foundation
import os

/// The periodic liveness tick's pace: 5 s while something is actually moving, 15 s once it is
/// quiet (task: process-scan cost). A file-system event on the sessions directory always forces
/// an immediate scan regardless of this — that path is `SessionStore.directoryChanged()`, unchanged
/// — this only governs how often the *unprompted* tick re-scans on its own.
///
/// Pure and stateless on purpose, so the decision is testable without a real timer.
enum ScanCadence {
    static let active: TimeInterval = 5
    static let idle: TimeInterval = 15
    /// How long a session-file change keeps the tick fast, even with no candidate churn.
    static let quietWindow: TimeInterval = 30

    static func interval(candidatesChanged: Bool, secondsSinceFileChange: TimeInterval?) -> TimeInterval {
        if candidatesChanged { return active }
        if let secondsSinceFileChange, secondsSinceFileChange <= quietWindow { return active }
        return idle
    }
}

/// Reads `~/.lookout/sessions/*.json` and keeps the live picture of every agent.
///
/// One `DispatchSource` directory watcher (debounced 100 ms) plus a liveness tick — the tick
/// prunes dead sessions and, when enabled, runs the process scan (SPEC §5.6, §8.2). The tick's own
/// pace adapts (`ScanCadence`): 5 s while the scan's candidate pids are moving or a session file
/// changed recently, 15 s once things are quiet. Nothing here ever touches the main thread except
/// the final publish.
final class SessionStore: ObservableObject {
    /// Merged and sorted: state files first, then anything the process scan found.
    @Published private(set) var sessions: [Session] = []
    /// The newest Codex rate limits seen in a live rollout (SPEC §17.7 without hooks) — read by
    /// `AppState.refreshCodexUsage()` alongside the reporter's `codex-usage.json`.
    @Published private(set) var rolloutUsage: CodexUsageSnapshot?

    /// Called for every state change, with the state the session was in before (nil = first sight).
    /// Not called for the initial load, so launching Lookout does not replay old notifications.
    var onTransition: ((Session, SessionState?) -> Void)?

    let directory: URL
    /// True when `LOOKOUT_HOME` points somewhere else — fixtures must never be deleted.
    let isOverridden: Bool

    private let log = Logger(subsystem: "io.github.lukenorgaard.beacon", category: "sessions")
    private let queue = DispatchQueue(label: "io.github.lukenorgaard.beacon.sessions", qos: .utility)
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private var ticker: DispatchSourceTimer?
    private var debounce: DispatchWorkItem?
    private var previousStates: [String: SessionState] = [:]
    private var seededTransitions = false
    private let scanner = ProcessScanRunner()
    private let rolloutCache = CodexRolloutCache()
    private var prunes: Bool

    /// Adaptive-cadence state (`ScanCadence`), queue-confined like everything else here.
    private var lastCandidatePIDs: Set<Int32> = []
    private var lastRolloutIDs: Set<String> = []
    private var candidatesChangedLastScan = false
    private var lastFileChangeAt: Date?

    /// Mirrors of the two Settings values the background work needs, kept as plain values so the
    /// scan never reaches back into a main-thread object.
    private var discoveryEnabled = true
    private var agentCommands = ProcessScanner.defaultCommands

    /// Files older than this with no live pid behind them are gone (SPEC §4).
    private static let staleAfter: TimeInterval = 24 * 60 * 60

    init(home: URL? = nil) {
        let environment = ProcessInfo.processInfo.environment
        if let home {
            directory = home.appendingPathComponent("sessions", isDirectory: true)
            isOverridden = true
        } else if let override = environment["LOOKOUT_HOME"], !override.isEmpty {
            directory = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
                .appendingPathComponent("sessions", isDirectory: true)
            isOverridden = true
        } else {
            directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".lookout/sessions", isDirectory: true)
            isOverridden = false
        }
        prunes = !isOverridden || environment["LOOKOUT_PRUNE"] == "1"
    }

    deinit {
        watcher?.cancel()
        ticker?.cancel()
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            self?.installWatcher()
            self?.refresh()
        }
        startTicker()
    }

    func apply(discovery: Bool, agentCommands: [String]) {
        queue.async { [weak self] in
            guard let self else { return }
            let changed = self.discoveryEnabled != discovery || self.agentCommands != agentCommands
            self.discoveryEnabled = discovery
            self.agentCommands = agentCommands
            if changed { self.refresh() }
        }
    }

    /// Ask for an immediate re-read (used after a jump marks a row seen).
    func reload() {
        queue.async { [weak self] in self?.refresh() }
    }

    private func startTicker() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.watchedFD < 0 { self.installWatcher() }
            self.refresh()
            self.rescheduleTicker()
        }
        timer.schedule(deadline: .now() + ScanCadence.active, leeway: .seconds(1))
        timer.resume()
        ticker = timer
    }

    /// Re-arms the same timer source for its next firing at the cadence `refresh()` just decided.
    /// Deliberately reads `self.ticker` rather than capturing the local `timer` from
    /// `startTicker()` — capturing a `DispatchSourceTimer` inside its own event handler is a
    /// classic retain cycle (the handler is owned by the timer, so the timer would keep itself
    /// alive forever).
    private func rescheduleTicker() {
        guard let timer = ticker else { return }
        let secondsSinceFileChange = lastFileChangeAt.map { Date().timeIntervalSince($0) }
        let interval = ScanCadence.interval(
            candidatesChanged: candidatesChangedLastScan,
            secondsSinceFileChange: secondsSinceFileChange
        )
        timer.schedule(deadline: .now() + interval, leeway: .seconds(1))
    }

    private func installWatcher() {
        guard watchedFD < 0 else { return }
        guard FileManager.default.fileExists(atPath: directory.path) else { return }

        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.directoryChanged() }
        source.setCancelHandler { [weak self] in
            close(fd)
            self?.watchedFD = -1
        }
        source.resume()
        watcher = source
        watchedFD = fd
    }

    /// The reporter writes `.tmp` then renames, so a burst of events is normal — coalesce them.
    /// Always triggers an immediate (debounced) scan, independent of the ticker's own cadence, so
    /// a hook-driven session still appears right away even while the tick has backed off to 15 s.
    private func directoryChanged() {
        lastFileChangeAt = Date()
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    // MARK: - Reading

    private func refresh() {
        let fileSessions = loadFiles()
        var merged = fileSessions

        if discoveryEnabled {
            let covered = Set(fileSessions.compactMap(\.pid))
            let discovered = scanner.scan(coveredPIDs: covered, agentCommands: agentCommands)
            // Codex Desktop sessions have no process to scan for and, without trusted hooks, no
            // state file either; their own rollout files are the third source. Same merge rule:
            // a state file for the id wins.
            let rollouts = CodexRolloutDiscovery.discover(cache: rolloutCache)
            // A discovered row now carries the real session id, so the file has to win on id
            // as well as on pid (SPEC §9.1).
            merged = CodexDiscoveryMerge.merge(
                files: fileSessions, processes: discovered, rollouts: rollouts.sessions
            )

            // Feeds `ScanCadence`: the tick stays fast while the set of discovered agent pids (or
            // live rollouts) is still changing, and backs off once it has been stable for a scan.
            let candidatePIDs = Set(discovered.compactMap(\.pid))
            let rolloutIDs = Set(rollouts.sessions.map(\.sessionID))
            candidatesChangedLastScan = candidatePIDs != lastCandidatePIDs || rolloutIDs != lastRolloutIDs
            if rolloutIDs != lastRolloutIDs {
                log.notice("rollout discovery: \(rolloutIDs.count, privacy: .public) live Codex session(s) without hooks")
            }
            lastCandidatePIDs = candidatePIDs
            lastRolloutIDs = rolloutIDs
            let usage = rollouts.usage
            DispatchQueue.main.async { [weak self] in
                guard let self, self.rolloutUsage != usage else { return }
                self.rolloutUsage = usage
            }
        } else {
            candidatesChangedLastScan = false
            rolloutCache.retain(paths: [])
        }

        let sorted = Session.sorted(merged)
        let transitions = self.transitions(for: sorted)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.sessions != sorted { self.sessions = sorted }
            for (session, previous) in transitions {
                self.onTransition?(session, previous)
            }
        }
    }

    private func transitions(for sessions: [Session]) -> [(Session, SessionState?)] {
        var result: [(Session, SessionState?)] = []
        var next: [String: SessionState] = [:]
        for session in sessions {
            next[session.id] = session.state
            let previous = previousStates[session.id]
            if previous != session.state, seededTransitions {
                result.append((session, previous))
            }
        }
        previousStates = next
        seededTransitions = true
        return result
    }

    private func loadFiles() -> [Session] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }

        let decoder = JSONDecoder()
        var result: [Session] = []
        result.reserveCapacity(names.count)

        for name in names where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let session = try? decoder.decode(Session.self, from: data) else {
                log.error("Unreadable session file \(name, privacy: .public)")
                continue
            }
            if isDead(session) {
                if prunes {
                    try? fm.removeItem(at: url)
                    continue
                }
                if !isOverridden { continue }
            }
            result.append(session)
        }
        return result
    }

    /// SPEC §4: no live pid, or nothing has touched the file in 24 hours.
    private func isDead(_ session: Session) -> Bool {
        if let pid = session.pid, pid > 0, !SessionStore.isAlive(pid) { return true }
        if let updated = session.updatedAt,
           Date().timeIntervalSince(updated) > SessionStore.staleAfter {
            return true
        }
        return false
    }

    /// `kill(pid, 0)`: ESRCH means gone, EPERM means alive but not ours.
    static func isAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
