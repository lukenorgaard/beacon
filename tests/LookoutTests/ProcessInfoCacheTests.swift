import XCTest
@testable import Lookout

final class ProcessInfoCacheTests: XCTestCase {
    private func identity(_ pid: pid_t, _ seconds: Int64) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startSeconds: seconds, startMicroseconds: 0)
    }

    func info(_ command: String) -> CachedProcessInfo {
        CachedProcessInfo(command: command, comm: "claude", ppid: 1, hostSessionID: nil, sessionID: nil)
    }

    func testAStoredIdentityIsAHit() {
        let cache = ProcessInfoCache()
        let id = identity(100, 1_000)
        cache.store(id, info("original"))
        XCTAssertEqual(cache.lookup(id)?.command, "original")
    }

    func testAnIdentityThatWasNeverStoredIsAMiss() {
        let cache = ProcessInfoCache()
        XCTAssertNil(cache.lookup(identity(999, 1_000)))
    }

    /// The safety property the whole cache exists for: a pid the kernel recycled under a new
    /// start time must never serve the previous occupant's cached identity.
    func testAPidReusedUnderADifferentStartTimeIsAMiss() {
        let cache = ProcessInfoCache()
        cache.store(identity(100, 1_000), info("original-process"))
        XCTAssertNil(
            cache.lookup(identity(100, 2_000)),
            "a reused pid under a new start time must never see the old process's identity"
        )
        // The original identity is of course still there under its own exact key.
        XCTAssertEqual(cache.lookup(identity(100, 1_000))?.command, "original-process")
    }

    func testEvictDropsAnythingNotInTheLiveSet() {
        let cache = ProcessInfoCache()
        cache.store(identity(100, 1_000), info("a"))
        cache.store(identity(200, 1_000), info("b"))
        cache.evict(keeping: [identity(100, 1_000)])

        XCTAssertNotNil(cache.lookup(identity(100, 1_000)))
        XCTAssertNil(cache.lookup(identity(200, 1_000)), "not in the live set, must be gone")
        XCTAssertEqual(cache.count, 1)
    }

    func testEvictKeepsNothingWhenTheLiveSetIsEmpty() {
        let cache = ProcessInfoCache()
        cache.store(identity(100, 1_000), info("a"))
        cache.evict(keeping: [])
        XCTAssertEqual(cache.count, 0)
    }

    func testTheCacheNeverGrowsPastItsCapacity() {
        let cache = ProcessInfoCache(capacity: 4)
        for i in 0..<10 { cache.store(identity(pid_t(i), 1_000), info("p\(i)")) }
        XCTAssertLessThanOrEqual(cache.count, 4)
    }

    func testCachedPIDsReflectsAnyStartTime() {
        let cache = ProcessInfoCache()
        cache.store(identity(100, 1_000), info("a"))
        XCTAssertEqual(cache.cachedPIDs, [100])
    }
}

/// `entries(agentCommands:cache:source:)` driven entirely by fakes — a fake pid lister plus
/// fakes for every kernel call, so caching, candidate filtering and pid reuse are all provable
/// without a live process (task: process-scan cost).
final class ProcessSnapshotCachingTests: XCTestCase {
    /// Counts every call the production code would have paid a real syscall for.
    private final class CallLog {
        var pathCalls: [pid_t] = []
        var procargsCalls: [pid_t] = []
        var basicInfoCalls: [pid_t] = []
    }

    /// pid 90000 is a `claude` CLI candidate; pid 90001 is an ordinary, unrelated process that
    /// must never be treated as one. `claudeStart` is the candidate's process start time, so a
    /// test can simulate pid reuse simply by changing it between two calls.
    private func fakeSource(log: CallLog, claudeStart: Int64) -> ProcessInfoSource {
        ProcessInfoSource(
            listPIDs: { [90_000, 90_001] },
            shortInfo: { pid in
                switch pid {
                case 90_000: return (ppid: 1, comm: "claude")
                case 90_001: return (ppid: 1, comm: "loginwindow")
                default: return nil
                }
            },
            basicInfo: { pid in
                log.basicInfoCalls.append(pid)
                guard pid == 90_000 else { return nil }
                return ProcessBasicInfo(tty: "ttys005", startSeconds: claudeStart, startMicroseconds: 0)
            },
            path: { pid in
                log.pathCalls.append(pid)
                switch pid {
                case 90_000: return "/opt/homebrew/bin/claude"
                case 90_001: return "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"
                default: return nil
                }
            },
            procargs: { pid in
                log.procargsCalls.append(pid)
                guard pid == 90_000 else { return nil }
                return ProcessArguments(command: "claude --resume")
            }
        )
    }

    // MARK: Candidate filtering (task item 2)

    func testProcargsIsNeverReadForANonCandidateEvenColdEveryTick() {
        let log = CallLog()
        let entries = ProcessSnapshot.entries(
            agentCommands: ["claude"], cache: nil, source: fakeSource(log: log, claudeStart: 1_000)
        )
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(log.procargsCalls, [90_000], "only the candidate may ever pay for procargs")
        XCTAssertEqual(log.pathCalls, [90_000, 90_001], "path is still resolved for everyone")
    }

    // MARK: Cache hit / miss (task item 1)

    func testAColdCacheStillReadsPathAndProcargsOnce() {
        let log = CallLog()
        let cache = ProcessInfoCache()
        let entries = ProcessSnapshot.entries(
            agentCommands: ["claude"], cache: cache, source: fakeSource(log: log, claudeStart: 1_000)
        )
        XCTAssertEqual(entries.first { $0.pid == 90_000 }?.command, "/opt/homebrew/bin/claude claude --resume")
        XCTAssertEqual(log.pathCalls, [90_000, 90_001])
        XCTAssertEqual(log.procargsCalls, [90_000])
        XCTAssertEqual(cache.count, 1)
    }

    func testAWarmCacheHitSkipsPathAndProcargsForTheCandidate() {
        let cache = ProcessInfoCache()
        _ = ProcessSnapshot.entries(
            agentCommands: ["claude"], cache: cache, source: fakeSource(log: CallLog(), claudeStart: 1_000)
        )

        let log = CallLog()
        let entries = ProcessSnapshot.entries(
            agentCommands: ["claude"], cache: cache, source: fakeSource(log: log, claudeStart: 1_000)
        )
        XCTAssertFalse(log.pathCalls.contains(90_000), "a warm hit must never re-resolve the path")
        XCTAssertTrue(log.procargsCalls.isEmpty, "a warm hit must never re-read procargs")
        XCTAssertEqual(
            entries.first { $0.pid == 90_000 }?.command, "/opt/homebrew/bin/claude claude --resume",
            "the cached command must still come through on a hit"
        )
        // The non-candidate is never cached and is still resolved fresh every tick.
        XCTAssertTrue(log.pathCalls.contains(90_001))
    }

    /// The safety property from the file-level cache note, exercised end to end: a pid the fake
    /// pid lister keeps naming, but whose start time changes, must never be served stale data.
    func testAPidReusedUnderADifferentStartTimeForcesAFreshRead() {
        let cache = ProcessInfoCache()
        _ = ProcessSnapshot.entries(
            agentCommands: ["claude"], cache: cache, source: fakeSource(log: CallLog(), claudeStart: 1_000)
        )
        XCTAssertEqual(cache.count, 1)

        let log = CallLog()
        // Same pid (90000), a later start time: a different process now, not the same claude.
        let entries = ProcessSnapshot.entries(
            agentCommands: ["claude"], cache: cache, source: fakeSource(log: log, claudeStart: 2_000)
        )
        XCTAssertTrue(log.pathCalls.contains(90_000), "pid reuse must never be served from the stale entry")
        XCTAssertTrue(log.procargsCalls.contains(90_000))
        XCTAssertEqual(entries.first { $0.pid == 90_000 }?.command, "/opt/homebrew/bin/claude claude --resume")
    }

    func testAPidThatDisappearsIsEvictedFromTheCache() {
        let cache = ProcessInfoCache()
        _ = ProcessSnapshot.entries(
            agentCommands: ["claude"], cache: cache, source: fakeSource(log: CallLog(), claudeStart: 1_000)
        )
        XCTAssertEqual(cache.count, 1)

        let goneSource = ProcessInfoSource(
            listPIDs: { [90_001] },
            shortInfo: { $0 == 90_001 ? (ppid: 1, comm: "loginwindow") : nil },
            basicInfo: { _ in nil },
            path: { _ in "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow" },
            procargs: { _ in nil }
        )
        _ = ProcessSnapshot.entries(agentCommands: ["claude"], cache: cache, source: goneSource)
        XCTAssertEqual(cache.count, 0, "a pid no longer in the process list must not linger in the cache")
    }
}
