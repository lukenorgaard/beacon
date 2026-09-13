import Darwin
import Foundation

/// What one `KERN_PROCARGS2` buffer yields: the command line, and — for agent candidates only —
/// the two session ids Claude Code puts in the environment (SPEC §9.1).
///
/// Nothing else from the environment block is ever decoded, let alone stored or logged: the
/// environment of a Claude session also carries `CLAUDE_CODE_OAUTH_TOKEN` (SPEC §2.1).
struct ProcessArguments: Equatable {
    var command: String
    var hostSessionID: String?
    var sessionID: String?
    /// SPEC §11.2: the session's messaging socket path. Read only when explicitly asked for.
    var messagingSocket: String?
    /// SPEC §11.2: the messaging token, which is never written to disk and never logged. It is
    /// wrapped so that printing or interpolating it anywhere yields `<redacted>` and not the
    /// secret — the type makes the mistake impossible rather than merely discouraged.
    var messagingToken: SecretToken?
}

/// A string that refuses to describe itself. Only `value` hands the secret over, and every call
/// site that touches it is one grep away.
struct SecretToken: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let value: String

    init(_ value: String) { self.value = value }

    var description: String { "<redacted>" }
    var debugDescription: String { "<redacted>" }
    var isEmpty: Bool { value.isEmpty }
}

// MARK: - Per-process cache (task: process-scan cost)
//
// Measured with `sample` on the live app: `ProcessScanRunner.scan` — one `proc_listpids` plus,
// per pid, `proc_pidpath` and (candidates only) a `PROC_PIDTBSDINFO` read and the `KERN_PROCARGS2`
// sysctl — dominates the app's own CPU work. `proc_pidpath` and the procargs sysctl are the two
// calls worth skipping on a repeat tick; a cache makes that possible for any pid whose identity
// — pid *and* start time — is unchanged since the last time it was resolved.
//
// Measured on this Mac: `PROC_PIDTBSDINFO` (the struct that carries start time) only succeeds for
// same-UID processes — it fails for roughly a third of this machine's ~830 processes (root-owned
// daemons included; verified against pid 1/launchd). `PROC_PIDT_SHORTBSDINFO` (ppid + comm, no
// start time) succeeds for all of them. A real agent CLI always runs as the same user as Lookout,
// so this is never a problem for anything the cache actually stores — but it does mean start time
// can only ever be read for candidates, which is exactly the population this cache covers.

/// A live process's identity for cache purposes: pid *and* start time, never pid alone. macOS
/// reuses pids; keying a cache by pid alone would, after reuse, hand whatever the kernel recycled
/// that pid to the previous occupant's cached path, comm and — worse — its session/host ids. For
/// a desktop candidate that could route a message into a session that no longer exists, or into
/// an unrelated live one (SPEC §9.1).
struct ProcessIdentity: Hashable {
    let pid: pid_t
    let startSeconds: Int64
    let startMicroseconds: Int64
}

/// What a confirmed candidate looked like last time it was resolved — enough to reconstruct its
/// `ProcessEntry` without paying for `proc_pidpath` or the procargs sysctl again.
struct CachedProcessInfo: Equatable {
    /// `ProcessEntry.command`: the full `path + argv` line a candidate carries, which is what
    /// the exclusion markers and `executableCandidates` match against — not the bare path.
    var command: String
    var comm: String
    /// Mirrors the cached fields the task asks for, but is never treated as authoritative: a
    /// live pid's ppid can change (reparenting to launchd(1) when its real parent dies) without
    /// its (pid, start) identity changing, and `entries(agentCommands:)` already has a fresh,
    /// cheap ppid every tick from the universal `shortInfo` call — so it always prefers that one.
    var ppid: Int32
    var hostSessionID: String?
    var sessionID: String?
}

/// Per-process cache keyed by (pid, start time). Only ever holds confirmed agent candidates —
/// the population where the expensive calls (`proc_pidpath`, the procargs sysctl) and the
/// correctness-sensitive fields (session/host ids) both live.
final class ProcessInfoCache {
    private var storage: [ProcessIdentity: CachedProcessInfo] = [:]
    let capacity: Int

    init(capacity: Int = 4096) { self.capacity = capacity }

    var count: Int { storage.count }

    /// The pids currently represented, at any start time — a cheap hint `entries(agentCommands:)`
    /// uses to decide which pids are worth a same-UID identity check at all. It is only ever a
    /// hint: a pid reused under a new start time still misses `lookup`, and the caller always
    /// falls back to full resolution when that happens.
    var cachedPIDs: Set<pid_t> { Set(storage.keys.map(\.pid)) }

    func lookup(_ identity: ProcessIdentity) -> CachedProcessInfo? { storage[identity] }

    func store(_ identity: ProcessIdentity, _ info: CachedProcessInfo) {
        if storage[identity] == nil, storage.count >= capacity {
            // Correctness never depends on which entry is dropped: a dropped entry is just a
            // cache miss on the next tick, never a wrong answer.
            if let victim = storage.keys.first { storage.removeValue(forKey: victim) }
        }
        storage[identity] = info
    }

    /// Drops every identity that was not confirmed live in the scan that just ran — a pid that
    /// exited, or was reused under a new start time, must never linger and serve a stale hit.
    func evict(keeping live: Set<ProcessIdentity>) {
        storage = storage.filter { live.contains($0.key) }
    }
}

/// The full `PROC_PIDTBSDINFO` read: controlling tty and start time together, since the caching
/// layer needs both and they come from the same struct. Same-UID only (see the file-level note
/// above) — `entries(agentCommands:)` only ever calls this for a pid it already suspects or has
/// confirmed is an agent candidate, which is always started by the same user as Lookout itself.
struct ProcessBasicInfo: Equatable {
    let tty: String?
    let startSeconds: Int64
    let startMicroseconds: Int64
}

/// The kernel calls `entries(agentCommands:)` needs, pulled out so the caching and candidate
/// filtering can be driven by fakes in tests — including a fake pid lister, which is what makes
/// pid reuse (same pid, a different start time) reproducible without waiting for a real one.
struct ProcessInfoSource {
    var listPIDs: () -> [pid_t]
    var shortInfo: (pid_t) -> (ppid: Int32, comm: String)?
    var basicInfo: (pid_t) -> ProcessBasicInfo?
    /// nil when `proc_pidpath` fails — callers fall back to the kernel's `comm`, same as before
    /// this cache existed (a deleted/replaced binary is still matched by comm).
    var path: (pid_t) -> String?
    /// One `KERN_PROCARGS2` read: argv *and* the two allowed session-id env keys together, since
    /// both come out of the same sysctl call.
    var procargs: (pid_t) -> ProcessArguments?

    static let live = ProcessInfoSource(
        listPIDs: { ProcessSnapshot.allPIDs() },
        shortInfo: { ProcessSnapshot.shortInfo(of: $0) },
        basicInfo: { ProcessSnapshot.basicInfo(of: $0) },
        path: { pid in
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            return length > 0 ? String(cString: buffer) : nil
        },
        procargs: { ProcessSnapshot.procargs(of: $0, keys: .session) }
    )
}
