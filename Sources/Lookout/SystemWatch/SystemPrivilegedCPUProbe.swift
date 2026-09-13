import Darwin
import Foundation

/// One row of the pid list as the probe's selection sees it. Plain data so the choice of what to
/// fork for can be tested against a fabricated machine.
struct SystemProbeProcess: Equatable {
    var pid: Int32
    var uid: uid_t
    /// The kernel's 16-character `p_comm`, which is all `PROC_PIDT_SHORTBSDINFO` gives.
    var comm: String
    var path: String?
}

/// A process the probe will ask `ps` about.
struct SystemProbeCandidate: Equatable {
    var pid: Int32
}

/// One line of `ps -o pid=,%cpu=,comm=`.
struct SystemProbeReading: Equatable {
    var pid: Int32
    var cpuPercent: Double
    /// macOS `ps` prints the whole executable path for `comm`, which is what the display names
    /// and the owning-app lookup want anyway.
    var path: String
}

/// What one call to the probe produced, and what it cost.
struct SystemProbeRun {
    var output: String?
    var elapsed: TimeInterval
}

/// The one fork Lookout still pays for, and why it exists.
///
/// `proc_pid_rusage` and `proc_pidinfo` answer only for the current uid — measured here, 603 of
/// 875 pids. The two processes SPEC §18.2 cares most about are both outside that set: WindowServer
/// runs as uid 88, and a VPN or security system extension as root. macOS `ps` reads them because
/// `/bin/ps` is setuid root, and there is no unprivileged substitute (`kinfo_proc.p_pctcpu` is
/// zero on modern macOS — verified). So `helper.windowserver` and `helper.networkextension` can
/// only fire if something asks `ps`.
///
/// The cost is contained rather than avoided: at most one fork per process cycle, never on the
/// 5 s machine cycle, only for a handful of pids picked by name, and nothing at all when the
/// machine has none of them. Per-pid `%cpu` from `ps` is the decaying average macOS reports,
/// which is what the Sentinel app's thresholds were tuned against — so the numbers stay comparable.
final class SystemPrivilegedCPUProbe {
    /// A floor under the fork rate that holds no matter how often the caller samples. The watcher
    /// already limits process cycles to 15 s; this makes a burst harmless too.
    static let minimumInterval: TimeInterval = 14
    /// Over this, the probe stands down for `backoffCycles` process cycles and says so.
    static let budget: TimeInterval = 0.5
    static let timeout: TimeInterval = 2
    static let backoffCycles = 2
    /// Expected to be 1–10 in practice; the cap only bounds a pathological machine.
    static let maximumCandidates = 12

    private let now: () -> Date
    private let run: ([Int32]) -> SystemProbeRun
    private var lastRunAt: Date?
    private var skipCycles = 0
    private var cached: [SystemProbeReading] = []
    /// Short human text for `SystemWatchState.lastError`, or nil when the probe is healthy.
    private(set) var lastError: String?

    init(now: @escaping () -> Date = Date.init, run: (([Int32]) -> SystemProbeRun)? = nil) {
        self.now = now
        self.run = run ?? SystemPrivilegedCPUProbe.askPS
    }

    // MARK: - Selection

    /// Which other-uid processes are worth a fork. Own-uid processes are never included: their
    /// CPU already came from `proc_pid_rusage`, which is both cheaper and more precise.
    static func candidates(in processes: [SystemProbeProcess], ownUID: uid_t) -> [SystemProbeCandidate] {
        processes
            .filter { $0.uid != ownUID && isWorthProbing(comm: $0.comm, path: $0.path) }
            .sorted { $0.pid < $1.pid }
            .prefix(maximumCandidates)
            .map { SystemProbeCandidate(pid: $0.pid) }
    }

    /// The marker lists the rules match on, plus the two paths whose processes carry no usable
    /// name: a system extension's `comm` is a truncated bundle id.
    static func isWorthProbing(comm: String, path: String?) -> Bool {
        if comm == "WindowServer" { return true }
        if SystemMarkers.matches(comm, any: SystemMarkers.networkExtension) { return true }
        guard let path, !path.isEmpty else { return false }
        if path.hasSuffix("/WindowServer") { return true }
        if path.hasPrefix("/Library/SystemExtensions/") { return true }
        if path.hasPrefix("/System/Library/CoreServices/WindowServer") { return true }
        return SystemMarkers.matches(path, any: SystemMarkers.networkExtension)
    }

    // MARK: - Sampling

    /// `milliseconds` is 0 on every call that did not fork — which is most of them.
    func sample(_ candidates: [SystemProbeCandidate]) -> (readings: [SystemProbeReading], milliseconds: Double) {
        guard !candidates.isEmpty else {
            // A machine with no WindowServer and no security extension is not a machine with a
            // problem, so this is not an error and it costs nothing.
            cached = []
            lastError = nil
            return ([], 0)
        }

        let moment = now()
        if skipCycles > 0 {
            skipCycles -= 1
            return (cached, 0)
        }
        if let lastRunAt, moment.timeIntervalSince(lastRunAt) < Self.minimumInterval {
            return (cached, 0)
        }

        lastRunAt = moment
        let result = run(candidates.map(\.pid))

        guard let output = result.output else {
            cached = []
            lastError = "Could not read system process CPU."
            return ([], result.elapsed * 1000)
        }

        if result.elapsed > Self.budget {
            skipCycles = Self.backoffCycles
            lastError = String(
                format: "System CPU check took %.1fs; pausing it briefly.", result.elapsed
            )
        } else {
            lastError = nil
        }

        cached = Self.parse(output)
        return (cached, result.elapsed * 1000)
    }

    /// `comm` is last and is a path that may contain spaces, so only the first two fields split.
    static func parse(_ output: String) -> [SystemProbeReading] {
        var readings: [SystemProbeReading] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let fields = trimmed.split(
                maxSplits: 2, omittingEmptySubsequences: true,
                whereSeparator: { $0 == " " || $0 == "\t" }
            )
            guard fields.count == 3,
                  let pid = Int32(fields[0]),
                  let cpu = Double(fields[1]),
                  cpu.isFinite, cpu >= 0
            else { continue }
            readings.append(
                SystemProbeReading(pid: pid, cpuPercent: cpu, path: String(fields[2]))
            )
        }
        return readings
    }

    /// The live runner. `Shell.run` is already a `Foundation.Process` behind a hard deadline that
    /// escalates terminate → SIGKILL, which is exactly the contract this needs; it must never run
    /// on the main thread, and the watcher only ever calls the probe from its serial queue.
    private static func askPS(_ pids: [Int32]) -> SystemProbeRun {
        let began = Date()
        let result = Shell.run(
            "/bin/ps",
            ["-o", "pid=,%cpu=,comm=", "-p", pids.map(String.init).joined(separator: ",")],
            timeout: timeout
        )
        let elapsed = Date().timeIntervalSince(began)
        guard !result.timedOut, result.exitCode == 0, !result.stdout.isEmpty else {
            return SystemProbeRun(output: nil, elapsed: elapsed)
        }
        return SystemProbeRun(output: result.stdout, elapsed: elapsed)
    }
}
