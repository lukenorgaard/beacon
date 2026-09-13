import Foundation

/// One row of `ps -axo pid=,ppid=,tty=,comm=,args=`.
///
/// `comm` is truncated to 16 characters by `ps` on macOS (`/Applications/Cl`), so it is useless
/// on its own. Everything here matches against `command`, which is the whole tail of the line —
/// truncated comm *and* the full argument vector.
struct ProcessEntry: Equatable {
    let pid: Int32
    let ppid: Int32
    /// `nil` for `??` (no controlling terminal), otherwise normalised to `ttys005`.
    let tty: String?
    let command: String
    /// `CLAUDE_CODE_HOST_SESSION_ID` — the desktop app's own session id, the only thing its
    /// `claude://code/continue` handler accepts (SPEC §9.1). Agent candidates only.
    var hostSessionID: String?
    /// `CLAUDE_CODE_SESSION_ID` — the real session id, so a hook-reported file can later
    /// replace this row by id and not merely by pid (SPEC §9.1). Agent candidates only.
    var sessionID: String?
}

enum ProcessTable {
    static func parse(_ output: String) -> [ProcessEntry] {
        var entries: [ProcessEntry] = []
        entries.reserveCapacity(512)

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let fields = line.split(
                separator: " ", maxSplits: 3, omittingEmptySubsequences: true
            )
            guard fields.count == 4,
                  let pid = Int32(fields[0]),
                  let ppid = Int32(fields[1])
            else { continue }

            let ttyField = String(fields[2])
            let command = fields[3].trimmingCharacters(in: .whitespaces)
            entries.append(
                ProcessEntry(pid: pid, ppid: ppid, tty: normaliseTTY(ttyField), command: command)
            )
        }
        return entries
    }

    /// `s005` → `ttys005`; `??` → nil. State files use the `ttys005` spelling (SPEC §4).
    static func normaliseTTY(_ field: String) -> String? {
        let value = field.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value != "??", value != "?" else { return nil }
        return value.hasPrefix("tty") ? value : "tty" + value
    }
}

/// An agent process found by scanning, with no state file behind it (SPEC §8.2).
struct DiscoveredAgent: Equatable {
    let pid: Int32
    let agent: String
    let tty: String?
    let host: SessionHost
    let hostPID: Int32?
    /// From the process environment, when the process had them (SPEC §9.1).
    var sessionID: String?
    var hostRef: String?
    /// SPEC §16.2: the nearest shell ancestor, which is what the editor companion matches a
    /// terminal on. Nil when the agent was not started from a shell at all.
    var shellPID: Int32?
}

enum ProcessScanner {
    /// SPEC §8.2 default list; the user can edit it in Settings.
    static let defaultCommands = [
        "claude", "codex", "gemini", "opencode", "aider", "goose", "cursor-agent",
        "amp", "copilot", "qwen",
    ]

    /// Helper processes that share an agent's name but are not a session (SPEC §8.2).
    static let exclusionMarkers = [
        "mcp-server", "app-server", "mcp serve", "--version", "completion",
        // The ChatGPT app's code-mode host keeps long-lived `codex sandbox` helpers under
        // `cua_node/bin/node_repl`. Matched as a subcommand so the `--sandbox` *flag* on a real
        // session (`codex exec --sandbox read-only`) still counts as a session.
        "codex sandbox",
    ]

    /// Ancestor markers, in priority order. Case-sensitive on purpose: the `claude` CLI must not
    /// be mistaken for the `Claude` desktop app.
    private static let hostMarkers: [(marker: String, host: SessionHost)] = [
        ("/Cursor.app/", .cursor),
        ("Cursor Helper", .cursor),
        ("/Devin.app/", .devin),
        ("Devin Helper", .devin),
        ("/Visual Studio Code.app/", .vscode),
        ("/Code.app/", .vscode),
        ("Code Helper", .vscode),
        ("/Terminal.app/", .terminal),
        ("/iTerm.app/", .iterm),
        ("iTerm2", .iterm),
        ("/Claude.app/", .claudeDesktop),
        ("Claude Helper", .claudeDesktop),
        ("/ChatGPT.app/", .codexApp),
        ("/Codex.app/", .codexApp),
    ]

    /// Executable names hidden inside a `ps` line. `ps` truncates `comm`, and a path with spaces
    /// (`…/Application Support/Claude/…/claude`) is split across tokens, so both are reconstructed.
    static func executableCandidates(command: String) -> [String] {
        let tokens = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !tokens.isEmpty else { return [] }

        var candidates: [String] = [basename(tokens[0])]
        guard tokens.count > 1 else { return candidates }
        candidates.append(basename(tokens[1]))

        // A path containing spaces continues in tokens that start with neither `/` nor `-`;
        // a genuine next argument starts with one of those. That distinction keeps
        // `/bin/cat /tmp/claude` from looking like the claude CLI.
        if tokens[1].hasPrefix("/") {
            var joined = tokens[1]
            var index = 2
            while index < tokens.count, index < 6 {
                let token = tokens[index]
                if token.hasPrefix("/") || token.hasPrefix("-") { break }
                joined += " " + token
                candidates.append(basename(joined))
                index += 1
            }
        }
        return candidates
    }

    private static func basename(_ path: String) -> String {
        guard let last = path.split(separator: "/").last else { return path }
        var name = String(last)
        // npm's claude-code package ships its native macOS binary as `claude.exe`.
        if name.hasSuffix(".exe") { name.removeLast(4) }
        return name
    }

    static func isExcluded(command: String) -> Bool {
        exclusionMarkers.contains { command.contains($0) }
    }

    /// An id read out of another process's environment is untrusted input: it ends up in a file
    /// name-shaped key, a tooltip and a URL, so anything that is not a plain identifier is
    /// dropped and the synthetic `discovered-<pid>` id is used instead (SPEC §9.1).
    static func sanitisedIdentifier(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value.count <= 128
        else { return nil }
        let allowed = value.allSatisfy { character in
            guard character.isASCII else { return false }
            return character.isLetter || character.isNumber
                || character == "-" || character == "_" || character == "."
        }
        return allowed ? value : nil
    }

    /// The agent name this line runs, or nil.
    static func agentName(command: String, agentCommands: Set<String>) -> String? {
        for candidate in executableCandidates(command: command) where agentCommands.contains(candidate) {
            return candidate
        }
        return nil
    }

    /// SPEC §16.2: the shells an integrated terminal can be running. `ps` prints a login shell's
    /// argv[0] as `-zsh`, and `proc_pidpath` gives `/bin/zsh`; both reduce to `zsh` here.
    static let shellNames: Set<String> = ["zsh", "bash", "fish", "sh", "nu", "dash"]

    static func isShell(command: String) -> Bool {
        guard let first = command.split(separator: " ", omittingEmptySubsequences: true).first
        else { return false }
        var name = String(first.split(separator: "/").last ?? first)
        while name.hasPrefix("-") { name.removeFirst() }
        return shellNames.contains(name.lowercased())
    }

    /// SPEC §16.2: the nearest ancestor that is a shell — the terminal's `processId` as far as
    /// the companion is concerned. The walk stops at the same depth the host walk uses.
    static func shellPID(for pid: Int32, index: [Int32: ProcessEntry]) -> Int32? {
        var current = index[pid]?.ppid ?? 0
        var level = 0
        while level < 12, current > 1, let entry = index[current] {
            if isShell(command: entry.command) { return entry.pid }
            current = entry.ppid
            level += 1
        }
        return nil
    }

    /// Walk up to 12 ancestors and take the first recognisable host app (same rules as SPEC §4).
    static func host(
        for pid: Int32, index: [Int32: ProcessEntry]
    ) -> (host: SessionHost, hostPID: Int32?) {
        var current = index[pid]?.ppid ?? 0
        var level = 0
        while level < 12, current > 1, let entry = index[current] {
            for (marker, host) in hostMarkers where entry.command.contains(marker) {
                return (host, entry.pid)
            }
            current = entry.ppid
            level += 1
        }
        return (.unknown, nil)
    }

    /// The heart of §8.2: which live processes are agent sessions nobody is reporting for.
    ///
    /// - `coveredPIDs` are pids that already have a state file — those always win.
    static func discover(
        entries: [ProcessEntry],
        agentCommands: [String],
        coveredPIDs: Set<Int32>
    ) -> [DiscoveredAgent] {
        let commands = Set(
            agentCommands
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        )
        guard !commands.isEmpty else { return [] }

        var index: [Int32: ProcessEntry] = [:]
        index.reserveCapacity(entries.count)
        for entry in entries { index[entry.pid] = entry }

        // Pass 1: everything that looks like an agent, before the descendant rule.
        var named: [Int32: String] = [:]
        for entry in entries {
            guard !isExcluded(command: entry.command) else { continue }
            guard let name = agentName(command: entry.command, agentCommands: commands) else {
                continue
            }
            named[entry.pid] = name
        }

        // Pass 2: drop anything running underneath another agent — `codex mcp-server` spawned by
        // a Claude session is a helper, not a session of its own.
        var result: [DiscoveredAgent] = []
        for (pid, name) in named {
            guard !coveredPIDs.contains(pid) else { continue }
            guard !hasAgentAncestor(pid: pid, named: named, index: index, covered: coveredPIDs)
            else { continue }

            let (walked, hostPID) = host(for: pid, index: index)
            let hostRef = sanitisedIdentifier(index[pid]?.hostSessionID)
            // §9.1: the desktop id is in the environment of every desktop session, so a process
            // carrying one that the ancestor walk could not place is a desktop session too.
            // A walk that *did* place it is never overruled — a Cursor terminal opened from the
            // desktop app inherits the variable without being a desktop session.
            let host = (walked == .unknown && hostRef != nil) ? SessionHost.claudeDesktop : walked
            let isDesktop = host == .claudeDesktop

            result.append(
                DiscoveredAgent(
                    pid: pid,
                    agent: name,
                    tty: index[pid]?.tty,
                    host: host,
                    hostPID: hostPID,
                    // §9.1 reads the environment for *desktop* processes. Elsewhere the variable
                    // is inherited rather than owned: measured on this Mac, four unrelated Devin
                    // sessions all reported the same `CLAUDE_CODE_SESSION_ID`, because each
                    // integrated terminal inherited it from the session that opened it.
                    sessionID: isDesktop ? sanitisedIdentifier(index[pid]?.sessionID) : nil,
                    hostRef: isDesktop ? hostRef : nil,
                    shellPID: shellPID(for: pid, index: index)
                )
            )
        }
        return dropSharedIdentifiers(result).sorted { $0.pid < $1.pid }
    }

    /// An id two live processes both claim was inherited by one of them, not owned. Nobody gets
    /// it: a wrong id would let one session's hook file swallow another session's row (SPEC §9.1),
    /// and the synthetic `discovered-<pid>` fallback is always correct.
    static func dropSharedIdentifiers(_ agents: [DiscoveredAgent]) -> [DiscoveredAgent] {
        var counts: [String: Int] = [:]
        for id in agents.compactMap(\.sessionID) { counts[id, default: 0] += 1 }
        var references: [String: Int] = [:]
        for reference in agents.compactMap(\.hostRef) { references[reference, default: 0] += 1 }
        guard counts.values.contains(where: { $0 > 1 })
            || references.values.contains(where: { $0 > 1 })
        else { return agents }

        return agents.map { agent in
            var copy = agent
            if let id = agent.sessionID, counts[id, default: 0] > 1 { copy.sessionID = nil }
            if let reference = agent.hostRef, references[reference, default: 0] > 1 {
                copy.hostRef = nil
            }
            return copy
        }
    }

    private static func hasAgentAncestor(
        pid: Int32, named: [Int32: String], index: [Int32: ProcessEntry], covered: Set<Int32>
    ) -> Bool {
        var current = index[pid]?.ppid ?? 0
        var level = 0
        while level < 24, current > 1 {
            if named[current] != nil || covered.contains(current) { return true }
            guard let parent = index[current]?.ppid else { return false }
            current = parent
            level += 1
        }
        return false
    }
}

/// Runs the scan against the live machine. One `ps` and at most one `lsof` per tick, always on a
/// background queue, with hard deadlines so a wedged call can never stall the tick (SPEC §5.6).
final class ProcessScanRunner {
    private var firstSeen: [Int32: Date] = [:]
    private var knownCWD: [Int32: String] = [:]
    /// Kept across ticks so a stable candidate can skip `proc_pidpath` and the procargs sysctl
    /// on every scan after its first (SPEC: process-scan cost). Keyed by (pid, start time), never
    /// by pid alone.
    private let processCache = ProcessInfoCache()

    /// - Returns: synthetic `running` sessions, in memory only.
    func scan(coveredPIDs: Set<Int32>, agentCommands: [String]) -> [Session] {
        let entries = processes(agentCommands: agentCommands)
        guard !entries.isEmpty else { return [] }

        let discovered = ProcessScanner.discover(
            entries: entries, agentCommands: agentCommands, coveredPIDs: coveredPIDs
        )
        guard !discovered.isEmpty else {
            firstSeen.removeAll()
            knownCWD.removeAll()
            return []
        }

        let now = Date()
        let livePIDs = Set(discovered.map(\.pid))
        firstSeen = firstSeen.filter { livePIDs.contains($0.key) }
        knownCWD = knownCWD.filter { livePIDs.contains($0.key) }
        for agent in discovered where firstSeen[agent.pid] == nil {
            firstSeen[agent.pid] = now
        }

        // cwd comes from the kernel first; only pids that refuse fall back to a batched lsof,
        // which is capped at one second and never blocks the tick.
        var missing: [Int32] = []
        for pid in discovered.map(\.pid) where knownCWD[pid] == nil {
            if let path = ProcessSnapshot.workingDirectory(of: pid) {
                knownCWD[pid] = path
            } else {
                missing.append(pid)
            }
        }
        if !missing.isEmpty {
            for (pid, path) in Self.workingDirectories(pids: missing) {
                knownCWD[pid] = path
            }
        }

        return discovered.map { agent in
            var session = Session()
            // The real id when the process handed one over, so a hook-reported file can replace
            // this row by id rather than only by pid (SPEC §9.1).
            session.sessionID = agent.sessionID ?? "discovered-\(agent.pid)"
            session.hostRef = agent.hostRef
            session.agent = SessionAgent(raw: agent.agent)
            session.state = .running
            session.reason = "discovered"
            session.pid = agent.pid
            session.tty = agent.tty
            session.shellPid = agent.shellPID
            session.host = agent.host
            session.hostPID = agent.hostPID
            session.cwd = knownCWD[agent.pid] ?? ""
            session.project = session.cwd.isEmpty
                ? agent.agent
                : Session.projectName(for: session.cwd)
            let seen = firstSeen[agent.pid] ?? now
            session.startedAt = seen
            session.stateSince = seen
            session.updatedAt = now
            session.isDiscovered = true
            return session
        }
    }

    /// libproc first (~3 ms); `ps` only if it somehow came back empty.
    private func processes(agentCommands: [String]) -> [ProcessEntry] {
        let commands = Set(
            agentCommands
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        )
        let entries = ProcessSnapshot.entries(agentCommands: commands, cache: processCache)
        if !entries.isEmpty { return entries }

        let ps = Shell.run("/bin/ps", ["-axo", "pid=,ppid=,tty=,comm=,args="], timeout: 3)
        guard !ps.timedOut, !ps.stdout.isEmpty else { return [] }
        return ProcessTable.parse(ps.stdout)
    }

    /// `lsof -a -p 1,2,3 -d cwd -Fn` → `p<pid>` / `n<path>` lines.
    static func workingDirectories(pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        let result = Shell.run(
            "/usr/sbin/lsof", ["-a", "-p", list, "-d", "cwd", "-Fn"], timeout: 1
        )
        guard !result.timedOut else { return [:] }
        return parseLSOF(result.stdout)
    }

    static func parseLSOF(_ output: String) -> [Int32: String] {
        var map: [Int32: String] = [:]
        var current: Int32?
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            switch line.first {
            case "p":
                current = Int32(line.dropFirst())
            case "n":
                if let pid = current, map[pid] == nil {
                    map[pid] = String(line.dropFirst())
                }
            default:
                continue
            }
        }
        return map
    }
}
