import XCTest
@testable import Lookout

final class CodexDiscoveryMergeTests: XCTestCase {
    private func process(_ pid: Int32) -> Session {
        var row = Session()
        row.sessionID = "discovered-\(pid)"
        row.agent = .codex
        row.pid = pid
        row.host = .terminal
        row.hostPID = 4000
        row.shellPid = pid - 1
        row.tty = "ttys001"
        row.cwd = "/fictional/voyager"
        row.isDiscovered = true
        return row
    }

    private func rollout(_ id: String, desktop: Bool = false) -> Session {
        var row = Session()
        row.sessionID = id
        row.agent = .codex
        row.host = desktop ? .codexApp : .unknown
        row.transcriptPath = "/fictional/rollout-\(id).jsonl"
        row.cwd = "/fictional/voyager"
        row.title = "Fix the checkout flow"
        row.model = "gpt-6-astra"
        row.state = .working
        row.isDiscovered = true
        return row
    }

    func testOneCLIProcessAndItsOpenRolloutProduceOneActionableRow() throws {
        let rows = CodexDiscoveryMerge.merge(
            files: [], processes: [process(4242)], rollouts: [rollout("one")],
            openRollouts: { _ in ["/fictional/rollout-one.jsonl"] }
        )
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.sessionID, "one")
        XCTAssertEqual(row.pid, 4242)
        XCTAssertEqual(row.shellPid, 4241)
        XCTAssertEqual(row.hostPID, 4000)
        XCTAssertEqual(row.host, .terminal)
        XCTAssertEqual(row.tty, "ttys001")
        XCTAssertEqual(row.title, "Fix the checkout flow")
    }

    func testTwoCLISessionsInTheSameFolderAreMatchedByFileNotFolder() {
        let rows = CodexDiscoveryMerge.merge(
            files: [], processes: [process(4242), process(4244)],
            rollouts: [rollout("one"), rollout("two")],
            openRollouts: { pid in ["/fictional/rollout-\(pid == 4242 ? "one" : "two").jsonl"] }
        )
        XCTAssertEqual(rows.map(\.sessionID), ["one", "two"])
        XCTAssertEqual(rows.compactMap(\.pid), [4242, 4244])
    }

    func testDeniedDescriptorAccessKeepsTheProcessWithoutAddingADuplicate() {
        let rows = CodexDiscoveryMerge.merge(
            files: [], processes: [process(4242)], rollouts: [rollout("one")],
            openRollouts: { _ in [] }
        )
        XCTAssertEqual(rows, [process(4242)])
    }

    func testAmbiguousOwnershipDoesNotCombineTwoSessions() {
        let processes = [process(4242), process(4244)]
        let rows = CodexDiscoveryMerge.merge(
            files: [], processes: processes, rollouts: [rollout("shared")],
            openRollouts: { _ in ["/fictional/rollout-shared.jsonl"] }
        )
        XCTAssertEqual(rows, processes)
    }

    func testMultipleOpenRolloutsDoNotInventASessionIdentity() {
        let rows = CodexDiscoveryMerge.merge(
            files: [], processes: [process(4242)], rollouts: [rollout("one"), rollout("two")],
            openRollouts: { _ in ["/fictional/rollout-one.jsonl", "/fictional/rollout-two.jsonl"] }
        )
        XCTAssertEqual(rows, [process(4242)])
    }

    func testHookStateStillWinsOnIDOrPID() {
        var hook = rollout("one")
        hook.pid = 4242
        hook.state = .needsYou
        hook.isDiscovered = false
        let rows = CodexDiscoveryMerge.merge(
            files: [hook], processes: [process(4242)], rollouts: [rollout("one")],
            openRollouts: { _ in ["/fictional/rollout-one.jsonl"] }
        )
        XCTAssertEqual(rows, [hook])
    }

    func testDesktopThreadsNeedNoPIDButClosedCLIRolloutsAreNotLiveRows() {
        let desktop = rollout("desktop", desktop: true)
        let rows = CodexDiscoveryMerge.merge(
            files: [], processes: [], rollouts: [rollout("closed-cli"), desktop],
            openRollouts: { _ in XCTFail("No CLI candidates should mean no descriptor reads"); return [] }
        )
        XCTAssertEqual(rows, [desktop])
    }

    func testNativeLookupFindsOnlyTheRolloutFileOpenedByThisTest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beacon-fd-test-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rollout = root.appendingPathComponent("rollout-fixture.jsonl")
        let unrelated = root.appendingPathComponent("unrelated.txt")
        try Data().write(to: rollout)
        try Data().write(to: unrelated)
        let first = try FileHandle(forWritingTo: rollout)
        let second = try FileHandle(forWritingTo: unrelated)
        defer { try? first.close(); try? second.close() }
        let found = CodexProcessFiles.openRollouts(pid: getpid())
        // libproc spells the temp directory /private/var; Foundation may shorten it to /var.
        let urls = found.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
        XCTAssertTrue(urls.contains(rollout.standardizedFileURL.resolvingSymlinksInPath()))
        XCTAssertFalse(found.contains { $0.hasSuffix("/unrelated.txt") })
        XCTAssertTrue(CodexProcessFiles.openRollouts(pid: -1).isEmpty)

        var row = self.rollout("fixture")
        row.transcriptPath = rollout.path
        let merged = CodexDiscoveryMerge.merge(files: [], processes: [process(getpid())], rollouts: [row])
        XCTAssertEqual(merged.map(\.sessionID), ["fixture"], "Path aliases must also match in the live merge")
    }
}
