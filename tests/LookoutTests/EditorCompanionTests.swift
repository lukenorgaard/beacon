import Darwin
import Foundation
import XCTest
@testable import Lookout

final class EditorCompanionTests: XCTestCase {
    var root: URL!
    private var home: LookoutHome!
    var server: FakeCompanionServer?

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-companion-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        home = LookoutHome(root: root)
    }

    override func tearDown() {
        server?.stop()
        server = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        home = nil
        super.tearDown()
    }

    // MARK: Helpers

    @discardableResult
    func writeInstance(
        app: String = "cursor",
        pid: Int32 = 4242,
        port: Int = 51234,
        token: String = "0123456789abcdef0123456789abcdef",
        folders: [String] = [],
        startedAt: String = "2026-09-03T09:12:44Z",
        overrides: [String: Any?] = [:]
    ) throws -> URL {
        var object: [String: Any] = [
            "app": app,
            "pid": Int(pid),
            "port": port,
            "token": token,
            "windowTitle": "acme-web",
            "folders": folders,
            "started_at": startedAt,
            "version": "0.1.0",
        ]
        for (key, value) in overrides {
            if let value { object[key] = value } else { object.removeValue(forKey: key) }
        }
        let directory = home.companion
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(app)-\(pid).json")
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
            .write(to: url)
        return url
    }

    func client(
        alive: @escaping (Int32) -> Bool = { _ in true }
    ) -> EditorCompanion {
        EditorCompanion(home: home, isAlive: alive)
    }

    static func terminal(
        index: Int, name: String, pid: Int?, active: Bool = false
    ) -> [String: Any] {
        [
            "index": index,
            "name": name,
            "processId": pid as Any? ?? NSNull(),
            "cwd": "/Users/you/Acme/repo",
            "creationOptions": ["cwd": "/Users/you/Acme/repo"],
            "isActive": active,
        ]
    }

    // MARK: - Scanning the state files (SPEC §16.2)

    func testALiveInstanceIsReadAndADeadOneIsDropped() throws {
        try writeInstance(app: "cursor", pid: 4242, port: 51_234)
        try writeInstance(app: "cursor", pid: 4243, port: 51_235)

        let found = client(alive: { $0 == 4242 }).instances(app: "cursor")
        XCTAssertEqual(found.map(\.pid), [4242], "kill(pid, 0) decides, not the file's existence")
        XCTAssertEqual(found.first?.port, 51_234)
        XCTAssertEqual(found.first?.token.value, "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(found.first?.windowTitle, "acme-web")
    }

    /// The liveness test itself, against the only two pids a test can be sure about.
    func testProcessLivenessUsesKillZero() {
        XCTAssertTrue(EditorCompanion.processIsAlive(getpid()))
        XCTAssertTrue(EditorCompanion.processIsAlive(1), "launchd is somebody else's, but alive")
        XCTAssertFalse(EditorCompanion.processIsAlive(0))
        XCTAssertFalse(EditorCompanion.processIsAlive(-1))
        // A pid above the kernel's maximum can never exist.
        XCTAssertFalse(EditorCompanion.processIsAlive(2_000_000))
    }

    func testInstancesAreFilteredByAppAndSortedNewestFirst() throws {
        try writeInstance(app: "cursor", pid: 10, port: 5001, startedAt: "2026-09-03T09:00:00Z")
        try writeInstance(app: "cursor", pid: 11, port: 5002, startedAt: "2026-09-03T11:00:00Z")
        try writeInstance(app: "devin", pid: 12, port: 5003, startedAt: "2026-09-03T10:00:00Z")

        let companion = client()
        XCTAssertEqual(companion.instances(app: "cursor").map(\.pid), [11, 10])
        XCTAssertEqual(companion.instances(app: "devin").map(\.pid), [12])
        XCTAssertEqual(companion.instances().map(\.pid), [11, 12, 10], "every app, newest first")
        XCTAssertTrue(companion.hasLiveInstance(app: "cursor"))
        XCTAssertFalse(companion.hasLiveInstance(app: "vscode"))
    }

    /// Everything a hand-edited, truncated or hostile file can be. None of them may produce an
    /// instance — and in particular a token that could break out of an HTTP header must not.
    func testMalformedStateFilesAreIgnored() throws {
        let directory = home.companion
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json at all".utf8)
            .write(to: directory.appendingPathComponent("cursor-1.json"))

        try writeInstance(app: "cursor", pid: 2, overrides: ["token": nil])
        try writeInstance(app: "cursor", pid: 3, overrides: ["port": 0])
        try writeInstance(app: "cursor", pid: 4, overrides: ["port": 70_000])
        try writeInstance(app: "cursor", pid: 5, overrides: ["app": "../../etc"])
        try writeInstance(app: "cursor", pid: 6, overrides: [
            "token": "abc\r\nX-Evil: 1",
        ])
        try writeInstance(app: "cursor", pid: 7, overrides: ["token": "short"])
        try writeInstance(app: "cursor", pid: 8, overrides: ["pid": 0])

        XCTAssertEqual(client().instances().count, 0, "nothing here is a usable companion")
    }

    /// SPEC §16.3's cache: a file whose size and modification date have not moved is not read
    /// again. Same-length garbage with the original timestamp proves it.
    func testAnUnchangedFileIsNotReadASecondTime() throws {
        let url = try writeInstance(app: "cursor", pid: 4242)
        // A whole-second stamp on both writes: `utimes` keeps microseconds, and the fresh file's
        // own nanosecond mtime would otherwise differ from anything set afterwards.
        let stamp = Date(timeIntervalSince1970: 1_756_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)

        let companion = client()
        XCTAssertEqual(companion.instances().count, 1)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        try Data(String(repeating: "x", count: size).utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)

        XCTAssertEqual(companion.instances().count, 1, "the cached parse is reused")
        XCTAssertEqual(client().instances().count, 0, "a cold client sees the garbage it is")

        // A new timestamp invalidates the entry, garbage and all.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path
        )
        XCTAssertEqual(companion.instances().count, 0)
    }

    func testAnOverriddenHomeNeverSharesTheAppWideClient() {
        XCTAssertTrue(EditorCompanion.client(home: home) !== EditorCompanion.shared)
        XCTAssertTrue(EditorCompanion.client(home: LookoutHome(environment: [:]))
            === EditorCompanion.shared)
    }

    // MARK: - The matching rules (SPEC §16.2)

    private func pair(
        _ terminal: CompanionTerminal, app: String = "cursor"
    ) -> (instance: CompanionInstance, terminal: CompanionTerminal) {
        (
            CompanionInstance(
                app: app, pid: 900, port: 1, token: SecretToken("abcdefabcdefabcdef"),
                windowTitle: nil, folders: [], startedAt: nil, version: nil,
                file: URL(fileURLWithPath: "/tmp/x.json")
            ),
            terminal
        )
    }

    func terminal(_ index: Int, _ name: String?, _ pid: Int32?) -> CompanionTerminal {
        CompanionTerminal(index: index, name: name, processId: pid, cwd: nil, isActive: false)
    }

    func testTheShellPidWinsOverEverything() {
        let terminals = [
            pair(terminal(0, "claude", 111)),
            pair(terminal(1, "zsh", 222)),
            pair(terminal(2, "claude — fe2", 333)),
        ]
        let found = EditorCompanion.match(
            shellPid: 222, agentCommand: "claude", in: terminals
        )
        XCTAssertEqual(found?.terminal.index, 1)
        XCTAssertEqual(found?.rule, .pid, "an exact pid beats two terminals named claude")
    }

    func testExactlyOneTerminalNamedAfterTheAgentIsTheFallback() {
        let terminals = [
            pair(terminal(0, "zsh", 111)),
            pair(terminal(1, "claude", 222)),
        ]
        let found = EditorCompanion.match(shellPid: 999, agentCommand: "claude", in: terminals)
        XCTAssertEqual(found?.terminal.index, 1)
        XCTAssertEqual(found?.rule, .name)

        // Case does not matter; the agent name is lower-cased on both sides.
        XCTAssertEqual(
            EditorCompanion.match(
                shellPid: nil, agentCommand: "CLAUDE",
                in: [pair(terminal(0, "Claude Code", 5))]
            )?.terminal.index,
            0
        )
    }

    func testTwoCandidatesOrNoneMeansNoMatchAtAll() {
        let ambiguous = [
            pair(terminal(0, "claude", 111)),
            pair(terminal(1, "claude 2", 222)),
        ]
        XCTAssertNil(
            EditorCompanion.match(shellPid: nil, agentCommand: "claude", in: ambiguous),
            "§16.2: only when *exactly* one matches — otherwise the old window jump"
        )
        XCTAssertNil(
            EditorCompanion.match(shellPid: 42, agentCommand: "codex", in: ambiguous)
        )
        XCTAssertNil(EditorCompanion.match(shellPid: 42, agentCommand: nil, in: ambiguous))
        XCTAssertNil(EditorCompanion.match(shellPid: nil, agentCommand: "claude", in: []))
        // A terminal whose pid the extension host could not await never matches by pid.
        XCTAssertNil(
            EditorCompanion.match(
                shellPid: 0, agentCommand: "codex", in: [pair(terminal(0, "zsh", nil))]
            )
        )
    }

    func testTheNameRuleSpansEveryWindowOfThatApp() {
        let terminals = [
            pair(terminal(0, "claude", 111), app: "cursor"),
            pair(terminal(0, "claude", 222), app: "cursor"),
        ]
        XCTAssertNil(
            EditorCompanion.match(shellPid: nil, agentCommand: "claude", in: terminals),
            "two windows each with a claude terminal is exactly the ambiguous case"
        )
    }
}
