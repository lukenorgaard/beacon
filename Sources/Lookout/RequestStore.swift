import Foundation
import os

/// Reads `~/.lookout/requests/*.json` — the open permission and question requests the reporter
/// wrote (SPEC §11.3) — with exactly the pattern `SessionStore` uses: one `DispatchSource`
/// directory watcher debounced 100 ms, plus a 5 s tick (SPEC §5.6).
///
/// It only ever reads. Answering writes a file under `answers/`, and the *reporter* deletes the
/// request once it has been served.
final class RequestStore: ObservableObject {
    @Published private(set) var requests: [AttentionRequest] = []

    let home: LookoutHome
    var directory: URL { home.requests }

    private let log = Logger(subsystem: "io.github.lukenorgaard.beacon", category: "requests")
    private let queue = DispatchQueue(label: "io.github.lukenorgaard.beacon.requests", qos: .utility)
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private var ticker: DispatchSourceTimer?
    private var debounce: DispatchWorkItem?

    /// A request created this long ago is not worth showing any more, whatever kind it is
    /// (bug fix 2026-09-04: a `question` never carries `waits_until`, so age has to be judged
    /// from `created_at` for it to mean anything — the same clock a stale permission is already
    /// judged by).
    static let staleAfter: TimeInterval = 60 * 60

    /// Files older than this — or whose session has no state file at all any more — are not
    /// just hidden, they are deleted (`pruneOrphans`, bug fix 2026-09-04): the reporter only
    /// ever removes the *one* file it currently references, so an interrupted run leaves the
    /// rest behind indefinitely otherwise (SPEC §11.3).
    static let orphanAfter: TimeInterval = 6 * 60 * 60

    init(home: LookoutHome = LookoutHome()) {
        self.home = home
    }

    deinit {
        watcher?.cancel()
        ticker?.cancel()
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            // The reporter creates this on its first request; making it here means the watcher
            // can be installed at launch instead of five seconds later.
            self.home.ensure(self.directory)
            self.installWatcher()
            self.refresh()
        }
        startTicker()
    }

    func reload() {
        queue.async { [weak self] in self?.refresh() }
    }

    /// The newest open request for a session, which is the one the card is about.
    func request(for sessionID: String) -> AttentionRequest? {
        requests
            .filter { $0.sessionID == sessionID }
            .max { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    /// The request that actually belongs on `session`'s card right now (bug fix 2026-09-04).
    ///
    /// `request(for sessionID:)` above answers "what is the newest request file for this
    /// session id" — which is exactly how a six-hour-old `AskUserQuestion` ended up back on a
    /// card for a session that had long since finished: the reporter only deletes the *one*
    /// file it currently references, so an orphan from an earlier turn sits right next to the
    /// live one, newer by file time alone.
    ///
    /// The session's own state file is the source of truth instead: a request counts only when
    /// the session still points at it by id (`session.requestID == request.requestID`) *and*
    /// the session is still `needs_you` — a `done` or `working` session never shows a question
    /// or a permission request again, however recently the file itself was touched. `now` is a
    /// seam for tests.
    func request(for session: Session, now: Date = Date()) -> AttentionRequest? {
        guard session.state == .needsYou else { return nil }
        guard let wanted = Session.text(session.requestID) else { return nil }
        guard let match = requests.first(where: {
            $0.sessionID == session.sessionID && $0.requestID == wanted
        }) else { return nil }
        if let created = match.createdAt, now.timeIntervalSince(created) > RequestStore.staleAfter {
            return nil
        }
        return match
    }

    // MARK: - Watching

    private func startTicker() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.watchedFD < 0 { self.installWatcher() }
            self.refresh()
        }
        timer.resume()
        ticker = timer
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

    private func directoryChanged() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func refresh() {
        let loaded = load()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.requests != loaded { self.requests = loaded }
        }
    }

    private func load() -> [AttentionRequest] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }

        let now = Date()
        var result: [AttentionRequest] = []
        result.reserveCapacity(names.count)
        for name in names where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }
            let stem = String(name.dropLast(".json".count))
            guard let request = AttentionRequest.decode(data, name: stem) else {
                log.error("Unreadable request file \(name, privacy: .public)")
                continue
            }
            // Bug fix 2026-09-04: judged by `created_at`, not `waits_until` — a permission
            // request has both (they land within `wait_seconds` of each other), but a question
            // never carries `waits_until` at all, which used to mean it never went stale here.
            if let created = request.createdAt,
               now.timeIntervalSince(created) > RequestStore.staleAfter {
                continue
            }
            result.append(request)
        }
        return result.sorted { left, right in
            let a = left.createdAt ?? .distantPast
            let b = right.createdAt ?? .distantPast
            if a != b { return a > b }
            return left.id < right.id
        }
    }

    // MARK: - Garbage collection (bug fix 2026-09-04)

    /// Deletes request files nobody is ever going to answer: one older than `orphanAfter`, or
    /// one whose session has no state file at all any more (the session ended, or never really
    /// matched a live one). `AppState` calls this off the main thread whenever it re-reads the
    /// session list — the same cadence real sessions refresh at — so an orphan the reporter
    /// forgot to clean up cannot sit around forever the way the six-hour-old question that
    /// caused this fix did.
    ///
    /// Deliberately narrow: it only ever lists and removes files directly under `directory`
    /// (`~/.lookout/requests`, or a test's temp home) and only ever *reads* `home.sessions` to
    /// check a file exists — nothing else on disk is touched. `now` is a seam for tests.
    @discardableResult
    func pruneOrphans(now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return 0 }

        var removed = 0
        for name in names where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }
            let stem = String(name.dropLast(".json".count))
            // A file this store cannot even decode is left alone rather than guessed at — the
            // same caution `load()` already takes.
            guard let request = AttentionRequest.decode(data, name: stem) else { continue }

            var orphaned = false
            if let created = request.createdAt,
               now.timeIntervalSince(created) > RequestStore.orphanAfter {
                orphaned = true
            }
            if !orphaned {
                let sessionFile = home.sessions.appendingPathComponent(
                    "\(request.agent.name)-\(request.sessionID).json"
                )
                if !fm.fileExists(atPath: sessionFile.path) { orphaned = true }
            }
            guard orphaned else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}
