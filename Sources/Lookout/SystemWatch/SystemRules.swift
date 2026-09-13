import Foundation

/// Turns snapshots into diagnoses (SPEC §18.2), ported rule for rule from the Sentinel app's
/// `RulesEngine`: same ids, thresholds, sustain windows and wording.
///
/// Every rule requires its condition to *hold*: a machine that spikes to 100 % for three seconds
/// is working, not struggling. `now` is injected so the whole engine can be driven by hand-built
/// timestamps in a test — no rule test ever sleeps.
final class SystemRulesEngine {
    private var history: [SystemSnapshot] = []
    private let historyWindow: TimeInterval = 360
    /// When each rule id first fired in its current streak, so a warning's "for 12 m" does not
    /// reset itself every five seconds. An id that stops firing loses its entry and starts over.
    private var firstFired: [String: Date] = [:]
    let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func record(_ snapshot: SystemSnapshot) {
        history.append(snapshot)
        let cutoff = now().addingTimeInterval(-historyWindow)
        history.removeAll { $0.sampledAt < cutoff }
    }

    func evaluate(_ snapshot: SystemSnapshot, thresholds: SystemThresholds) -> [SystemSignal] {
        // Rolled up from the FULL process list, not from `topApps`: a CPU-ranked slice of eight
        // hands the memory rules a CPU-biased sample and makes them name the wrong app.
        let apps = SystemProcessSampler.rollUp(snapshot.processes)
        var signals: [SystemSignal] = []

        appendMemorySignals(snapshot, thresholds, apps, into: &signals)
        appendSwapSignal(snapshot, thresholds, apps, into: &signals)
        appendCPUSignals(snapshot, thresholds, apps, into: &signals)
        appendHelperSignals(snapshot, thresholds, into: &signals)
        appendDiskSignal(snapshot, thresholds, into: &signals)
        appendThermalSignal(snapshot, thresholds, into: &signals)
        appendUptimeSignal(snapshot, thresholds, into: &signals)
        appendSprawlSignal(snapshot, thresholds, apps, into: &signals)
        appendCallRiskSignal(snapshot, thresholds, into: &signals)

        return stamp(signals)
    }

    /// Gives every signal the moment its streak started and forgets the ids that stopped firing.
    private func stamp(_ signals: [SystemSignal]) -> [SystemSignal] {
        let moment = now()
        var streaks: [String: Date] = [:]
        var stamped = signals
        for index in stamped.indices {
            let id = stamped[index].id
            let since = firstFired[id] ?? moment
            stamped[index].since = since
            streaks[id] = since
        }
        firstFired = streaks
        // Ties broken by id so the tab's list does not reshuffle between identical evaluations.
        return stamped.sorted {
            $0.severity == $1.severity ? $0.id < $1.id : $0.severity > $1.severity
        }
    }

    // MARK: - Sustain helpers

    /// The cadence the engine is actually being fed at, measured from the history rather than
    /// assumed. A fixed sample floor is a silent trap: with a floor of 3 and a 15 s cadence, every
    /// rule whose window is under ~35 s could never fire at all, however bad the machine got —
    /// which is exactly what happened to `call.atrisk` and `memory.critical` while the tab was
    /// hidden. Deriving the interval means a future cadence change cannot re-open that hole.
    ///
    /// The median, not the mean: one long gap (the machine slept, a cycle overran) must not be
    /// able to talk the floor down.
    var sampleInterval: TimeInterval {
        guard history.count >= 2 else { return SystemRulesEngine.assumedInterval }
        var deltas: [TimeInterval] = []
        deltas.reserveCapacity(history.count - 1)
        for index in 1..<history.count {
            let delta = history[index].sampledAt.timeIntervalSince(history[index - 1].sampledAt)
            if delta > 0 { deltas.append(delta) }
        }
        guard !deltas.isEmpty else { return SystemRulesEngine.assumedInterval }
        return deltas.sorted()[deltas.count / 2]
    }

    /// What `sampleInterval` answers before there is any history to measure — SPEC §18.6's
    /// machine cadence.
    static let assumedInterval: TimeInterval = 5

    /// How many samples a window of `seconds` has to contain before the rule is allowed to speak.
    /// A window at cadence `i` holds `floor(seconds / i) + 1` samples, so asking for
    /// `seconds / i` always leaves one sample of slack and can never be unsatisfiable; the floor
    /// of 2 is what stops a single sample from counting as "sustained".
    func minimumSamples(for seconds: TimeInterval) -> Int {
        let interval = max(sampleInterval, 0.001)
        return max(2, Int(seconds / interval))
    }

    /// True only when the predicate holds across every sample in the trailing window *and* the
    /// window is actually covered — otherwise a freshly started app would fire instantly.
    func sustained(
        _ seconds: TimeInterval,
        _ predicate: (SystemSnapshot) -> Bool
    ) -> Bool {
        let moment = now()
        let cutoff = moment.addingTimeInterval(-seconds)
        let window = history.filter { $0.sampledAt >= cutoff }
        guard window.count >= minimumSamples(for: seconds), let oldest = window.first
        else { return false }
        guard moment.timeIntervalSince(oldest.sampledAt) >= seconds * 0.75 else { return false }
        return window.allSatisfy(predicate)
    }
}
