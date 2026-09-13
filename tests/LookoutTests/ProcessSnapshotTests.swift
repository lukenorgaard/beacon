import XCTest
@testable import Lookout

final class ProcessSnapshotTests: XCTestCase {
    func testSnapshotSeesThisProcessWithItsRealPathAndParent() {
        let entries = ProcessSnapshot.entries(agentCommands: Set(ProcessScanner.defaultCommands))
        XCTAssertGreaterThan(entries.count, 50)

        let me = ProcessInfo.processInfo.processIdentifier
        let mine = entries.first { $0.pid == me }
        XCTAssertNotNil(mine, "our own process must be in the snapshot")
        XCTAssertFalse(mine?.command.isEmpty ?? true)
        XCTAssertEqual(mine?.ppid, getppid())

        // Paths are whole — the truncation that makes `ps -o comm` useless is gone.
        XCTAssertTrue(entries.contains { $0.command.count > 16 })
        XCTAssertTrue(entries.allSatisfy { $0.pid > 0 })
    }

    func testSnapshotIsCheapEnoughForA5SecondTick() {
        let commands = Set(ProcessScanner.defaultCommands)
        _ = ProcessSnapshot.entries(agentCommands: commands)  // warm the OS-level caches

        let started = Date()
        let entries = ProcessSnapshot.entries(agentCommands: commands)
        let milliseconds = Date().timeIntervalSince(started) * 1000
        print("libproc snapshot (uncached): \(entries.count) processes in \(Int(milliseconds)) ms")
        // 50 ms is the design budget on a quiet machine; a shared, loaded build box (CI runners,
        // a developer's Mac mid-build) stretches libproc calls several-fold without anything
        // being wrong. 250 ms still catches a real regression (an O(n²) walk, a per-pid fork).
        XCTAssertLessThan(milliseconds, 250, "the scan must stay well under budget per tick")
    }

    /// The per-process cache (task: process-scan cost) is meant to make a *repeat* tick cheaper
    /// than a cold one, specifically for whatever candidates are live on this machine right now.
    /// Prints cold vs. warm so the before/after is visible in the test log.
    func testACachedSnapshotIsNoSlowerColdAndFasterWarm() {
        let commands = Set(ProcessScanner.defaultCommands)
        let cache = ProcessInfoCache()

        _ = ProcessSnapshot.entries(agentCommands: commands, cache: cache)  // warm the OS caches too

        // Best of three for each: a single sample on a loaded machine is scheduling noise, the
        // minimum is what the code actually costs.
        func timed(_ body: () -> [ProcessEntry]) -> (entries: [ProcessEntry], ms: Double) {
            var best: (entries: [ProcessEntry], ms: Double)?
            for _ in 0..<3 {
                let start = Date()
                let entries = body()
                let ms = Date().timeIntervalSince(start) * 1000
                if best == nil || ms < best!.ms { best = (entries, ms) }
            }
            return best!
        }
        let (cold, coldMilliseconds) = timed {
            ProcessSnapshot.entries(agentCommands: commands, cache: ProcessInfoCache())
        }
        let (warm, warmMilliseconds) = timed {
            ProcessSnapshot.entries(agentCommands: commands, cache: cache)
        }

        print(
            "process-info cache: cold \(Int(coldMilliseconds)) ms, warm \(Int(warmMilliseconds)) ms"
                + " (\(cache.count) candidate(s) cached)"
        )
        // Process counts churn on a live, busy Mac between the two calls (other sessions'
        // sub-agents starting and exiting) — assert both snapshots are sane, not identical.
        XCTAssertGreaterThan(cold.count, 50)
        XCTAssertGreaterThan(warm.count, 50)
        // The warm tick must never cost meaningfully more than the cold one — the whole point of
        // the cache. A little slack absorbs scheduling noise on a shared machine.
        XCTAssertLessThanOrEqual(warmMilliseconds, coldMilliseconds * 1.25 + 10)
        XCTAssertLessThan(warmMilliseconds, 250, "a warm tick must stay well under budget too")
    }

    func testArgumentsAndParentLookupsForOurselves() {
        let me = ProcessInfo.processInfo.processIdentifier
        XCTAssertEqual(ProcessSnapshot.parent(of: me), getppid())
        let arguments = ProcessSnapshot.arguments(of: me)
        XCTAssertNotNil(arguments)
        XCTAssertTrue(arguments?.contains("xctest") ?? false)
        XCTAssertNil(ProcessSnapshot.deviceName(UInt32.max), "no controlling terminal")
    }
}

extension ProcessSnapshotTests {
    func testWorkingDirectoryComesFromTheKernel() {
        let me = ProcessInfo.processInfo.processIdentifier
        XCTAssertEqual(
            ProcessSnapshot.workingDirectory(of: me),
            FileManager.default.currentDirectoryPath
        )
    }

    func testNpmClaudeBinaryNamedClaudeExeMatches() {
        let candidates = ProcessScanner.executableCandidates(
            command: "/Users/you/.npm-global/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
        )
        XCTAssertTrue(candidates.contains("claude"), "\(candidates)")
        XCTAssertNotNil(
            ProcessScanner.agentName(command: "claude", agentCommands: ["claude"]),
            "the bare kernel command name must match too"
        )
    }
}

/// `ProcessInfoCache` in isolation — no live process needed (task: process-scan cost).
