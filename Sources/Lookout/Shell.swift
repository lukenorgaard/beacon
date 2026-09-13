import Foundation

/// Minimal command runner with a hard deadline. Lookout only ever *reads* with this, or asks
/// another app to focus itself — it never kills or writes to another process (SPEC §5.6).
///
/// Never call this on the main thread.
enum Shell {
    /// How long a child gets to die after its deadline, at each of the three escalation steps
    /// (terminate → SIGKILL → drain). Kept small on purpose: SPEC §9.2 caps the click path at
    /// 2 s, and a jump's own timeout plus `timeoutOverhead` has to fit inside that.
    static let grace: TimeInterval = 0.2

    /// The most a call can spend *after* its `timeout` has elapsed. `run` therefore always
    /// returns within `timeout + timeoutOverhead`.
    static let timeoutOverhead: TimeInterval = 3 * grace

    struct Result {
        var stdout: String
        var exitCode: Int32
        var timedOut: Bool
    }

    /// Output crosses threads: the drain runs on a background queue while the caller polls.
    private final class OutputBox {
        private let lock = NSLock()
        private var data = Data()

        func set(_ value: Data) {
            lock.lock()
            data = value
            lock.unlock()
        }

        func get() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    /// `mergeStandardError` folds stderr into the same pipe as stdout. Off by default: the jump
    /// path only wants the value a helper printed, while the hook installer needs the error line
    /// python wrote before exiting (SPEC §10.2).
    ///
    /// `environment` and `currentDirectory` exist for the Claude suggester (SPEC §13.2), which
    /// has to unset the caller's `CLAUDE_*` variables and run inside the session's project. Both
    /// default to inheriting, which is what every other caller wants.
    @discardableResult
    static func run(
        _ launchPath: String,
        _ arguments: [String],
        timeout: TimeInterval = 10,
        mergeStandardError: Bool = false,
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil
    ) -> Result {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else {
            return Result(stdout: "", exitCode: -1, timedOut: false)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardInput = FileHandle.nullDevice
        if mergeStandardError {
            process.standardError = pipe
        } else {
            process.standardError = FileHandle.nullDevice
        }

        do {
            try process.run()
        } catch {
            return Result(stdout: "", exitCode: -1, timedOut: false)
        }

        // Drain concurrently: a full pipe buffer deadlocks a process we then wait on.
        let handle = pipe.fileHandleForReading
        let box = OutputBox()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.set(handle.readDataToEndOfFile())
            drained.signal()
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        if !wait(for: process, until: deadline) {
            timedOut = true
            process.terminate()
            if !wait(for: process, until: Date().addingTimeInterval(grace)) {
                kill(process.processIdentifier, SIGKILL)
                _ = wait(for: process, until: Date().addingTimeInterval(grace))
            }
        }

        // The drain thread only has to notice the EOF the exit above already caused. Give it
        // whatever is left of the caller's budget plus one grace period, so the whole call still
        // fits inside `timeout + timeoutOverhead` however the child behaved.
        let drainBudget = max(grace, deadline.timeIntervalSinceNow + grace)
        let completed = drained.wait(timeout: .now() + drainBudget) == .success
        let output = completed ? (String(data: box.get(), encoding: .utf8) ?? "") : ""
        let exitCode = process.isRunning ? -1 : process.terminationStatus
        return Result(stdout: output, exitCode: exitCode, timedOut: timedOut)
    }

    /// Polls instead of `waitUntilExit()` so every wait here has a deadline.
    private static func wait(for process: Process, until deadline: Date) -> Bool {
        while process.isRunning {
            if Date() >= deadline { return false }
            usleep(5_000)
        }
        return true
    }
}
