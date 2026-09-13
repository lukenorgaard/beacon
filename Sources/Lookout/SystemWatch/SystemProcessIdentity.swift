import Darwin
import Foundation

/// A sampled process identity, excluding arguments, environment and browsing data.
struct SystemProcessIdentity: Equatable, Codable {
    var pid: Int32
    var name: String
    var path: String
    var uid: UInt32
    var startedAt: UInt64

    static func read(_ pid: Int32) -> SystemProcessIdentity? {
        guard let usage = SystemProcessSampler.rusage(of: pid),
              let info = SystemProcessSampler.shortInfo(of: pid),
              let path = SystemProcessSampler.path(of: pid),
              let verified = SystemProcessSampler.rusage(of: pid),
              usage.ri_proc_start_abstime == verified.ri_proc_start_abstime
        else { return nil }
        return Self(pid: pid, name: SystemProcessSampler.displayName(for: path), path: path,
                    uid: info.uid, startedAt: usage.ri_proc_start_abstime)
    }

    func canStop(ownUID: UInt32 = getuid(), ownPID: Int32 = getpid()) -> Bool {
        let protectedNames = ["launchd", "kernel_task", "WindowServer", "loginwindow",
                              "securityd", "tccd", "cfprefsd", "opendirectoryd"]
        return pid > 1 && pid != ownPID && uid == ownUID && startedAt > 0
            && !protectedNames.contains(name)
            && !["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"].contains {
                path.hasPrefix($0)
            }
    }

    var isChromeHelper: Bool {
        name.hasPrefix("Google Chrome Helper") && path.contains("/Google Chrome.app/")
            && path.contains("/Helpers/") && canStop()
    }
}

enum SystemProcessStopper {
    /// Returns a reason before any signal. Also used immediately before escalation.
    static func validate(
        current: SystemProcessIdentity, expected: SystemProcessIdentity
    ) -> SystemWatchStopError? {
        guard current == expected else { return .changedIdentity }
        guard current.canStop() else { return .protectedProcess }
        return nil
    }

    static func stop(
        pid: Int32, expectedName: String, expectedIdentity: SystemProcessIdentity?
    ) -> Result<Void, Error> {
        guard let current = SystemProcessIdentity.read(pid) else { return .failure(SystemWatchStopError.gone) }
        guard current.name == expectedName else {
            return .failure(SystemWatchStopError.changed(actual: current.name))
        }
        let expected = expectedIdentity ?? current
        if let error = validate(current: current, expected: expected) { return .failure(error) }
        guard kill(pid, SIGTERM) == 0 else {
            return .failure(errno == ESRCH ? SystemWatchStopError.gone : .denied)
        }

        // A monotonic clock keeps a wall-clock adjustment from extending the wait.
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            guard SystemWatcher.isRunning(pid) else { return .success(()) }
            guard SystemProcessIdentity.read(pid) == expected else { return .success(()) }
            usleep(50_000)
        }
        guard SystemWatcher.isRunning(pid) else { return .success(()) }
        guard let latest = SystemProcessIdentity.read(pid) else { return .success(()) }
        if let error = validate(current: latest, expected: expected) { return .failure(error) }
        guard kill(pid, SIGKILL) == 0 || errno == ESRCH else {
            return .failure(SystemWatchStopError.denied)
        }
        usleep(200_000)
        return !SystemWatcher.isRunning(pid) || SystemProcessIdentity.read(pid) != expected
            ? .success(()) : .failure(SystemWatchStopError.survived)
    }
}
