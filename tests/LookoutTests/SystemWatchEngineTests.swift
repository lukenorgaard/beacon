import Combine
import XCTest
@testable import Lookout

/// SPEC §18.6 / §18.7: the engine's lifecycle and the one thing it is allowed to do to the
/// machine. `stopProcess` is exercised against a real child process, because the guarantee that
/// matters — a recycled pid is never signalled — cannot be checked with a fake.
final class SystemWatchEngineTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    private func engine(
        _ state: SystemWatchState, cadence: SystemWatcher.Cadence = SystemWatcher.Cadence()
    ) -> SystemWatcher {
        SystemWatcher(
            state: state, sensitivity: { .balanced }, notificationsEnabled: { false },
            cadence: cadence
        )
    }

    /// Lets the main run loop turn for `seconds` — the engine publishes onto it, so a plain
    /// `Thread.sleep` here would stop the very thing being measured.
    private func settle(_ seconds: TimeInterval) {
        let waited = expectation(description: "\(seconds)s of run loop")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { waited.fulfill() }
        wait(for: [waited], timeout: seconds + 5)
    }

    func testACyclePublishesOnTheMainThread() {
        let state = SystemWatchState()
        let watcher = engine(state)
        let published = expectation(description: "a snapshot reaches the state object")
        published.assertForOverFulfill = false

        var onMainThread = false
        var processCount = 0
        state.$snapshot
            .compactMap { $0 }
            .sink { snapshot in
                onMainThread = Thread.isMainThread
                processCount = snapshot.processCount
                published.fulfill()
            }
            .store(in: &cancellables)

        watcher.start()
        wait(for: [published], timeout: 10)
        watcher.stop()

        XCTAssertTrue(onMainThread, "SPEC §18.1: the engine publishes on the main thread only")
        XCTAssertGreaterThan(processCount, 50)
        // The privileged probe backs off when its one `ps` fork is slow, which a loaded build
        // machine makes routine; that message is expected here, anything else is a real error.
        if let error = state.lastError {
            XCTAssertTrue(
                error.hasPrefix("System CPU check took"),
                "unexpected sampler error: \(error)"
            )
        }
    }

    func testStartingTwiceIsSafe() {
        let state = SystemWatchState()
        let watcher = engine(state)
        let published = expectation(description: "a snapshot reaches the state object")
        published.assertForOverFulfill = false
        state.$snapshot.compactMap { $0 }.sink { _ in published.fulfill() }.store(in: &cancellables)

        watcher.start()
        watcher.start()
        wait(for: [published], timeout: 10)
        watcher.stop()
    }

    func testStopEndsTheCycles() {
        let state = SystemWatchState()
        let watcher = engine(state)
        let first = expectation(description: "the first snapshot")
        first.assertForOverFulfill = false
        state.$snapshot.compactMap { $0 }.sink { _ in first.fulfill() }.store(in: &cancellables)

        watcher.start()
        wait(for: [first], timeout: 10)
        watcher.stop()
        cancellables.removeAll()

        // A cycle already in flight may still publish, so only what arrives after it could have
        // finished counts as a missed cancellation.
        let quiet = expectation(description: "nothing is published after stop")
        quiet.isInverted = true
        var counting = false
        state.$snapshot.sink { _ in if counting { quiet.fulfill() } }.store(in: &cancellables)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { counting = true }
        wait(for: [quiet], timeout: 2)
    }

    func testStoppingIsIdempotentAndSafeBeforeStart() {
        let watcher = engine(SystemWatchState())
        watcher.stop()
        watcher.stop()
    }

    // MARK: - stopProcess

    /// The outcome of one `stopProcess`, and how long the call itself took to hand back.
    private struct StopOutcome {
        var result: Result<Void, Error>
        var callReturnedAfter: TimeInterval
        var completedOnMainThread: Bool
    }

    /// Calls the engine the way the button does and waits for the answer, recording how long the
    /// *call* took as distinct from how long the stop took.
    private func stop(
        _ watcher: SystemWatcher, pid: Int32, expectedName: String,
        timeout: TimeInterval = 10
    ) -> StopOutcome {
        let answered = expectation(description: "the engine answers")
        var result: Result<Void, Error> = .failure(SystemWatchStopError.gone)
        var onMain = false

        let began = Date()
        watcher.stopProcess(pid: pid, expectedName: expectedName) {
            result = $0
            onMain = Thread.isMainThread
            answered.fulfill()
        }
        let returned = Date().timeIntervalSince(began)

        wait(for: [answered], timeout: timeout)
        return StopOutcome(
            result: result, callReturnedAfter: returned, completedOnMainThread: onMain
        )
    }

    /// SPEC §18.4, after the review: the stop waits out SIGTERM for up to two seconds and then
    /// another 200 ms after SIGKILL. Called inline from the button, that froze the whole app —
    /// panel, menu bar and every other tab — for over two seconds. The call has to come straight
    /// back and answer later, on the main thread, where the row's "Stopping…" is cleared.
    func testStopReturnsAtOnceAndAnswersLaterOnTheMainThread() throws {
        let child = try spawnSleeper()
        defer { terminate(child) }

        let outcome = stop(
            engine(SystemWatchState()), pid: child.processIdentifier, expectedName: "sleep"
        )
        XCTAssertLessThan(
            outcome.callReturnedAfter, 0.1,
            "the button's thread may not wait on SIGTERM (SPEC §18.4)"
        )
        XCTAssertTrue(outcome.completedOnMainThread)
        if case .failure(let error) = outcome.result {
            XCTFail("stop failed: \(error.localizedDescription)")
        }
        XCTAssertFalse(SystemWatcher.isRunning(child.processIdentifier))
    }

    func testStopRefusesAPidThatIsNoLongerWhatTheButtonSaid() throws {
        let child = try spawnSleeper()
        defer { terminate(child) }
        let pid = child.processIdentifier

        let outcome = stop(engine(SystemWatchState()), pid: pid, expectedName: "yes")
        switch outcome.result {
        case .success:
            XCTFail("a recycled pid must never be signalled")
        case .failure(let error):
            XCTAssertEqual(error as? SystemWatchStopError, .changed(actual: "sleep"))
            XCTAssertTrue(error.localizedDescription.contains("sleep"))
        }
        XCTAssertTrue(outcome.completedOnMainThread)
        XCTAssertTrue(child.isRunning, "the process must survive a refused stop")
    }

    func testStopEndsTheProcessWhenTheNameStillMatches() throws {
        let child = try spawnSleeper()
        defer { terminate(child) }
        let pid = child.processIdentifier

        XCTAssertEqual(SystemProcessSampler.liveName(of: pid), "sleep")
        let outcome = stop(engine(SystemWatchState()), pid: pid, expectedName: "sleep")
        if case .failure(let error) = outcome.result {
            XCTFail("stop failed: \(error.localizedDescription)")
        }
        XCTAssertFalse(SystemWatcher.isRunning(pid))
    }

    func testStopReportsAProcessThatIsAlreadyGone() {
        // pid 1 is launchd and can never be a Stop target; anything at or below it is refused
        // before a signal is anywhere near being sent.
        let outcome = stop(engine(SystemWatchState()), pid: 1, expectedName: "launchd")
        switch outcome.result {
        case .success: XCTFail("launchd must never be a stop target")
        case .failure(let error): XCTAssertEqual(error as? SystemWatchStopError, .gone)
        }
    }

    /// The engine the UI falls back to when Sentinel is off has to answer the same way — on main,
    /// with a failure — or the row would sit on "Stopping…" for ever.
    func testTheNoopEngineStillAnswersOnTheMainThread() {
        let answered = expectation(description: "the noop engine answers")
        var onMain = false
        var failed = false
        NoopSystemWatchEngine(state: SystemWatchState())
            .stopProcess(pid: 4242, expectedName: "runaway") { result in
                onMain = Thread.isMainThread
                if case .failure = result { failed = true }
                answered.fulfill()
            }
        wait(for: [answered], timeout: 5)
        XCTAssertTrue(onMain)
        XCTAssertTrue(failed)
    }

    // MARK: - Cadence (SPEC §18.6)

    func testTheDefaultCadenceIsTheOneTheSpecNames() {
        let cadence = SystemWatcher.Cadence()
        XCTAssertEqual(cadence.machine, 5, "the machine half never slows down — see `Cadence`")
        XCTAssertEqual(cadence.processVisible, 5)
        XCTAssertEqual(cadence.processHidden, 15, "only the expensive half is throttled")
        XCTAssertEqual(cadence.priming, 1)
    }

    /// SPEC §18.6, after the review: opening the tab used to inherit whatever deadline was already
    /// armed, so the gauges could sit on numbers up to a full interval old for as long as that
    /// deadline had left. The machine cadence here is far longer than the test, so a snapshot
    /// arriving after the flip can only be the one that opening the tab asked for.
    func testOpeningTheTabTakesAFreshSampleInsteadOfWaitingOutTheArmedDeadline() {
        let state = SystemWatchState()
        let watcher = engine(
            state,
            cadence: .init(machine: 60, processVisible: 60, processHidden: 60, priming: 0.5)
        )
        var count = 0
        state.$snapshot.compactMap { $0 }.sink { _ in count += 1 }.store(in: &cancellables)

        watcher.start()
        defer { watcher.stop() }

        // Let the priming cycles finish, then prove the engine is idle: nothing may arrive on its
        // own in the second and a half after that, or the flip below would prove nothing.
        settle(3)
        let settled = count
        XCTAssertGreaterThan(settled, 0, "the engine sampled at least once")
        settle(1.5)
        XCTAssertEqual(count, settled, "the 60 s deadline must be the one that is armed")

        let fresh = expectation(description: "opening the tab produces a sample")
        fresh.assertForOverFulfill = false
        state.$snapshot
            .compactMap { $0 }
            .dropFirst()
            .sink { _ in fresh.fulfill() }
            .store(in: &cancellables)
        state.isVisible = true
        wait(for: [fresh], timeout: 2.5)
    }

    // MARK: - Child process helpers

    private func spawnSleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        // Give the kernel a moment to make the executable path readable.
        Thread.sleep(forTimeInterval: 0.1)
        return process
    }

    private func terminate(_ process: Process) {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
}
