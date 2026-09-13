import Foundation

/// Bug fix (2026-09-04): Codex asks a question in its TUI ("Action Required" —
/// `request_user_input`), but nothing hooks that moment — there is no AskUserQuestion-equivalent
/// event for Codex (SPEC §17.7's own research), so the session sits reporting whatever it was
/// doing before ("Working · Bash") while the user waits on a prompt Lookout never mentions. The
/// question only ever shows up in the session's own rollout file
/// (`~/.codex/sessions/…/rollout-<ts>-<uuid>.jsonl`, the state file's `transcript_path`), as a
/// `function_call` named `request_user_input`, answered later by a `function_call_output` with
/// the same `call_id`.
///
/// Three pieces, in this one file because they only ever make sense together: `CodexQuestion`
/// (the pure parser), `CodexQuestionDecoration` (the pure `AppState.apply()` rule, exactly the
/// shape `StaleBackground` already uses), and `CodexQuestionWatcher` (the timer that keeps the
/// parser's answer fresh for every open Codex session, off the main thread).

// MARK: - CodexQuestion (pure parser)

/// One open `request_user_input` call — what `CodexQuestion.parse(tailData:)` found, and what
/// `CodexQuestionDecoration` and the card both read.
struct CodexQuestion: Equatable {
    /// One question inside the call's `questions` array — Codex can ask several at once.
    struct Question: Equatable {
        var id: String
        var header: String?
        var question: String
        /// Labels only (SPEC: "options:[label]") — a free-text question carries none.
        var options: [String]
    }

    var callID: String
    var questions: [Question]
    /// The call's own `timestamp`, when the line carried one.
    var askedAt: Date?

    /// What `CodexQuestionDecoration` puts in `Session.detail`, and what the card's single-
    /// question layout falls back to.
    var firstQuestionText: String? { questions.first?.question }

    /// The parser's own tail-read cap: enough room for even a long multi-question call while
    /// keeping every look a bounded read, never a full-file scan.
    static let tailBytes = 256 * 1024

    /// Finds the newest `request_user_input` function_call in `tailData` and returns the open
    /// question it represents — nil when there is none, or the newest one already has a
    /// `function_call_output` for the same `call_id` (SPEC's own definition of "open").
    ///
    /// Pure and forgiving like the rest of the app's decoders (`Session`, `AttentionRequest`):
    /// `tailData` is the last ≤256 KB of a rollout file, which — because it was not necessarily
    /// read from the start of a line — may open on a partial line, and its very last line may be
    /// mid-write. Both are handled the same way: a line that fails to decode as one of the two
    /// known shapes is simply skipped, never treated as an error. Lines are read in file order;
    /// "newest" is whichever `request_user_input` call is seen last, so an unrelated later
    /// `function_call` (any other tool) changes nothing.
    static func parse(tailData: Data) -> CodexQuestion? {
        guard !tailData.isEmpty else { return nil }
        let decoder = JSONDecoder()
        var latest: CodexQuestion?
        var answeredCallIDs: Set<String> = []

        for lineData in tailData.split(separator: UInt8(ascii: "\n")) {
            guard !lineData.isEmpty else { continue }
            guard let line = try? decoder.decode(RolloutLine.self, from: lineData),
                  line.type == "response_item", let payload = line.payload
            else { continue }

            switch payload.type {
            case "function_call_output":
                if let callID = payload.callID { answeredCallIDs.insert(callID) }
            case "function_call":
                guard payload.name == "request_user_input",
                      let callID = payload.callID,
                      let argumentsData = payload.arguments?.data(using: .utf8),
                      let arguments = try? decoder.decode(
                        RequestUserInputArgs.self, from: argumentsData
                      )
                else { continue }
                let questions: [Question] = arguments.questions.compactMap { arg in
                    guard let text = Session.text(arg.question) else { return nil }
                    let options = (arg.options ?? []).compactMap { Session.text($0.label) }
                    return Question(
                        id: Session.text(arg.id) ?? callID,
                        header: Session.text(arg.header),
                        question: text,
                        options: options
                    )
                }
                guard !questions.isEmpty else { continue }
                latest = CodexQuestion(
                    callID: callID, questions: questions,
                    askedAt: line.timestamp.flatMap(ISO8601.date)
                )
            default:
                continue
            }
        }

        guard let latest, !answeredCallIDs.contains(latest.callID) else { return nil }
        return latest
    }
}

/// One `response_item` line, just enough of it to tell a question call from its answer.
private struct RolloutLine: Decodable {
    let timestamp: String?
    let type: String?
    let payload: Payload?

    struct Payload: Decodable {
        let type: String?
        let name: String?
        let callID: String?
        /// A JSON *string* (SPEC: `arguments` is not a nested object) — decoded a second time.
        let arguments: String?

        enum CodingKeys: String, CodingKey {
            case type, name, arguments
            case callID = "call_id"
        }
    }
}

/// The decoded `arguments` string of a `request_user_input` call.
private struct RequestUserInputArgs: Decodable {
    let questions: [QuestionArg]
}

private struct QuestionArg: Decodable {
    let id: String?
    let header: String?
    let question: String?
    let options: [OptionArg]?
}

private struct OptionArg: Decodable {
    let label: String?
    let description: String?
}

extension CodexQuestion {
    /// The in-memory `AttentionRequest` the card falls back to for this question (item 3) —
    /// never written to `~/.lookout/requests`, so it exists only in memory for as long as the
    /// watcher keeps finding the same open call. `AttentionCardWindow.sync()` only ever reaches
    /// for this once `RequestStore` — a real, hook-driven request — has nothing for the session,
    /// which is what makes "a hook-driven request always wins" true without either side having
    /// to know about the other.
    func attentionRequest(session: Session) -> AttentionRequest {
        var request = AttentionRequest()
        request.agent = session.agent
        request.sessionID = session.sessionID
        request.requestID = callID
        request.kind = .question
        request.question = questions.first?.question
        request.options = questions.first?.options ?? []
        request.cwd = session.cwd
        request.createdAt = askedAt
        request.name = "codex-question-\(session.sessionID)-\(callID)"
        request.isCodexQuestion = true
        request.codexQuestions = questions
        return request
    }
}

// MARK: - Decoration (AppState.apply(), pure rule — StaleBackground's own shape)

/// Decorates a Codex session with an open question as `needs_you`/`question`, exactly the shape
/// the reporter already writes for a Claude `AskUserQuestion` (SPEC: `reason == "question"` is
/// what `statusLabel`, `NotificationCategory.of` and the Suggester already key off). A pure
/// function of a session plus what the watcher currently knows, decorating the copy `AppState`
/// hands everywhere downstream — sort, the header/status counts, the notification and the card
/// all read `Session.state`/`.reason`/`.detail` alone, so nothing else needs to know this rule
/// exists (mirrors `StaleBackground.decorate`).
enum CodexQuestionDecoration {
    static let reason = "question"

    /// The row/notification only have room for the first question, truncated the way every other
    /// short field on `Session` is (`Session.truncate`'s own ellipsis).
    static let detailLimit = 120

    /// Never overrides a hook-driven `needs_you` — a permission already on screen wins outright,
    /// and `CodexQuestionWatcher` itself never even bothers checking a session in that state
    /// (its own cheap-skip rule), so `questions` would not carry an entry for it anyway.
    static func decorate(_ session: Session, questions: [String: CodexQuestion]) -> Session {
        guard session.agent == .codex, session.state != .needsYou else { return session }
        guard let question = questions[session.sessionID],
              let text = question.firstQuestionText
        else { return session }
        var decorated = session
        decorated.state = .needsYou
        decorated.reason = reason
        decorated.detail = Session.truncate(text, to: detailLimit)
        return decorated
    }
}

// MARK: - Watching rollout files

/// One Codex session worth checking, and everything the watcher needs to decide whether it is
/// worth checking at all — built by `AppState.apply()` from the plain, hook-driven session list
/// (never the decorated one — see `isNeedsYouByHook`'s own doc comment).
struct CodexQuestionCandidate: Equatable {
    var sessionID: String
    var transcriptPath: String
    /// The *hook-driven* state, before `CodexQuestionDecoration` (or anything else) touches it.
    /// Using the decorated state here would mean a session this rule just turned `needs_you`
    /// looks "already needs_you" on the very next look and is skipped forever — the watcher would
    /// blind itself to its own answer and never notice the question got answered.
    var isNeedsYouByHook: Bool
}

/// A plain size+mtime pair — what `CodexQuestionCheck.run` compares against the last look to
/// decide a tail read is worth its cost. A struct of its own (not just "call `stat`") so a test
/// can inject one without touching a real file (SPEC: "inject a clock/file stat").
struct CodexRolloutStat: Equatable {
    var size: UInt64
    var modified: Date
}

/// What one look at a file produced: the stat it was taken at (so the *next* look can tell
/// whether anything moved) and the question that was open then, if any.
struct CodexRolloutLook: Equatable {
    var stat: CodexRolloutStat
    var question: CodexQuestion?
}

/// The pure per-cycle check `CodexQuestionWatcher`'s timer runs, factored out so a test can drive
/// it directly — no timer, no queue, no real files required: `statter`/`tailReader` are plain
/// closures, exactly the seam-per-side-effect style `AttentionCardModel`'s `sender`/`jumper`
/// already use.
enum CodexQuestionCheck {
    /// One pass over `candidates`: a hook-`needs_you` candidate is skipped outright (cheap); every
    /// other one is `stat`-ed, and only actually tail-read and re-parsed when its stat differs
    /// from `cache`'s last look at it — "skip files whose size+mtime are unchanged since the last
    /// look". Returns the cache to hand back in on the *next* call, and the questions currently
    /// open (for every candidate `CodexQuestionWatcher` publishes, whether freshly read or reused
    /// from cache).
    static func run(
        candidates: [CodexQuestionCandidate],
        cache: [String: CodexRolloutLook],
        tailBytes: Int = CodexQuestion.tailBytes,
        statter: (String) -> CodexRolloutStat?,
        tailReader: (String, Int) -> Data?
    ) -> (cache: [String: CodexRolloutLook], questions: [String: CodexQuestion]) {
        // A candidate that left the set entirely (session ended, or is no longer Codex) drops
        // out of the cache too — everything still a candidate keeps its last look, whether or
        // not this pass touches it.
        let liveIDs = Set(candidates.map(\.sessionID))
        var nextCache = cache.filter { liveIDs.contains($0.key) }
        var questions: [String: CodexQuestion] = [:]

        for candidate in candidates {
            // The cheap skip: a session the hook already marked needs_you needs no question
            // decoration (a permission already wins), so its file is not even stat-ed this cycle.
            // Its cache entry, if any, is left exactly as it was for when the hook state clears.
            guard !candidate.isNeedsYouByHook else { continue }

            guard let stat = statter(candidate.transcriptPath) else {
                nextCache.removeValue(forKey: candidate.sessionID)
                continue
            }
            if let cached = nextCache[candidate.sessionID], cached.stat == stat {
                if let question = cached.question { questions[candidate.sessionID] = question }
                continue
            }
            let question = tailReader(candidate.transcriptPath, tailBytes)
                .flatMap(CodexQuestion.parse)
            nextCache[candidate.sessionID] = CodexRolloutLook(stat: stat, question: question)
            if let question { questions[candidate.sessionID] = question }
        }

        return (nextCache, questions)
    }
}

/// Runs `CodexQuestionCheck.run` on a timer of its own, off the main thread, and publishes the
/// result — the live wrapper around the pure pieces above. `AppState` feeds it the candidate list
/// on every session refresh (`observe`, cheap — just replaces an array) and the timer does the
/// actual file work independently, exactly the split `RequestStore` already uses between its
/// directory watcher and its own 5 s tick.
final class CodexQuestionWatcher: ObservableObject {
    @Published private(set) var questions: [String: CodexQuestion] = [:]

    /// Seam for tests: the default reads a real file; a test can substitute values that never
    /// touch disk, or that pretend a file "changed" (or did not) without rewriting it.
    var statter: (String) -> CodexRolloutStat?
    var tailReader: (String, Int) -> Data?

    private let queue = DispatchQueue(label: "io.github.lukenorgaard.beacon.codex-question", qos: .utility)
    private var ticker: DispatchSourceTimer?
    private var candidates: [CodexQuestionCandidate] = []
    private var cache: [String: CodexRolloutLook] = [:]
    private let interval: TimeInterval
    private let tailBytes: Int

    init(interval: TimeInterval = 5, tailBytes: Int = CodexQuestion.tailBytes) {
        self.interval = interval
        self.tailBytes = tailBytes
        self.statter = CodexQuestionWatcher.defaultStatter
        self.tailReader = CodexQuestionWatcher.defaultTailReader
    }

    deinit {
        ticker?.cancel()
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        ticker = timer
    }

    /// Test seam: publishes `questions` directly, bypassing the timer entirely — for a headless
    /// test that wants `AppState.apply()`'s decoration/notify/card wiring exercised without a
    /// real 5 s wait (mirrors `AttentionCoordinator.present(_:)`'s own reasoning).
    func publish(_ questions: [String: CodexQuestion]) {
        self.questions = questions
    }

    /// `AppState.apply()` calls this on every session refresh. Cheap: it only replaces the array
    /// the next tick reads: the actual `stat`/tail-read work happens on `queue`, on the timer's
    /// own schedule, never synchronously with the caller.
    func observe(_ candidates: [CodexQuestionCandidate]) {
        queue.async { [weak self] in self?.candidates = candidates }
    }

    private func tick() {
        let result = CodexQuestionCheck.run(
            candidates: candidates, cache: cache, tailBytes: tailBytes,
            statter: statter, tailReader: tailReader
        )
        cache = result.cache
        let published = result.questions
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.questions != published { self.questions = published }
        }
    }

    static func defaultStatter(_ path: String) -> CodexRolloutStat? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        guard let modified = attrs[.modificationDate] as? Date,
              let sizeNumber = attrs[.size] as? NSNumber
        else { return nil }
        return CodexRolloutStat(size: sizeNumber.uint64Value, modified: modified)
    }

    /// The same tail-read shape `TranscriptTail.read` already uses — seek to `size - maxBytes`,
    /// read to the end, never pull the whole file into memory.
    static func defaultTailReader(_ path: String, _ maxBytes: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        return try? handle.readToEnd()
    }
}
