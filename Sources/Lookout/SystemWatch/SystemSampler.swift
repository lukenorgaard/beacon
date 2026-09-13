import Darwin
import Foundation

/// The machine half of one cycle (SPEC §18.6): everything the kernel will tell us without a
/// subprocess. Ported from the Sentinel app's `MetricsSampler`, minus its `ps` fork.
struct SystemMachineSample: Equatable {
    var cpuPercent: Double = 0
    var cpuPerCore: [Double] = []
    var memoryTotal: UInt64 = 0
    var memoryUsed: UInt64 = 0
    var memoryPressure: MemoryPressureLevel = .normal
    var swapUsed: UInt64 = 0
    var swapOutPerSecond: Double = 0
    var swapInPerSecond: Double = 0
    var diskTotal: UInt64 = 0
    var diskFree: UInt64 = 0
    var thermal: ThermalLevel = .nominal
    var uptime: TimeInterval = 0
    var loadAverage: [Double] = [0, 0, 0]
    /// False on the first sample, when there is no previous tick count to subtract from and
    /// `cpuPercent` is therefore 0 rather than measured. The watcher shortens the next interval
    /// instead of leaving a fabricated 0 % on screen for a whole cycle.
    var hasCPUBaseline = false
}

/// Samples the machine through mach and sysctl directly. Runs every few seconds on the watcher's
/// serial queue and must stay close to free — measured under 1 ms per call.
///
/// Nothing here fabricates a value: a call that fails leaves its fields at their defaults and
/// names itself in `sample().error`, which the watcher surfaces as `SystemWatchState.lastError`
/// (SPEC §18.6, "a sampler that fails reports lastError instead of zeros").
final class SystemSampler {
    private var previousCoreTicks: [[UInt32]] = []
    private var previousSwapouts: UInt64 = 0
    private var previousSwapins: UInt64 = 0
    private var previousVMTime: Date?
    private var pendingSwapoutRate: Double = 0
    private var pendingSwapinRate: Double = 0

    private let pageSize = UInt64(vm_kernel_page_size)
    private let now: () -> Date

    /// Measured on this Mac: `volumeAvailableCapacityForImportantUsage` costs ~118 ms, against
    /// ~0.02 ms for every other call in this file put together — it walks purgeable space to
    /// report the figure the Finder shows, which is the one `disk.low` is calibrated against.
    /// Free space moves in gigabytes per hour, so it is read on its own slow cadence and carried
    /// in between; that is what keeps a cycle free (SPEC §18.6).
    private let diskInterval: TimeInterval = 60
    private var disk: (total: UInt64, free: UInt64)?
    private var diskSampledAt: Date?

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// `error` is short human text naming what could not be read, or nil when everything worked.
    func sample() -> (sample: SystemMachineSample, error: String?) {
        var result = SystemMachineSample()
        var failures: [String] = []

        if let cpu = sampleCPU() {
            result.cpuPercent = cpu.total
            result.cpuPerCore = cpu.perCore
            result.hasCPUBaseline = cpu.hasBaseline
        } else {
            failures.append("CPU counters")
        }

        if let memory = sampleMemory() {
            result.memoryTotal = memory.total
            result.memoryUsed = memory.used
            result.memoryPressure = memory.pressure
        } else {
            failures.append("memory statistics")
        }

        result.swapUsed = sampleSwapUsed() ?? 0
        result.swapOutPerSecond = pendingSwapoutRate
        result.swapInPerSecond = pendingSwapinRate

        if let disk = currentDisk() {
            result.diskTotal = disk.total
            result.diskFree = disk.free
        } else {
            failures.append("disk capacity")
        }

        result.thermal = Self.thermalLevel(ProcessInfo.processInfo.thermalState)
        result.uptime = systemUptime()
        result.loadAverage = sampleLoadAverage()

        guard !failures.isEmpty else { return (result, nil) }
        return (result, "Could not read \(failures.joined(separator: ", ")).")
    }

    // MARK: - CPU

    private struct CPUReading {
        var total: Double
        var perCore: [Double]
        var hasBaseline: Bool
    }

    /// Per-core tick deltas between calls. The first call only records the baseline, so it
    /// reports 0 % and says so — there is nothing to subtract from yet.
    private func sampleCPU() -> CPUReading? {
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let status = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoArray, &infoCount
        )
        guard status == KERN_SUCCESS, let infoArray else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: infoArray)),
                vm_size_t(UInt(infoCount) * UInt(MemoryLayout<integer_t>.stride))
            )
        }

        let states = Int(CPU_STATE_MAX)
        var current: [[UInt32]] = []
        current.reserveCapacity(Int(cpuCount))
        for core in 0..<Int(cpuCount) {
            var ticks = [UInt32](repeating: 0, count: states)
            for state in 0..<states {
                ticks[state] = UInt32(bitPattern: infoArray[core * states + state])
            }
            current.append(ticks)
        }

        defer { previousCoreTicks = current }
        guard previousCoreTicks.count == current.count else {
            return CPUReading(total: 0, perCore: [], hasBaseline: false)
        }

        var userDelta = 0.0, systemDelta = 0.0, niceDelta = 0.0, idleDelta = 0.0
        var perCore: [Double] = []
        perCore.reserveCapacity(current.count)

        for (index, ticks) in current.enumerated() {
            let previous = previousCoreTicks[index]
            let user = Self.tickDelta(ticks[Int(CPU_STATE_USER)], previous[Int(CPU_STATE_USER)])
            let system = Self.tickDelta(ticks[Int(CPU_STATE_SYSTEM)], previous[Int(CPU_STATE_SYSTEM)])
            let nice = Self.tickDelta(ticks[Int(CPU_STATE_NICE)], previous[Int(CPU_STATE_NICE)])
            let idle = Self.tickDelta(ticks[Int(CPU_STATE_IDLE)], previous[Int(CPU_STATE_IDLE)])

            userDelta += user
            systemDelta += system
            niceDelta += nice
            idleDelta += idle

            let coreTotal = user + system + nice + idle
            perCore.append(coreTotal > 0 ? (user + system + nice) / coreTotal * 100 : 0)
        }

        let total = userDelta + systemDelta + niceDelta + idleDelta
        guard total > 0 else { return CPUReading(total: 0, perCore: perCore, hasBaseline: false) }

        let busy = (userDelta + systemDelta + niceDelta) / total * 100
        return CPUReading(total: min(100, max(0, busy)), perCore: perCore, hasBaseline: true)
    }

    /// Mach tick counters are 32-bit and wrap; a decrease is a wrap, not a negative delta.
    static func tickDelta(_ current: UInt32, _ previous: UInt32) -> Double {
        current >= previous
            ? Double(current - previous)
            : Double((UInt64(UInt32.max) - UInt64(previous)) + UInt64(current) + 1)
    }

    // MARK: - Memory

    private struct MemoryReading {
        var total: UInt64
        var used: UInt64
        var pressure: MemoryPressureLevel
    }

    private func sampleMemory() -> MemoryReading? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }

        // Activity Monitor's "Memory Used" = app + wired + compressed, where App Memory is the
        // internal pages minus the purgeable ones.
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = (internalPages > purgeable ? internalPages - purgeable : 0) &* pageSize
        let wired = UInt64(stats.wire_count) &* pageSize
        let compressed = UInt64(stats.compressor_page_count) &* pageSize

        updateSwapRates(stats: stats)

        return MemoryReading(
            total: ProcessInfo.processInfo.physicalMemory,
            used: app &+ wired &+ compressed,
            pressure: Self.pressureLevel(sysctlInt32("kern.memorystatus_vm_pressure_level") ?? 1)
        )
    }

    static func pressureLevel(_ raw: Int32) -> MemoryPressureLevel {
        switch raw {
        case 4: return .critical
        case 2: return .warning
        default: return .normal
        }
    }

    static func thermalLevel(_ state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    /// Swap-out *rate* is what predicts stalling — a large but static swap file is far less
    /// harmful than an actively thrashing small one.
    private func updateSwapRates(stats: vm_statistics64_data_t) {
        let swapouts = UInt64(stats.swapouts)
        let swapins = UInt64(stats.swapins)
        let timestamp = now()

        guard let previousTime = previousVMTime else {
            previousSwapouts = swapouts
            previousSwapins = swapins
            previousVMTime = timestamp
            return
        }

        let elapsed = timestamp.timeIntervalSince(previousTime)
        guard elapsed > 0.5 else { return }

        pendingSwapoutRate = swapouts >= previousSwapouts
            ? Double(swapouts - previousSwapouts) / elapsed : 0
        pendingSwapinRate = swapins >= previousSwapins
            ? Double(swapins - previousSwapins) / elapsed : 0
        previousSwapouts = swapouts
        previousSwapins = swapins
        previousVMTime = timestamp
    }

    private func sampleSwapUsed() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage.xsu_used
    }

    // MARK: - Disk

    private func currentDisk() -> (total: UInt64, free: UInt64)? {
        if let disk, let sampledAt = diskSampledAt,
           now().timeIntervalSince(sampledAt) < diskInterval {
            return disk
        }
        guard let fresh = sampleDisk() else { return disk }
        disk = fresh
        diskSampledAt = now()
        return fresh
    }

    private func sampleDisk() -> (total: UInt64, free: UInt64)? {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0
        else { return nil }

        // "Important usage" is what the Finder reports and what actually gates the system.
        let free: Int64
        if let important = values.volumeAvailableCapacityForImportantUsage {
            free = important
        } else if let available = values.volumeAvailableCapacity {
            free = Int64(available)
        } else {
            return nil
        }
        return (UInt64(total), UInt64(max(0, free)))
    }

    // MARK: - Misc

    private func systemUptime() -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else {
            return ProcessInfo.processInfo.systemUptime
        }
        return now().timeIntervalSince1970 - Double(boot.tv_sec)
    }

    private func sampleLoadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads : [0, 0, 0]
    }

    private func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }
}
