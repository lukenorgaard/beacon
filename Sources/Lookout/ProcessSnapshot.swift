import Darwin
import Foundation

/// The live process list, taken through libproc instead of forking `ps`.
///
/// Measured on this Mac (825 processes): `ps -axo pid=,ppid=,tty=,comm=,args=` costs ~70 ms of
/// CPU per call, which at one call every 5 s blows the < 0.3 % idle budget on its own (SPEC §5.6).
/// The same snapshot through `proc_listpids` + `proc_pidpath` costs ~3 ms — and `ps` truncates
/// `comm` to 16 characters (`/Applications/Cl`) while `proc_pidpath` returns the whole path, so
/// this is both cheaper and more accurate. `ProcessTable.parse` stays as the fallback.
enum ProcessSnapshot {
    /// The four — and only four — environment keys Lookout is allowed to read out of another
    /// process (SPEC §9.1, §11.2). Everything else in that buffer is skipped at byte level.
    static let hostSessionKey = "CLAUDE_CODE_HOST_SESSION_ID"
    static let sessionKey = "CLAUDE_CODE_SESSION_ID"
    static let messagingSocketKey = "CLAUDE_CODE_MESSAGING_SOCKET"
    static let messagingTokenKey = "CLAUDE_CODE_MESSAGING_TOKEN"

    /// Every key this file will ever decode — the allow-list, in one testable place.
    static let allowedEnvironmentKeys: [String] = [
        hostSessionKey, sessionKey, messagingSocketKey, messagingTokenKey,
    ]

    /// Which half of the allow-list a caller wants. The scan asks for `.session` on every agent
    /// candidate, every five seconds; `.messaging` is asked for once, at the moment a message is
    /// about to be sent, so the token is never in memory the rest of the time (SPEC §11.2).
    struct EnvironmentKeys: OptionSet {
        let rawValue: Int
        static let session = EnvironmentKeys(rawValue: 1 << 0)
        static let messaging = EnvironmentKeys(rawValue: 1 << 1)
    }

    /// Longest value copied out of the environment block. A session id is ~40 characters; this
    /// only exists so a pathological entry can never be pulled into memory wholesale.
    static let maxEnvironmentValue = 256

    /// The messaging token is longer than a session id and shorter than any sane bound, so it
    /// gets its own ceiling rather than widening the one the ids use.
    static let maxTokenValue = 1024

    /// Everything we can see, with `command` = the executable path. Agent candidates are then
    /// enriched with their argument vector and tty, which is what the exclusion markers need,
    /// plus the two allowed environment keys (SPEC §9.1).
    ///
    /// `cache`, when given, lets a repeat sighting of the same candidate (same pid, same start
    /// time) skip `proc_pidpath` and the procargs sysctl entirely — see the file-level note above
    /// `ProcessIdentity`. Everything that is not already a known candidate pid is resolved exactly
    /// as before, every tick: caching never changes what a *new* process is classified as, only
    /// how cheaply a *stable* one is re-confirmed.
    static func entries(
        agentCommands: Set<String>,
        cache: ProcessInfoCache? = nil,
        source: ProcessInfoSource = .live
    ) -> [ProcessEntry] {
        let pids = source.listPIDs()
        guard !pids.isEmpty else { return [] }

        var entries: [ProcessEntry] = []
        entries.reserveCapacity(pids.count)
        var liveIdentities: Set<ProcessIdentity> = []
        // A hint only: it decides whether to spend one same-UID identity check on this pid, not
        // whether the pid is trusted. A pid whose start time no longer matches always falls
        // through to full resolution below.
        let hintPIDs = cache?.cachedPIDs ?? []

        for pid in pids where pid > 0 {
            guard let short = source.shortInfo(pid) else { continue }

            if hintPIDs.contains(pid), let basic = source.basicInfo(pid) {
                let identity = ProcessIdentity(
                    pid: pid, startSeconds: basic.startSeconds,
                    startMicroseconds: basic.startMicroseconds
                )
                if let cached = cache?.lookup(identity) {
                    liveIdentities.insert(identity)
                    entries.append(
                        ProcessEntry(
                            pid: pid, ppid: short.ppid, tty: basic.tty, command: cached.command,
                            hostSessionID: cached.hostSessionID, sessionID: cached.sessionID
                        )
                    )
                    continue
                }
                // Same pid, a different (or unreadable) start time: the kernel recycled this pid
                // since it was last cached. Never trust the stale entry — fall through and
                // resolve it fresh, exactly as if there had been no hint at all.
            }

            // A session whose executable was replaced on disk since it started (Claude Code
            // auto-updates its npm binary) has no path any more; the kernel still knows its name.
            let resolved = source.path(pid)
            let path = (resolved.flatMap { $0.isEmpty ? nil : $0 }) ?? short.comm
            guard !path.isEmpty else { continue }

            // Only a handful of processes are agent candidates; only those pay for arguments,
            // and only those have their environment block looked at at all.
            // Match on the path *and* the kernel name: the npm build ships as `claude.exe`.
            let isCandidate = ProcessScanner.agentName(
                command: path, agentCommands: agentCommands
            ) != nil || ProcessScanner.agentName(
                command: short.comm, agentCommands: agentCommands
            ) != nil

            guard isCandidate else {
                entries.append(ProcessEntry(pid: pid, ppid: short.ppid, tty: nil, command: path))
                continue
            }

            let parsed = source.procargs(pid)
            let command = parsed.map { "\(path) \($0.command)" } ?? path
            let basic = source.basicInfo(pid)

            entries.append(
                ProcessEntry(
                    pid: pid, ppid: short.ppid, tty: basic?.tty, command: command,
                    hostSessionID: parsed?.hostSessionID, sessionID: parsed?.sessionID
                )
            )

            if let cache, let basic {
                let identity = ProcessIdentity(
                    pid: pid, startSeconds: basic.startSeconds,
                    startMicroseconds: basic.startMicroseconds
                )
                liveIdentities.insert(identity)
                cache.store(
                    identity,
                    CachedProcessInfo(
                        command: command, comm: short.comm, ppid: short.ppid,
                        hostSessionID: parsed?.hostSessionID, sessionID: parsed?.sessionID
                    )
                )
            }
        }

        cache?.evict(keeping: liveIdentities)
        return entries
    }

    static func allPIDs() -> [pid_t] {
        let probe = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard probe > 0 else { return [] }
        let capacity = Int(probe) / MemoryLayout<pid_t>.size + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let bytes = proc_listpids(
            UInt32(PROC_ALL_PIDS), 0, &pids, Int32(capacity * MemoryLayout<pid_t>.size)
        )
        guard bytes > 0 else { return [] }
        return Array(pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size))
    }

    /// Parent pid and the kernel's command name (`p_comm`, 16 chars) in one cheap call.
    static func shortInfo(of pid: pid_t) -> (ppid: Int32, comm: String)? {
        var info = proc_bsdshortinfo()
        let size = proc_pidinfo(
            pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdshortinfo>.size)
        )
        guard size == Int32(MemoryLayout<proc_bsdshortinfo>.size) else { return nil }
        let comm = withUnsafeBytes(of: &info.pbsi_comm) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        return (Int32(bitPattern: info.pbsi_ppid), comm)
    }

    /// The cheap variant of the BSD info — this is the call that runs for every process.
    static func parent(of pid: pid_t) -> Int32? {
        var info = proc_bsdshortinfo()
        let size = proc_pidinfo(
            pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdshortinfo>.size)
        )
        guard size == Int32(MemoryLayout<proc_bsdshortinfo>.size) else { return nil }
        return Int32(bitPattern: info.pbsi_ppid)
    }

    /// `ttys005`, or nil for a process with no controlling terminal.
    static func tty(of pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(
            pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard size == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        return deviceName(info.e_tdev)
    }

    /// Tty and start time in one `PROC_PIDTBSDINFO` read — same struct `tty(of:)` reads, with the
    /// two fields the cache needs (SPEC: process-scan cost). Same-UID only; see the file-level
    /// note above `ProcessIdentity`.
    static func basicInfo(of pid: pid_t) -> ProcessBasicInfo? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(
            pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard size == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        return ProcessBasicInfo(
            tty: deviceName(info.e_tdev),
            startSeconds: Int64(info.pbi_start_tvsec),
            startMicroseconds: Int64(info.pbi_start_tvusec)
        )
    }

    static func deviceName(_ device: UInt32) -> String? {
        guard device != UInt32.max, device != 0 else { return nil }
        guard let name = devname(dev_t(bitPattern: device), S_IFCHR) else { return nil }
        let value = String(cString: name)
        return value.isEmpty ? nil : value
    }

    /// The process's working directory, straight from the kernel — no `lsof` fork. Fails for
    /// processes we do not own, which is what the `lsof` fallback is for.
    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = proc_pidinfo(
            pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)
        )
        guard size == Int32(MemoryLayout<proc_vnodepathinfo>.size) else { return nil }

        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        return path.isEmpty ? nil : path
    }

    /// The argument vector, space-joined. Read-only, and never logged — a command line can carry
    /// anything the user typed.
    static func arguments(of pid: pid_t) -> String? {
        guard let parsed = procargs(of: pid, environment: false), !parsed.command.isEmpty else {
            return nil
        }
        return parsed.command
    }

    /// One `KERN_PROCARGS2` read. The buffer holds `argc`, the exec path, padding NULs, the
    /// `argc` arguments, and then the whole environment block (SPEC §9.1).
    ///
    /// `environment: false` stops at the end of argv and never looks at a single environment
    /// byte. `environment: true` walks the rest, but only ever *decodes* the two allowed keys.
    static func procargs(of pid: pid_t, environment: Bool) -> ProcessArguments? {
        procargs(of: pid, keys: environment ? .session : [])
    }

    /// The messaging pair for one live pid (SPEC §11.2). Nothing keeps a reference: the caller
    /// uses the token for one connection and drops it.
    static func messaging(of pid: pid_t) -> (socket: String?, token: SecretToken?) {
        guard let parsed = procargs(of: pid, keys: .messaging) else { return (nil, nil) }
        return (parsed.messagingSocket, parsed.messagingToken)
    }

    static func procargs(of pid: pid_t, keys: EnvironmentKeys) -> ProcessArguments? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 8 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 8 else { return nil }
        // The second call may report fewer bytes than it reserved; never read past them.
        if size < buffer.count { buffer.removeLast(buffer.count - size) }

        return parse(procargs: buffer, keys: keys)
    }

    /// The pure parser, split out so the layout — padding, empty arguments, a truncated buffer,
    /// a decoy environment key — can be tested without a live process.
    static func parse(procargs buffer: [UInt8], environment: Bool) -> ProcessArguments? {
        parse(procargs: buffer, keys: environment ? .session : [])
    }

    static func parse(procargs buffer: [UInt8], keys: EnvironmentKeys) -> ProcessArguments? {
        let limit = buffer.count
        guard limit > 8 else { return nil }

        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) })
        guard argc > 0, argc < 65_536 else { return nil }

        var index = 4
        guard let execPath = token(buffer, &index, limit) else { return nil }
        // The exec path is followed by alignment NULs before argv[0].
        while index < limit, buffer[index] == 0 { index += 1 }

        var pieces: [String] = [execPath]
        pieces.reserveCapacity(argc + 1)
        while pieces.count <= argc, index < limit {
            guard let piece = token(buffer, &index, limit) else { break }
            pieces.append(piece)
        }
        let command = pieces.joined(separator: " ")
        guard !keys.isEmpty else { return ProcessArguments(command: command) }

        // Everything from here on is the environment block. It carries an OAuth token, so the
        // key match happens on raw bytes: no entry but the allowed ones is ever made into
        // a String, which makes leaking one by accident impossible rather than merely unlikely.
        let wantsSession = keys.contains(.session)
        let wantsMessaging = keys.contains(.messaging)
        let hostPrefix = Array("\(hostSessionKey)=".utf8)
        let sessionPrefix = Array("\(sessionKey)=".utf8)
        let socketPrefix = Array("\(messagingSocketKey)=".utf8)
        let tokenPrefix = Array("\(messagingTokenKey)=".utf8)
        var hostSessionID: String?
        var sessionID: String?
        var messagingSocket: String?
        var messagingToken: SecretToken?

        func complete() -> Bool {
            if wantsSession, hostSessionID == nil || sessionID == nil { return false }
            if wantsMessaging, messagingSocket == nil || messagingToken == nil { return false }
            return true
        }

        while index < limit, !complete() {
            let start = index
            while index < limit, buffer[index] != 0 { index += 1 }
            let end = index
            if index < limit { index += 1 }
            guard end > start else { continue }

            if wantsSession, hostSessionID == nil,
               let value = value(buffer, from: start, to: end, prefix: hostPrefix) {
                hostSessionID = value
                continue
            }
            if wantsSession, sessionID == nil,
               let value = value(buffer, from: start, to: end, prefix: sessionPrefix) {
                sessionID = value
                continue
            }
            if wantsMessaging, messagingSocket == nil,
               let value = value(buffer, from: start, to: end, prefix: socketPrefix) {
                messagingSocket = value
                continue
            }
            if wantsMessaging, messagingToken == nil,
               let value = value(
                   buffer, from: start, to: end, prefix: tokenPrefix, limit: maxTokenValue
               ) {
                messagingToken = SecretToken(value)
            }
        }

        return ProcessArguments(
            command: command, hostSessionID: hostSessionID, sessionID: sessionID,
            messagingSocket: messagingSocket, messagingToken: messagingToken
        )
    }

    /// One NUL-terminated string, advancing `index` past its terminator.
    static func token(_ buffer: [UInt8], _ index: inout Int, _ limit: Int) -> String? {
        guard index < limit else { return nil }
        let start = index
        while index < limit, buffer[index] != 0 { index += 1 }
        let end = index
        if index < limit { index += 1 }
        return String(decoding: buffer[start..<end], as: UTF8.self)
    }

    /// `KEY=value` → `value`, matched byte by byte so a non-matching entry is never decoded.
    static func value(
        _ buffer: [UInt8], from start: Int, to end: Int, prefix: [UInt8],
        limit valueLimit: Int = maxEnvironmentValue
    ) -> String? {
        let length = end - start
        guard length > prefix.count, length - prefix.count <= valueLimit else {
            return nil
        }
        for offset in 0..<prefix.count where buffer[start + offset] != prefix[offset] {
            return nil
        }
        return String(decoding: buffer[(start + prefix.count)..<end], as: UTF8.self)
    }
}
