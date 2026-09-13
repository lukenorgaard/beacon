import AppKit
import XCTest
@testable import Lookout

extension SentinelViewTests {
    // MARK: - SPEC §18.4: the actions

    /// A `SentinelActions` whose every side effect is recorded instead of performed.
    ///
    /// Both halves are asynchronous now — the confirmation is a sheet on the panel and the stop
    /// runs on the engine's queue — so the recorder holds the pending continuations and the test
    /// decides when each one answers. That is the whole point: it is what lets a test stand in the
    /// middle of a stop and look at what the row is showing.
    private final class Recorder {
        var confirmations: [(name: String, pid: Int32)] = []
        var stops: [(pid: Int32, name: String)] = []
        var activityMonitor = 0
        var systemSettings = 0
        var jumps: [String] = []
        /// nil answers the confirmation straight away with `confirm`; set it to hold the sheet
        /// open until the test answers by hand.
        var pendingConfirmation: ((Bool) -> Void)?
        var holdConfirmation = false
        var confirm = true
        var holdStop = false
        var pendingStop: ((Result<Void, Error>) -> Void)?
        var stopResult: Result<Void, Error> = .success(())
        var settingsAvailable = true

        func actions() -> SentinelActions {
            SentinelActions(
                confirmStop: { name, pid, completion in
                    self.confirmations.append((name, pid))
                    if self.holdConfirmation {
                        self.pendingConfirmation = completion
                    } else {
                        completion(self.confirm)
                    }
                },
                stopProcess: { pid, name, completion in
                    self.stops.append((pid, name))
                    if self.holdStop {
                        self.pendingStop = completion
                    } else {
                        completion(self.stopResult)
                    }
                },
                openActivityMonitor: {
                    self.activityMonitor += 1
                    return true
                },
                openSystemSettings: {
                    self.systemSettings += 1
                    return self.settingsAvailable
                },
                jump: { self.jumps.append($0) }
            )
        }
    }

    /// Runs an action to completion and hands back the inline message it produced.
    private func perform(
        _ action: SystemSignalAction, with actions: SentinelActions,
        onStopConfirmed: @escaping () -> Void = {}
    ) -> String? {
        var message: String?
        var completed = false
        actions.perform(action, onStopConfirmed: onStopConfirmed) {
            message = $0
            completed = true
        }
        XCTAssertTrue(completed, "the recorder answers synchronously unless the test holds it")
        return message
    }

    func testStoppingAProcessAsksFirstAndPassesThePidAndNameThrough() {
        let recorder = Recorder()
        let message = perform(.stopProcess(pid: 4242, name: "runaway"), with: recorder.actions())

        XCTAssertNil(message)
        XCTAssertEqual(recorder.confirmations.count, 1)
        XCTAssertEqual(recorder.confirmations.first?.pid, 4242)
        XCTAssertEqual(recorder.confirmations.first?.name, "runaway")
        XCTAssertEqual(recorder.stops.count, 1)
        XCTAssertEqual(recorder.stops.first?.pid, 4242)
        XCTAssertEqual(
            recorder.stops.first?.name, "runaway",
            "the engine needs the expected name to refuse a recycled pid (SPEC §18.4)"
        )
    }

    func testCancellingTheConfirmationNeverReachesTheEngineAndLeavesNoErrorBehind() {
        let recorder = Recorder()
        recorder.confirm = false

        var marked = false
        let message = perform(
            .stopProcess(pid: 4242, name: "runaway"), with: recorder.actions(),
            onStopConfirmed: { marked = true }
        )

        XCTAssertTrue(recorder.stops.isEmpty, "Cancel must not kill anything")
        XCTAssertNil(message, "a cancelled action is not a failure and shows no message")
        XCTAssertFalse(marked, "a cancelled stop never puts the row into its Stopping… state")
    }

    /// Nothing may happen while the sheet is still standing open — not the signal, and not the
    /// row's "Stopping…", which would be a lie about a stop the owner has not agreed to yet.
    func testNothingHappensWhileTheConfirmationIsStillOnScreen() {
        let recorder = Recorder()
        recorder.holdConfirmation = true

        var marked = false
        var message: String?
        var completed = false
        recorder.actions().perform(
            .stopProcess(pid: 4242, name: "runaway"),
            onStopConfirmed: { marked = true },
            completion: {
                message = $0
                completed = true
            }
        )

        XCTAssertEqual(recorder.confirmations.count, 1)
        XCTAssertTrue(recorder.stops.isEmpty)
        XCTAssertFalse(marked)
        XCTAssertFalse(completed)

        recorder.holdStop = true
        recorder.pendingConfirmation?(true)
        XCTAssertTrue(marked, "the row says Stopping… once the sheet is answered, not before")
        XCTAssertEqual(recorder.stops.count, 1)
        XCTAssertFalse(completed, "and it keeps saying it until the engine answers")

        recorder.pendingStop?(.success(()))
        XCTAssertTrue(completed)
        XCTAssertNil(message)
    }

    func testAFailedStopComesBackAsTheInlineMessageForTheRow() {
        let recorder = Recorder()
        recorder.stopResult = .failure(NSError(
            domain: "io.github.lukenorgaard.beacon.systemwatch", code: 9,
            userInfo: [NSLocalizedDescriptionKey: "pid 4242 is no longer runaway"]
        ))

        XCTAssertEqual(
            perform(.stopProcess(pid: 4242, name: "runaway"), with: recorder.actions()),
            "pid 4242 is no longer runaway"
        )
    }

    func testActivityMonitorAndSystemSettingsAreTheOtherTwoButtons() {
        let recorder = Recorder()
        let actions = recorder.actions()

        XCTAssertNil(perform(.openActivityMonitor, with: actions))
        XCTAssertEqual(recorder.activityMonitor, 1)
        XCTAssertTrue(recorder.stops.isEmpty, "no other side effect rides along")

        XCTAssertNil(perform(.openSystemSettings, with: actions))
        XCTAssertEqual(recorder.systemSettings, 1)
    }

    func testSettingsLaunchFailureAppearsInline() {
        let recorder = Recorder()
        recorder.settingsAvailable = false
        XCTAssertEqual(
            perform(.openSystemSettings, with: recorder.actions()),
            "Could not open System Settings"
        )
    }

    /// The row's own line does double duty: "Stopping…" while the engine is working, the failure
    /// after it answers. The height it occupies is the same either way, which is why the window
    /// does not have to be re-measured when a stop starts.
    func testTheRowSaysStoppingOnTheSameLineTheFailureWouldUse() {
        XCTAssertEqual(SentinelWarningRow.stoppingText, "Stopping…")
        // The button's own label never changes, so the text column beside it — measured from that
        // label — is the same width mid-stop as it was before, and the title cannot re-wrap inside
        // a frame the window sized for the narrower shape.
        let signal = SentinelViewTests.signal(
            "process.orphaned", .warning, minutesAgo: 3,
            action: .stopProcess(pid: 4242, name: "runaway")
        )
        XCTAssertEqual(Sentinel.buttonLabels(signal), ["Details", "Stop…"])
        let metrics = Theme.Metrics()
        XCTAssertGreaterThan(metrics.sentinelInlineErrorHeight, 0)
    }

    func testActionsUseBuiltInMacOSTools() {
        XCTAssertEqual(SentinelActions.activityMonitorBundleID, "com.apple.ActivityMonitor")
        XCTAssertEqual(SentinelActions.systemSettingsBundleID, "com.apple.systempreferences")
    }

    func testASignalWithASessionGetsAJumpThatCarriesTheSessionID() {
        let recorder = Recorder()
        let actions = recorder.actions()
        let signal = SentinelViewTests.signal(
            "process.orphaned", .critical, minutesAgo: 3, sessionID: "s-7"
        )
        signal.sessionID.map { actions.jump($0) }
        XCTAssertEqual(recorder.jumps, ["s-7"])
    }

    func testStoppingAProcessWithNoEngineRunningIsAnErrorRatherThanASilentNoOp() {
        // `start()` was never called, so no engine was ever built (SPEC §18.1).
        let answered = expectation(description: "the state answers even with no engine")
        var result: Result<Void, Error>?
        var onMain = false
        state.stopSystemProcess(pid: 4242, expectedName: "runaway") {
            result = $0
            onMain = Thread.isMainThread
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)

        XCTAssertTrue(onMain, "the row's Stopping… is cleared on the main thread")
        switch result {
        case .success, .none:
            XCTFail("a stop with nothing sampling must not report success")
        case let .failure(error):
            XCTAssertEqual((error as NSError).domain, "io.github.lukenorgaard.beacon.sentinel")
        }
    }
}
