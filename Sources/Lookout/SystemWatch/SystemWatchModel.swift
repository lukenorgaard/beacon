import Foundation

// SPEC §18: the Sentinel tab. This file is the contract between the engine
// (`SystemWatch/*`, ported from the Sentinel app) and the tab UI (`SentinelView` and friends).
// Both sides compile against these types; neither renames them. The engine owns this file's
// `SystemWatch.makeEngine` body and nothing else in it; the UI never edits this file.

/// §18.2: `ok` is not a signal — a rule that fires always carries at least `info`.
enum SignalSeverity: Int, Comparable, Codable {
    case info = 1
    case warning = 2
    case critical = 3

    static func < (lhs: SignalSeverity, rhs: SignalSeverity) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .info: return "Info"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }
}

enum MemoryPressureLevel: Int, Codable {
    case normal = 1
    case warning = 2
    case critical = 4

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }
}

enum ThermalLevel: Int, Codable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        }
    }
}

/// One process as the rules see it. `appName` is the bundle the human would quit
/// (Chrome for a Chrome helper); `name` is the executable.
struct SystemProcessLoad: Identifiable, Equatable, Codable {
    var pid: Int32
    var name: String
    var appName: String?
    var cpuPercent: Double
    var residentBytes: UInt64

    var identity: SystemProcessIdentity? = nil

    var id: Int32 { pid }
    var actionableName: String { appName ?? name }
}

/// Several processes of one app rolled up (§18.3 "Top CPU"). `residentBytes` sums per-process
/// resident sizes, so shared pages count once per process: an upper bound, never exact.
struct SystemAppLoad: Identifiable, Equatable, Codable {
    var name: String
    var cpuPercent: Double
    var residentBytes: UInt64
    var processCount: Int

    var id: String { name }
}

/// A process whose parent is gone and that is still burning CPU (§18.2 `process.orphaned`).
struct OrphanedProcess: Identifiable, Equatable, Codable {
    var pid: Int32
    var name: String
    var cpuPercent: Double
    var elapsed: TimeInterval
    var reason: String

    var id: Int32 { pid }
}

/// One sample of the machine. Every field is plain data so a test can build one by hand.
struct SystemSnapshot: Equatable, Codable {
    var sampledAt: Date = Date()
    /// 0–100, whole machine.
    var cpuPercent: Double = 0
    var cpuPerCore: [Double] = []
    var memoryTotal: UInt64 = 0
    /// Activity Monitor's "Memory Used" (app + wired + compressed).
    var memoryUsed: UInt64 = 0
    var memoryPressure: MemoryPressureLevel = .normal
    var swapUsed: UInt64 = 0
    /// Pages per second since the previous sample.
    var swapOutPerSecond: Double = 0
    var swapInPerSecond: Double = 0
    var diskTotal: UInt64 = 0
    var diskFree: UInt64 = 0
    var thermal: ThermalLevel = .nominal
    var uptime: TimeInterval = 0
    var loadAverage: [Double] = [0, 0, 0]
    var processCount: Int = 0
    /// Sorted by CPU, at most eight.
    var topApps: [SystemAppLoad] = []
    /// Every sampled process, for the rules — the tab never lists this directly.
    var processes: [SystemProcessLoad] = []
    var orphans: [OrphanedProcess] = []
    var windowServerCPU: Double = 0
    var networkExtensionCPU: Double = 0

    var saturatedCores: Int { cpuPerCore.filter { $0 >= 90 }.count }
    var memoryUsedFraction: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }
    var diskFreeFraction: Double { diskTotal > 0 ? Double(diskFree) / Double(diskTotal) : 1 }
    var uptimeDays: Double { uptime / 86400 }
}

/// §18.4: the one button a warning may carry. Every case is reversible or confirmed:
/// stopping a process always asks first, and nothing here deletes a file.
enum SystemSignalAction: Equatable, Codable {
    case stopProcess(pid: Int32, name: String)
    case openActivityMonitor
    /// System Settings lets the user review General → Storage for disk warnings.
    case openSystemSettings

    var label: String {
        switch self {
        case .stopProcess: return "Stop…"
        case .openActivityMonitor: return "Activity Monitor"
        case .openSystemSettings: return "System Settings"
        }
    }
}

/// One fired rule. `id` is the stable rule id (`cpu.saturated`, `disk.low`, …) so the tab can
/// animate in place and the notifier can dedupe and cool down.
struct SystemSignal: Identifiable, Equatable, Codable {
    var id: String
    var severity: SignalSeverity
    var title: String
    var detail: String
    var advice: [String]
    /// The app the user could quit, when the rule points at one.
    var culprit: String?
    /// When this rule first fired in the current streak.
    var since: Date
    var action: SystemSignalAction?
    /// Set when the culprit is a Lookout session's own process — the row's Jump applies.
    var sessionID: String?

    var notificationTitle: String { title }
    var notificationBody: String {
        var parts = [detail]
        if let first = advice.first { parts.append(first) }
        return parts.joined(separator: " — ")
    }
}

/// §18.5 Settings → Sentinel.
enum SystemWatchSensitivity: String, CaseIterable, Codable {
    case criticalOnly
    case balanced
    case early

    var label: String {
        switch self {
        case .criticalOnly: return "Critical only"
        case .balanced: return "Balanced"
        case .early: return "Early warning"
        }
    }

    /// The lowest severity that gets a notification.
    var notifyAt: SignalSeverity {
        switch self {
        case .criticalOnly: return .critical
        case .balanced: return .warning
        case .early: return .info
        }
    }

    /// Threshold multiplier the rules apply (Sentinel's own numbers).
    var scale: Double {
        switch self {
        case .criticalOnly: return 1.6
        case .balanced: return 1.0
        case .early: return 0.5
        }
    }
}

/// What the tab observes. The engine publishes on the main thread only; the tab writes only
/// `isVisible`, which the engine reads for its cadence (§18.6: the machine sample stays at 5 s
/// either way, the expensive process sample drops from 5 s to 15 s while hidden) and to take a
/// fresh sample the moment the tab opens.
final class SystemWatchState: ObservableObject {
    @Published var snapshot: SystemSnapshot?
    @Published var signals: [SystemSignal] = []
    @Published var resourceHistory: [SystemResourceSample] = []
    /// A sampler that cannot run (no permission, sysctl failure) says so here instead of
    /// pretending the machine is idle.
    @Published var lastError: String?
    @Published var isVisible = false

    init() {}

    var worstSeverity: SignalSeverity? { signals.map(\.severity).max() }
}

/// The engine's surface. `SystemWatch.makeEngine` is the only place the UI meets a concrete type.
protocol SystemWatchEngine: AnyObject {
    func start()
    func stop()
    /// §18.4: kills `pid` only if it is still the process named `expectedName` — a recycled pid
    /// must never be hit. The caller has already confirmed with the user.
    ///
    /// Asynchronous, and not as a matter of taste: stopping a process means SIGTERM, then up to
    /// two seconds of waiting for it to go, then SIGKILL and another wait. Run from the button
    /// that asked for it, that froze the whole app — panel, menu bar and every other tab — for
    /// over two seconds on exactly the process least likely to honour a SIGTERM. The work happens
    /// on the engine's own queue; `completion` is called on the main thread.
    func stopProcess(
        pid: Int32, expectedName: String, expectedIdentity: SystemProcessIdentity?,
        completion: @escaping (Result<Void, Error>) -> Void
    )
}

extension SystemWatchEngine {
    func stopProcess(pid: Int32, expectedName: String, completion: @escaping (Result<Void, Error>) -> Void) {
        stopProcess(pid: pid, expectedName: expectedName, expectedIdentity: nil, completion: completion)
    }
}

/// Does nothing — what the UI wires against until the engine lands, and what a test that
/// only cares about the tab gets.
final class NoopSystemWatchEngine: SystemWatchEngine {
    let state: SystemWatchState
    init(state: SystemWatchState) { self.state = state }
    func start() {}
    func stop() {}
    func stopProcess(
        pid: Int32, expectedName: String, expectedIdentity: SystemProcessIdentity? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        // On main, like the real engine: the row's "Stopping…" state is cleared by this call, and
        // a caller that had to know which thread it lands on would be a caller that gets it wrong.
        DispatchQueue.main.async {
            completion(.failure(NSError(
                domain: "io.github.lukenorgaard.beacon.systemwatch", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "no engine"]
            )))
        }
    }
}

enum SystemWatch {
    /// The factory the app calls once. The engine lane replaces this body with its real
    /// `SystemWatcher`; the closures are read on every cycle so Settings changes apply live.
    static func makeEngine(
        state: SystemWatchState,
        sensitivity: @escaping () -> SystemWatchSensitivity,
        notificationsEnabled: @escaping () -> Bool
    ) -> SystemWatchEngine {
        SystemWatcher(
            state: state, sensitivity: sensitivity, notificationsEnabled: notificationsEnabled
        )
    }
}
