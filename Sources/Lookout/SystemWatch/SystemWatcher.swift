import Combine
import Darwin
import Foundation
import os

/// Why a Stop could not happen. Every case is a reason the user can act on, and the recycled-pid
/// case is the one that matters: the snapshot behind the button can be seconds old, and on a
/// machine churning through a thousand processes that is long enough for the number to belong to
/// something the user cares about.
enum SystemWatchStopError: LocalizedError, Equatable {
    case gone
    case changed(actual: String)
    case denied
    case survived
    case protectedProcess
    case changedIdentity

    var errorDescription: String? {
        switch self {
        case .protectedProcess:
            return "Beacon will not stop a protected process or a process owned by another user."
        case .changedIdentity:
            return "The process changed since it was selected. Refresh Sentinel and check it again."
        case .gone:
            return "It already exited."
        case .changed(let actual):
            return "That process id now belongs to \(actual)."
        case .denied:
            return "The system refused to stop it."
        case .survived:
            return "It did not exit, even after being force-quit."
        }
    }
}

/// The Sentinel tab's engine (SPEC §18.6): one serial queue does all the sampling, the main queue
/// only ever receives finished values.
///
/// `isVisible` lives on the main thread, so the queue never reads it directly — it is observed
/// once and mirrored into a locked flag, because a `DispatchQueue.main.sync` from a timer handler
/// is a deadlock waiting for the main thread to touch this object.
final class SystemWatcher: SystemWatchEngine {
    /// SPEC §18.6, split in two after the tab was hidden in normal use and the short rules stopped
    /// firing altogether.
    ///
    /// The *machine* half is 5 s whether or not the tab is on screen. It is the half every sustain
    /// window is measured in, and it costs 0.1–0.3 ms — dropping it to 15 s while hidden bought
    /// nothing measurable and left `call.atrisk` (20 s) and `memory.critical` (20 s) with two
    /// samples in their window, below the rules' sample floor, so they could never fire while the
    /// owner was looking at any other tab.
    ///
    /// The *process* half is the expensive one (~6 ms plus the privileged probe's fork), and it is
    /// the one that gets throttled while hidden. The rules that depend on it — orphans, runaways,
    /// Top CPU — all have windows far longer than 15 s.
    struct Cadence: Equatable {
        var machine: TimeInterval = 5
        var processVisible: TimeInterval = 5
        var processHidden: TimeInterval = 15
        /// Used only until the first delta exists, so the tab is not showing a fabricated idle
        /// machine for a whole interval after it opens.
        var priming: TimeInterval = 1
    }

    private let state: SystemWatchState
    private let sensitivity: () -> SystemWatchSensitivity

    private let queue = DispatchQueue(label: "io.github.lukenorgaard.beacon.sentinel", qos: .utility)
    private let log = Logger(subsystem: "io.github.lukenorgaard.beacon", category: "sentinel")
    private let sampler: SystemSampler
    private let processSampler: SystemProcessSampler
    private let rules: SystemRulesEngine
    private let notifier: SystemWatchNotifier
    private let now: () -> Date
    private let cadence: Cadence

    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var visible = false
    private var visibility: AnyCancellable?

    /// Queue-confined.
    private var processSample = SystemProcessSample()
    private var lastProcessSampleAt: Date?

    private let trace = ProcessInfo.processInfo.environment["LOOKOUT_SENTINEL_TRACE"] == "1"

    init(
        state: SystemWatchState,
        sensitivity: @escaping () -> SystemWatchSensitivity,
        notificationsEnabled: @escaping () -> Bool,
        now: @escaping () -> Date = Date.init,
        cadence: Cadence = Cadence()
    ) {
        self.state = state
        self.sensitivity = sensitivity
        self.now = now
        self.cadence = cadence
        self.sampler = SystemSampler(now: now)
        self.processSampler = SystemProcessSampler(now: now)
        self.rules = SystemRulesEngine(now: now)
        self.notifier = SystemWatchNotifier(
            sensitivity: sensitivity, notificationsEnabled: notificationsEnabled, now: now
        )
    }

    // MARK: - Engine

    func start() {
        lock.lock()
        guard timer == nil else {
            lock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        lock.unlock()

        timer.setEventHandler { [weak self] in self?.cycle() }
        timer.schedule(deadline: .now())
        timer.resume()

        notifier.register()
        observeVisibility()
    }

    func stop() {
        lock.lock()
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()

        // Cancelling the Combine subscription has to happen where it was made.
        if Thread.isMainThread {
            visibility = nil
        } else {
            DispatchQueue.main.async { [weak self] in self?.visibility = nil }
        }
    }

    /// SPEC §18.4. Returns immediately; the signalling and the waiting happen on the sampling
    /// queue and `completion` lands back on the main thread.
    ///
    /// The waiting is the reason. `perform` below spins for up to two seconds on SIGTERM and
    /// another 200 ms after SIGKILL — run inline from the button that asked for it, that is over
    /// two seconds of a frozen app (panel, menu bar, every other tab), on exactly the class of
    /// process least likely to honour a SIGTERM promptly. The row shows "Stopping…" instead.
    func stopProcess(
        pid: Int32, expectedName: String, expectedIdentity: SystemProcessIdentity? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async { [weak self] in
            let result = self.map { _ in SystemProcessStopper.stop(pid: pid, expectedName: expectedName, expectedIdentity: expectedIdentity) }
                ?? .failure(SystemWatchStopError.gone)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// A process that has exited but not yet been reaped still answers `kill(pid, 0)`, so a
    /// zombie has to be read as gone — otherwise stopping a child of this process always looks
    /// like a failure.
    static func isRunning(_ pid: Int32) -> Bool {
        var info = proc_bsdshortinfo()
        let size = proc_pidinfo(
            pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdshortinfo>.size)
        )
        guard size == Int32(MemoryLayout<proc_bsdshortinfo>.size) else { return false }
        /// `SZOMB` from `sys/proc.h`, which is not exported to Swift.
        let zombie: UInt32 = 5
        return info.pbsi_status != zombie
    }

    // MARK: - Cycle

    private func observeVisibility() {
        let install = { [weak self] in
            guard let self, self.visibility == nil else { return }
            self.visibility = self.state.$isVisible.sink { [weak self] isVisible in
                guard let self else { return }
                self.lock.lock()
                let opened = isVisible && !self.visible
                self.visible = isVisible
                let timer = self.timer
                self.lock.unlock()
                // Opening the tab has to produce a sample, not inherit the deadline the hidden
                // cadence armed: without this the gauges sit on numbers up to 15 s old for as long
                // as that deadline has left to run, which is the first thing anyone opening the tab
                // would notice. Re-arming for `.now()` is safe from any thread and at worst races
                // a cycle that was already in flight — which is the sample we wanted anyway.
                if opened { timer?.schedule(deadline: .now()) }
            }
        }
        if Thread.isMainThread { install() } else { DispatchQueue.main.async(execute: install) }
    }

    private func cycle() {
        let began = DispatchTime.now().uptimeNanoseconds
        let timestamp = now()

        let machine = sampler.sample()
        let machineNanoseconds = DispatchTime.now().uptimeNanoseconds - began

        var processNanoseconds: UInt64 = 0
        if isProcessSampleDue(at: timestamp) {
            let processBegan = DispatchTime.now().uptimeNanoseconds
            processSample = processSampler.sample()
            lastProcessSampleAt = timestamp
            processNanoseconds = DispatchTime.now().uptimeNanoseconds - processBegan
        }

        // A machine sample that could not read memory at all is not a machine at rest — it is a
        // machine we cannot see. Report that instead of publishing zeros (SPEC §18.6).
        guard machine.sample.memoryTotal > 0 else {
            publish(snapshot: nil, signals: nil, error: machine.error ?? "Could not read the machine.")
            reschedule(hasBaselines: false)
            return
        }
        // The privileged probe can be unavailable while everything else is fine, so its complaint
        // rides alongside the machine sampler's rather than replacing it.
        let error = [machine.error, processSample.probeError]
            .compactMap { $0 }
            .joined(separator: " ")

        let snapshot = makeSnapshot(machine.sample, at: timestamp)
        rules.record(snapshot)
        let signals = rules.evaluate(
            snapshot, thresholds: SystemThresholds.scaled(for: sensitivity())
        )
        notifier.process(signals)
        publish(snapshot: snapshot, signals: signals, error: error.isEmpty ? nil : error)

        let total = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
        log.debug(
            """
            cycle \(total, format: .fixed(precision: 2))ms \
            processes=\(snapshot.processes.count) signals=\(signals.count)
            """
        )
        if trace {
            let machineMs = Double(machineNanoseconds) / 1_000_000
            let processMs = Double(processNanoseconds) / 1_000_000
            FileHandle.standardError.write(Data(String(
                format: "sentinel-trace total=%.2fms machine=%.2fms process=%.2fms "
                    + "privileged=%.2fms processes=%d signals=%d\n",
                total, machineMs, processMs, processSample.privilegedMilliseconds,
                snapshot.processes.count, signals.count
            ).utf8))
        }

        reschedule(hasBaselines: machine.sample.hasCPUBaseline && processSample.hasBaseline)
    }

    private func isProcessSampleDue(at timestamp: Date) -> Bool {
        guard let last = lastProcessSampleAt else { return true }
        // Without a baseline every `cpuPercent` is 0, so the second sample is taken early rather
        // than leaving an idle-looking machine on screen for a full interval.
        if !processSample.hasBaseline { return true }
        lock.lock()
        let interval = visible ? cadence.processVisible : cadence.processHidden
        lock.unlock()
        return timestamp.timeIntervalSince(last) >= interval
    }

    private func makeSnapshot(_ machine: SystemMachineSample, at timestamp: Date) -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        snapshot.sampledAt = timestamp
        snapshot.cpuPercent = machine.cpuPercent
        snapshot.cpuPerCore = machine.cpuPerCore
        snapshot.memoryTotal = machine.memoryTotal
        snapshot.memoryUsed = machine.memoryUsed
        snapshot.memoryPressure = machine.memoryPressure
        snapshot.swapUsed = machine.swapUsed
        snapshot.swapOutPerSecond = machine.swapOutPerSecond
        snapshot.swapInPerSecond = machine.swapInPerSecond
        snapshot.diskTotal = machine.diskTotal
        snapshot.diskFree = machine.diskFree
        snapshot.thermal = machine.thermal
        snapshot.uptime = machine.uptime
        snapshot.loadAverage = machine.loadAverage
        snapshot.processCount = processSample.processCount
        snapshot.topApps = processSample.topApps
        snapshot.processes = processSample.processes
        snapshot.orphans = processSample.orphans
        snapshot.windowServerCPU = processSample.windowServerCPU
        snapshot.networkExtensionCPU = processSample.networkExtensionCPU
        return snapshot
    }

    /// The one place this class touches the state object (SPEC §18.1: main thread only).
    private func publish(snapshot: SystemSnapshot?, signals: [SystemSignal]?, error: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let snapshot { self.state.record(snapshot) }
            if let signals { self.state.signals = signals }
            self.state.lastError = error
        }
    }

    /// The machine half only. Visibility does not enter into it any more — see `Cadence`: this is
    /// the clock every sustain window is measured in, and slowing it down while the tab was hidden
    /// is what silenced the short rules.
    private func reschedule(hasBaselines: Bool) {
        lock.lock()
        let timer = self.timer
        lock.unlock()
        timer?.schedule(deadline: .now() + (hasBaselines ? cadence.machine : cadence.priming))
    }
}
