import Darwin
import Foundation

/// The name lists the rules match on. They live next to the sampler because the sampler is what
/// has to keep them findable: rewriting `com.nordvpn.macos.Shield` to a product name is only
/// allowed as long as the rewritten name still contains its marker token.
enum SystemMarkers {
    static let networkExtension = [
        "nordvpn", "expressvpn", "protonvpn", "mullvad", "wireguard", "openvpn",
        "little snitch", "lulu", "crowdstrike", "falcon", "sentinelone",
        "sophos", "mcafee", "norton", "zscaler", "netskope", "cisco anyconnect",
    ]

    static let callApps = [
        "zoom.us", "zoom", "microsoft teams", "teams", "facetime", "avconferenced",
        "webex", "bluejeans", "gotomeeting", "discord", "slack call",
    ]

    static func matches(_ name: String, any markers: [String]) -> Bool {
        let lowered = name.lowercased()
        return markers.contains { lowered.contains($0) }
    }
}

/// The process half of one cycle (SPEC §18.6). Taken at most every 15 s, so a snapshot published
/// in between carries the previous one — which is exactly what the sustain windows expect.
struct SystemProcessSample {
    var processes: [SystemProcessLoad] = []
    var orphans: [OrphanedProcess] = []
    var topApps: [SystemAppLoad] = []
    var processCount: Int = 0
    var windowServerCPU: Double = 0
    var networkExtensionCPU: Double = 0
    /// False on the first sample, where there is no previous CPU-time reading to subtract from
    /// and every `cpuPercent` is therefore 0. The watcher takes the next one early rather than
    /// showing an idle machine for a full interval.
    var hasBaseline = false
    /// Wall time spent in `SystemPrivilegedCPUProbe`, and 0 on every cycle that did not fork.
    var privilegedMilliseconds: Double = 0
    /// Set when the probe could not run or had to back off — the only part of a cycle that can
    /// fail on its own without invalidating everything else.
    var probeError: String?
}

/// One live process's identity: pid *and* start time, never pid alone. macOS recycles pids, and a
/// cache keyed by pid alone would hand the recycled process the previous occupant's name and CPU
/// baseline — a fabricated 4000 % spike at best, the wrong name on a Stop button at worst.
private struct SystemProcessKey: Hashable {
    let pid: Int32
    let startAbstime: UInt64
}

/// Enumerates processes through libproc — no `ps` fork (SPEC §18.6; the fork is what made the
/// Sentinel app expensive). Measured on this Mac: ~6 ms for ~875 pids, against ~70 ms for `ps`.
///
/// The ceiling this buys is real and unavoidable: `proc_pid_rusage` and `proc_pidinfo` only
/// answer for processes owned by the current uid (macOS `ps` reads the rest because it is setuid
/// root). Processes we cannot read are counted in `processCount` and otherwise skipped, so
/// `windowServerCPU` — WindowServer runs as uid 88 — and root-owned system extensions read 0.
final class SystemProcessSampler {
    private let ownUID = getuid()
    private var previousCPUTicks: [SystemProcessKey: UInt64] = [:]
    private var previousSampleTime: Date?
    private var names: [SystemProcessKey: (name: String, appName: String?)] = [:]
    private let now: () -> Date
    private let timebase: (numer: Double, denom: Double)
    /// The only way to see WindowServer and a root-owned system extension at all — see the note
    /// on `SystemPrivilegedCPUProbe`.
    private let probe: SystemPrivilegedCPUProbe
    /// SPEC §18.3 shows five; eight is what the contract allows and leaves the tab room to grow.
    private let topAppLimit = 8

    init(now: @escaping () -> Date = Date.init, probe: SystemPrivilegedCPUProbe? = nil) {
        self.now = now
        self.probe = probe ?? SystemPrivilegedCPUProbe(now: now)
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = (Double(info.numer), Double(info.denom))
    }

    func sample() -> SystemProcessSample {
        let pids = Self.allPIDs()
        guard !pids.isEmpty else { return SystemProcessSample() }

        let timestamp = now()
        let elapsed = previousSampleTime.map { timestamp.timeIntervalSince($0) } ?? 0
        let hasBaseline = elapsed > 0.5
        let machNow = mach_absolute_time()

        var result = SystemProcessSample()
        result.processCount = pids.count
        result.hasBaseline = hasBaseline
        result.processes.reserveCapacity(pids.count)

        var currentTicks: [SystemProcessKey: UInt64] = [:]
        currentTicks.reserveCapacity(pids.count)
        var liveNames: [SystemProcessKey: (name: String, appName: String?)] = [:]
        liveNames.reserveCapacity(names.count)
        var orphanCandidates: [SystemOrphanCandidate] = []
        var otherUsers: [SystemProbeProcess] = []

        for pid in pids where pid > 0 {
            // uid first: it is the cheap call, and it is what decides whether the expensive one
            // can possibly succeed.
            guard let short = Self.shortInfo(of: pid) else { continue }
            guard short.uid == ownUID else {
                // Not ours, so `rusage` will refuse it. Note it down for the probe instead —
                // `proc_pidpath` does answer for these, which is what the selection needs.
                otherUsers.append(
                    SystemProbeProcess(
                        pid: pid, uid: short.uid, comm: short.comm, path: Self.path(of: pid)
                    )
                )
                continue
            }
            guard let usage = Self.rusage(of: pid) else { continue }

            let key = SystemProcessKey(pid: pid, startAbstime: usage.ri_proc_start_abstime)
            let ticks = usage.ri_user_time &+ usage.ri_system_time
            currentTicks[key] = ticks

            var cpuPercent = 0.0
            if hasBaseline, let previous = previousCPUTicks[key], ticks >= previous {
                cpuPercent = machNanoseconds(ticks - previous) / (elapsed * 1_000_000_000) * 100
            }

            let named: (name: String, appName: String?)
            if let cached = names[key] {
                named = cached
            } else {
                let path = Self.path(of: pid) ?? short.comm
                named = (Self.displayName(for: path), Self.owningApp(for: path))
            }
            liveNames[key] = named

            result.processes.append(
                SystemProcessLoad(
                    pid: pid, name: named.name, appName: named.appName,
                    cpuPercent: cpuPercent, residentBytes: usage.ri_resident_size,
                    identity: Self.path(of: pid).map { SystemProcessIdentity(pid: pid, name: named.name,
                        path: $0, uid: short.uid, startedAt: usage.ri_proc_start_abstime) }
                )
            )

            guard short.ppid == 1, cpuPercent >= SystemOrphans.minimumCPU else { continue }
            // Only this handful ever pays for a command line, and only argv is read — the
            // environment block behind the same sysctl is never decoded (SPEC §9.1).
            let path = Self.path(of: pid) ?? short.comm
            orphanCandidates.append(
                SystemOrphanCandidate(
                    pid: pid, name: named.name, path: path,
                    cpuPercent: cpuPercent,
                    elapsed: machSeconds(machNow &- usage.ri_proc_start_abstime),
                    command: ProcessSnapshot.arguments(of: pid) ?? path
                )
            )
        }

        previousCPUTicks = currentTicks
        previousSampleTime = timestamp
        names = liveNames

        // The probe's rows join the general population before anything is ranked, so WindowServer
        // and a VPN extension reach the roll-up, `topApps` and every rule exactly like the rest.
        // Their resident size is unknown and stays 0 rather than being guessed at, which also
        // keeps them out of the memory rules' "biggest user".
        let probed = probe.sample(SystemPrivilegedCPUProbe.candidates(in: otherUsers, ownUID: ownUID))
        for reading in probed.readings {
            result.processes.append(
                SystemProcessLoad(
                    pid: reading.pid,
                    name: Self.displayName(for: reading.path),
                    appName: Self.owningApp(for: reading.path),
                    cpuPercent: reading.cpuPercent,
                    residentBytes: 0
                )
            )
        }
        result.privilegedMilliseconds = probed.milliseconds
        result.probeError = probe.lastError

        result.processes.sort { $0.cpuPercent > $1.cpuPercent }
        result.topApps = Array(Self.rollUp(result.processes).prefix(topAppLimit))
        result.orphans = SystemOrphans.scan(orphanCandidates)
        result.windowServerCPU = result.processes
            .filter { $0.name == "WindowServer" }
            .reduce(0) { $0 + $1.cpuPercent }
        result.networkExtensionCPU = result.processes
            .filter { SystemMarkers.matches($0.name, any: SystemMarkers.networkExtension) }
            .reduce(0) { $0 + $1.cpuPercent }
        return result
    }

    /// `ri_user_time` and `ri_system_time` are mach absolute time units, not nanoseconds —
    /// verified against `ps -o time=`, which reads 41.7× larger on this machine (timebase 125/3).
    private func machNanoseconds(_ ticks: UInt64) -> Double {
        Double(ticks) * timebase.numer / timebase.denom
    }

    private func machSeconds(_ ticks: UInt64) -> TimeInterval {
        machNanoseconds(ticks) / 1_000_000_000
    }

    // MARK: - Roll-up

    /// Chrome with 40 helpers is one thing to a human. Grouping by owning app is what lets advice
    /// say "quit Chrome" instead of naming a renderer pid.
    static func rollUp(_ processes: [SystemProcessLoad]) -> [SystemAppLoad] {
        var grouped: [String: SystemAppLoad] = [:]
        grouped.reserveCapacity(processes.count)
        for process in processes {
            let key = process.actionableName
            var entry = grouped[key]
                ?? SystemAppLoad(name: key, cpuPercent: 0, residentBytes: 0, processCount: 0)
            entry.cpuPercent += process.cpuPercent
            entry.residentBytes &+= process.residentBytes
            entry.processCount += 1
            grouped[key] = entry
        }
        return grouped.values.sorted {
            $0.cpuPercent == $1.cpuPercent ? $0.name < $1.name : $0.cpuPercent > $1.cpuPercent
        }
    }

    // MARK: - Naming

    /// System extensions have no `.app` bundle, so their executable name is a raw bundle id like
    /// `com.nordvpn.macos.Shield`. Telling someone that is "eating CPU" is not actionable — they
    /// need the product name they recognise. Every display name still contains its marker token,
    /// or `SystemRules` stops matching it.
    private static let vendorNames: [(token: String, display: String)] = [
        ("nordvpn", "NordVPN"),
        ("expressvpn", "ExpressVPN"),
        ("protonvpn", "ProtonVPN"),
        ("mullvad", "Mullvad"),
        ("wireguard", "WireGuard"),
        ("openvpn", "OpenVPN"),
        ("littlesnitch", "Little Snitch"),
        ("crowdstrike", "CrowdStrike Falcon"),
        ("sentinelone", "SentinelOne"),
        ("sophos", "Sophos"),
        ("zscaler", "Zscaler"),
        ("netskope", "Netskope"),
    ]

    static func displayName(for path: String) -> String {
        let base = (path as NSString).lastPathComponent
        guard !base.isEmpty else { return path }

        // Only rewrite reverse-DNS style names; real executables keep their own name.
        if base.contains("."), base.lowercased().hasPrefix("com.") {
            let lowered = base.lowercased()
            for vendor in vendorNames where lowered.contains(vendor.token) {
                return vendor.display
            }
        }

        // Electron rewrites argv[0] to a live status string, e.g.
        // "Cursor Helper (Plugin): extension-host (retrieval) [2-7]". Keep the part before the
        // colon; the rest changes every sample and would mint a new roll-up bucket each time.
        if let colon = base.firstIndex(of: ":") {
            let head = String(base[base.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            if !head.isEmpty { return head }
        }
        return base.count > 48 ? String(base.prefix(45)) + "…" : base
    }

    /// The outermost `.app` in the path — the bundle a person would actually quit, not the helper
    /// process that happens to be burning the CPU.
    static func owningApp(for path: String) -> String? {
        for component in (path as NSString).pathComponents where component.hasSuffix(".app") {
            let name = String(component.dropLast(4))
            return name.isEmpty ? nil : name
        }

        // No path at all when the kernel's 16-character `comm` is all we have. Those helpers
        // still name their parent, and without this each one becomes its own roll-up bucket.
        guard !path.hasPrefix("/") else { return nil }
        if let range = path.range(of: " Helper") {
            let owner = String(path[path.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            if !owner.isEmpty { return owner }
        }
        return nil
    }

    // MARK: - libproc

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

    /// Parent pid, owner and the kernel's 16-character command name in one cheap call that works
    /// for every process on the machine, including the ones `rusage` refuses.
    static func shortInfo(of pid: pid_t) -> (ppid: Int32, uid: uid_t, comm: String)? {
        var info = proc_bsdshortinfo()
        let size = proc_pidinfo(
            pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdshortinfo>.size)
        )
        guard size == Int32(MemoryLayout<proc_bsdshortinfo>.size) else { return nil }
        let comm = withUnsafeBytes(of: &info.pbsi_comm) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        return (Int32(bitPattern: info.pbsi_ppid), info.pbsi_uid, comm)
    }

    /// CPU time, resident size and start time in one call. Same-uid only.
    static func rusage(of pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? info : nil
    }

    static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    /// What `stopProcess` re-checks a pid against, and what the sampler would have named it.
    static func liveName(of pid: pid_t) -> String? {
        guard let short = shortInfo(of: pid) else { return nil }
        return displayName(for: path(of: pid) ?? short.comm)
    }
}

/// One process the orphan test is applied to. Plain data so the test can be run without a
/// machine — which is the whole reason the rule is trustworthy enough to offer a Stop button.
struct SystemOrphanCandidate: Equatable {
    var pid: Int32
    /// Exactly what `SystemProcessSampler.displayName(for:)` made of `path`. The Stop button
    /// re-derives the name the same way before it signals anything, so the two must be produced
    /// by the same function or every Stop is refused as a recycled pid.
    var name: String
    /// The executable path on its own. Argv cannot be split back off `command` — a bundle path
    /// has spaces in it, which is how the Sentinel app ended up calling Chrome "Google".
    var path: String
    var cpuPercent: Double
    var elapsed: TimeInterval
    /// Executable path followed by argv, the way `KERN_PROCARGS2` hands it over.
    var command: String
}

/// Finds abandoned automation processes (SPEC §18.2 `process.orphaned`).
///
/// `ppid == 1` is evidence of nothing on its own: launchd parents every LaunchAgent, every brew
/// service, every XPC service and every GUI app the owner opened. The first version of this test
/// read "not inside an `.app` bundle, at ppid 1, over 20 % CPU" as abandonment, and on a real
/// machine that classified SourceKitService, ollama, whisper-server, postgres, node under fnm,
/// ssh-agent and chrome_crashpad_handler as orphans — each one offered a Stop button under the
/// words "nothing will ever stop them". Every one of those is somebody's service.
///
/// So the test now demands *positive* evidence of abandonment, in this order:
/// 1. the executable is not where a package manager, the system or an XPC/app-extension bundle
///    puts things (`excludedPrefixes`, `excludedFragments`, `~/Library`),
/// 2. its name is not service-ish (`isServiceName`),
/// 3. its command line carries an automation marker — a headless browser, a webdriver, a
///    Playwright/Puppeteer helper, or an agent runtime running non-interactively.
///
/// Only then do ppid 1 (the sampler's own precondition) and CPU sustained over the rule's window
/// make it an orphan. False negatives are the deliberate trade: a missed orphan costs a little
/// CPU, and a false one puts a Stop button on the owner's database.
enum SystemOrphans {
    /// Flags and helper paths that only ever appear when a browser or runtime was driven by a
    /// script rather than opened by a person. Matched lowercased against the whole command line.
    static let automationMarkers = [
        "--headless", "--remote-debugging-port", "--remote-debugging-pipe",
        "--enable-automation", "--user-data-dir=/var/folders", "--user-data-dir=/tmp",
        "chromedriver", "geckodriver", "webdriver", "selenium",
        "puppeteer", "playwright",
    ]

    /// Runtimes a script drives — but also exactly how a person runs an interactive tool, so one
    /// of `agentMarkers` has to appear alongside before any of these counts as evidence.
    static let agentRuntimes = ["claude", "codex", "node", "bun", "deno", "python", "python3"]

    /// What only appears when one of `agentRuntimes` was launched by another program: a
    /// non-interactive run, an MCP server, or a browser-automation harness.
    static let agentMarkers = [
        "--print", "--dangerously-skip-permissions", "--output-format",
        "--non-interactive", "mcp serve", "mcp-server", "--headless",
        "puppeteer", "playwright",
    ]

    /// Where services live. Nothing under these is ever an orphan, whatever it is doing:
    /// `/opt/homebrew` and `/usr/local` are brew services, `/usr/bin`, `/usr/libexec`, `/sbin`,
    /// `/System` and `/Library` are the system's own, `/nix` is a nix profile.
    static let excludedPrefixes = [
        "/opt/homebrew/", "/usr/local/", "/usr/bin/", "/usr/sbin/", "/sbin/",
        "/usr/libexec/", "/System/", "/Library/", "/nix/",
    ]

    /// An XPC service or an app extension is started by the system on demand and stopped by it
    /// the same way — the `.xpc`/`.appex` in the path is the whole tell (SourceKitService).
    static let excludedFragments = [".xpc/", ".appex/"]

    /// Names that say "this is a service" on their own: `…d` (every daemon), plus these tokens
    /// anywhere in the name. Matched loosely on purpose — over-excluding costs a missed orphan,
    /// under-excluding puts a Stop button on `ssh-agent`.
    static let serviceNameTokens = ["-server", "agent", "daemon", "helper", "crashpad"]

    /// CPU below this is not worth waking someone up for, however abandoned the process is.
    static let minimumCPU = 20.0

    /// `~/Library/...` — where fnm, pyenv, nvm and every other per-user toolchain installs. Not a
    /// prefix constant because the home directory is not one.
    static func isUnderUserLibrary(_ path: String) -> Bool {
        if path.hasPrefix(NSHomeDirectory() + "/Library/") { return true }
        let components = (path as NSString).pathComponents
        guard components.count >= 5 else { return false }
        return components[0] == "/" && components[1] == "Users" && components[3] == "Library"
    }

    static func isExcludedPath(_ path: String) -> Bool {
        if excludedPrefixes.contains(where: { path.hasPrefix($0) }) { return true }
        if excludedFragments.contains(where: { path.contains($0) }) { return true }
        return isUnderUserLibrary(path)
    }

    static func isServiceName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if lowered.hasSuffix("d") { return true }
        return serviceNameTokens.contains { lowered.contains($0) }
    }

    /// The marker that makes this process automation, or nil when there is none — which is the
    /// answer for nearly everything at ppid 1.
    static func automationMarker(for candidate: SystemOrphanCandidate) -> String? {
        let command = candidate.command.lowercased()
        if let marker = automationMarkers.first(where: { command.contains($0) }) { return marker }

        let name = candidate.name.lowercased()
        guard agentRuntimes.contains(where: { name == $0 || name.hasPrefix($0 + "-") })
        else { return nil }
        return agentMarkers.first { command.contains($0) }
    }

    /// The candidates handed here are already ppid 1 and owned by the current user; the sampler
    /// cannot produce any other kind. Everything else this test needs is on the candidate.
    static func isOrphan(_ candidate: SystemOrphanCandidate) -> Bool {
        evidence(for: candidate) != nil
    }

    static func evidence(for candidate: SystemOrphanCandidate) -> String? {
        guard candidate.cpuPercent >= minimumCPU else { return nil }
        guard !isExcludedPath(candidate.path) else { return nil }
        guard !isServiceName(candidate.name) else { return nil }
        return automationMarker(for: candidate)
    }

    /// Which parent is gone cannot be recovered: by the time a process reads as ppid 1 the kernel
    /// has already replaced the dead parent with launchd, and nothing records what it was. So the
    /// reason names the parent it has *now*, which is the honest half of the story.
    static func reason(for candidate: SystemOrphanCandidate) -> String {
        guard let marker = evidence(for: candidate) else {
            return "no parent process left"
        }
        return "started by a script (\(marker)); its own parent has exited and launchd (pid 1) "
            + "adopted it"
    }

    static func scan(_ candidates: [SystemOrphanCandidate]) -> [OrphanedProcess] {
        candidates
            .filter { isOrphan($0) }
            .map {
                OrphanedProcess(
                    pid: $0.pid,
                    name: $0.name,
                    cpuPercent: $0.cpuPercent,
                    elapsed: $0.elapsed,
                    reason: reason(for: $0)
                )
            }
            .sorted { $0.cpuPercent > $1.cpuPercent }
    }
}
