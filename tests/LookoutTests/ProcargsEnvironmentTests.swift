import XCTest
@testable import Lookout

/// SPEC §9.1: the `KERN_PROCARGS2` buffer holds argv *and* the environment block, and a discovered
/// desktop session's ids live in there. The environment also carries `CLAUDE_CODE_OAUTH_TOKEN`
/// (SPEC §2.1), so the hard requirement is not just "read the two keys" — it is "read nothing
/// else, ever". Both halves are asserted here.
final class ProcargsEnvironmentTests: XCTestCase {
    private static let decoy = "LOOKOUT_TEST_SECRET"
    private static let decoyValue = "sk-ant-oat01-never-read-this"

    /// The exact layout the kernel writes: argc, exec path, alignment NULs, argv, envp.
    private func buffer(
        argc: Int32? = nil,
        execPath: String = "/opt/homebrew/bin/claude",
        argv: [String],
        environment: [String],
        padding: Int = 3
    ) -> [UInt8] {
        var bytes = [UInt8]()
        var count = argc ?? Int32(argv.count)
        withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: Array(execPath.utf8))
        bytes.append(0)
        bytes.append(contentsOf: [UInt8](repeating: 0, count: padding))
        for argument in argv {
            bytes.append(contentsOf: Array(argument.utf8))
            bytes.append(0)
        }
        for entry in environment {
            bytes.append(contentsOf: Array(entry.utf8))
            bytes.append(0)
        }
        return bytes
    }

    private var noisyEnvironment: [String] {
        [
            "SHELL=/bin/zsh",
            "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-abcdefghijklmnop",
            "\(Self.decoy)=\(Self.decoyValue)",
            "CLAUDE_CODE_HOST_SESSION_ID=local_9c1d6e204a7f11ef",
            "CLAUDE_CODE_ENTRYPOINT=claude-desktop",
            "CLAUDE_CODE_SESSION_ID=1d9e4b77-0c52-4a36-8f21-77a5c3b9d401",
            "PATH=/usr/bin:/bin",
        ]
    }

    // MARK: - The parser

    func testTheTwoAllowedKeysComeOutOfTheEnvironmentBlock() throws {
        let parsed = try XCTUnwrap(
            ProcessSnapshot.parse(
                procargs: buffer(argv: ["claude", "--resume"], environment: noisyEnvironment),
                environment: true
            )
        )
        XCTAssertEqual(parsed.hostSessionID, "local_9c1d6e204a7f11ef")
        XCTAssertEqual(parsed.sessionID, "1d9e4b77-0c52-4a36-8f21-77a5c3b9d401")
        XCTAssertEqual(parsed.command, "/opt/homebrew/bin/claude claude --resume")
    }

    /// The whole point of §9.1's "never log env": no other entry may come back in *any* field.
    func testNoOtherEnvironmentStringIsEverReturned() throws {
        let parsed = try XCTUnwrap(
            ProcessSnapshot.parse(
                procargs: buffer(argv: ["claude"], environment: noisyEnvironment),
                environment: true
            )
        )
        let everything = [parsed.command, parsed.hostSessionID ?? "", parsed.sessionID ?? ""]
            .joined(separator: "\u{0}")
        for forbidden in [Self.decoy, Self.decoyValue, "OAUTH", "sk-ant-oat01", "SHELL", "PATH="] {
            XCTAssertFalse(everything.contains(forbidden), "\(forbidden) leaked out of the buffer")
        }
    }

    func testTheEnvironmentBlockIsNotEvenWalkedWhenItIsNotAskedFor() throws {
        let parsed = try XCTUnwrap(
            ProcessSnapshot.parse(
                procargs: buffer(argv: ["claude"], environment: noisyEnvironment),
                environment: false
            )
        )
        XCTAssertNil(parsed.hostSessionID)
        XCTAssertNil(parsed.sessionID)
        XCTAssertEqual(parsed.command, "/opt/homebrew/bin/claude claude")
    }

    func testKeysAreMatchedWholeAndNotByPrefix() throws {
        let parsed = try XCTUnwrap(
            ProcessSnapshot.parse(
                procargs: buffer(
                    argv: ["claude"],
                    environment: [
                        "CLAUDE_CODE_SESSION_ID_BACKUP=nope",
                        "XCLAUDE_CODE_SESSION_ID=nope",
                        "CLAUDE_CODE_SESSION_IDX=nope",
                        "CLAUDE_CODE_HOST_SESSION_ID=local_real",
                    ]
                ),
                environment: true
            )
        )
        XCTAssertEqual(parsed.hostSessionID, "local_real")
        XCTAssertNil(parsed.sessionID, "no near-miss key may satisfy the exact-key match")
    }

    func testAValueWithNoContentOrAnAbsurdLengthIsIgnored() throws {
        let long = String(repeating: "x", count: ProcessSnapshot.maxEnvironmentValue + 1)
        let parsed = try XCTUnwrap(
            ProcessSnapshot.parse(
                procargs: buffer(
                    argv: ["claude"],
                    environment: [
                        "CLAUDE_CODE_SESSION_ID=",
                        "CLAUDE_CODE_HOST_SESSION_ID=\(long)",
                    ]
                ),
                environment: true
            )
        )
        XCTAssertNil(parsed.sessionID, "`KEY=` with no value is not a value")
        XCTAssertNil(parsed.hostSessionID, "an absurd value is never copied out")
    }

    func testEmptyArgumentsAndOddPaddingSurviveTheWalk() throws {
        let parsed = try XCTUnwrap(
            ProcessSnapshot.parse(
                procargs: buffer(
                    argv: ["claude", "", "--model", "opus"],
                    environment: ["CLAUDE_CODE_SESSION_ID=abc"],
                    padding: 0
                ),
                environment: true
            )
        )
        XCTAssertEqual(parsed.sessionID, "abc", "an empty argv entry must not end the walk")
    }

    func testMalformedBuffersAreRejectedInsteadOfCrashing() {
        XCTAssertNil(ProcessSnapshot.parse(procargs: [], environment: true))
        XCTAssertNil(ProcessSnapshot.parse(procargs: [1, 0, 0, 0], environment: true))
        XCTAssertNil(
            ProcessSnapshot.parse(procargs: [0, 0, 0, 0, 65, 66, 67, 0, 0], environment: true),
            "argc 0 is not a process"
        )

        // Truncated mid-environment: whatever is intact still parses, nothing reads past the end.
        var truncated = buffer(argv: ["claude"], environment: noisyEnvironment)
        truncated.removeLast(20)
        XCTAssertNotNil(ProcessSnapshot.parse(procargs: truncated, environment: true))
    }

    // MARK: - Against a live process

    /// `setenv` cannot be used for this: `KERN_PROCARGS2` returns the exec-time stack copy, and a
    /// variable added later lives on the heap, so it is invisible there (measured on this Mac).
    /// The only way to assert the real kernel path is a child launched with a known environment.
    ///
    /// The child cannot be `/bin/sleep` either: macOS returns *only* argv for another process
    /// that is a platform binary, and the whole `/bin`, `/usr/bin` tree is one. Measured here —
    /// `/bin/sleep` gives 29 bytes and no environment at all, a plain copy of the same binary
    /// gives the environment in full, and so do the real Claude Code processes on this Mac
    /// (`CLAUDE_CODE_HOST_SESSION_ID=local_…` read back from two live desktop sessions), which
    /// is exactly the case SPEC §9.1 needs. So the child is an unsigned copy of `sleep`.
    func testALiveChildProcessYieldsExactlyTheTwoKeys() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-procargs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("sleep")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: binary)

        let child = Process()
        child.executableURL = binary
        child.arguments = ["30"]
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CODE_HOST_SESSION_ID"] = "local_livechild123"
        environment["CLAUDE_CODE_SESSION_ID"] = "7c1f0a52-9d34-4b88-b0a1-3e9d7c22aa10"
        environment["CLAUDE_CODE_OAUTH_TOKEN"] = "sk-ant-oat01-live-child"
        environment[Self.decoy] = Self.decoyValue
        child.environment = environment
        try child.run()
        defer {
            child.terminate()
            child.waitUntilExit()
        }

        let parsed = try XCTUnwrap(
            ProcessSnapshot.procargs(of: child.processIdentifier, environment: true)
        )
        XCTAssertEqual(parsed.hostSessionID, "local_livechild123")
        XCTAssertEqual(parsed.sessionID, "7c1f0a52-9d34-4b88-b0a1-3e9d7c22aa10")
        XCTAssertTrue(parsed.command.contains("sleep"))

        let everything = [parsed.command, parsed.hostSessionID ?? "", parsed.sessionID ?? ""]
            .joined(separator: "\u{0}")
        XCTAssertFalse(everything.contains(Self.decoy))
        XCTAssertFalse(everything.contains(Self.decoyValue))
        XCTAssertFalse(everything.contains("sk-ant-oat01"))

        // …and with `environment: false` the block is never touched at all.
        let quiet = try XCTUnwrap(
            ProcessSnapshot.procargs(of: child.processIdentifier, environment: false)
        )
        XCTAssertNil(quiet.hostSessionID)
        XCTAssertNil(quiet.sessionID)
    }

    /// Reading our own pid: a `setenv` decoy is not in the exec-time environment and therefore
    /// can never come back — the safety property holds from both directions.
    func testOurOwnProcessNeverHandsBackASetenvDecoy() throws {
        setenv(Self.decoy, Self.decoyValue, 1)
        setenv("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-in-our-own-heap", 1)
        defer {
            unsetenv(Self.decoy)
            unsetenv("CLAUDE_CODE_OAUTH_TOKEN")
        }

        let me = ProcessInfo.processInfo.processIdentifier
        let parsed = try XCTUnwrap(ProcessSnapshot.procargs(of: me, environment: true))
        XCTAssertTrue(parsed.command.contains("xctest"))
        let everything = [parsed.command, parsed.hostSessionID ?? "", parsed.sessionID ?? ""]
            .joined(separator: "\u{0}")
        XCTAssertFalse(everything.contains(Self.decoy))
        XCTAssertFalse(everything.contains(Self.decoyValue))
        XCTAssertFalse(everything.contains("sk-ant-oat01"))
    }

    /// An id out of another process's environment is untrusted input.
    func testIdentifiersFromTheEnvironmentAreSanitised() {
        XCTAssertEqual(ProcessScanner.sanitisedIdentifier("local_abc-123.x"), "local_abc-123.x")
        XCTAssertEqual(ProcessScanner.sanitisedIdentifier(" abc "), "abc")
        XCTAssertNil(ProcessScanner.sanitisedIdentifier(nil))
        XCTAssertNil(ProcessScanner.sanitisedIdentifier(""))
        XCTAssertNil(ProcessScanner.sanitisedIdentifier("../../etc/passwd"))
        XCTAssertNil(ProcessScanner.sanitisedIdentifier("abc def"))
        XCTAssertNil(ProcessScanner.sanitisedIdentifier("a&b=c"))
        XCTAssertNil(ProcessScanner.sanitisedIdentifier(String(repeating: "a", count: 129)))
    }
}

/// SPEC §9.1, the part the live machine taught us: an environment variable is *inherited*, not
/// owned. A Cursor or Devin integrated terminal carries whatever `CLAUDE_CODE_SESSION_ID` the
/// session that opened it had, so on this Mac four unrelated Devin sessions all reported the
/// same id. Adopting that id would let one session's hook file swallow three other rows.
final class DiscoveredIdentityTests: XCTestCase {
    private func entry(
        pid: Int32, ppid: Int32, command: String,
        hostSessionID: String? = nil, sessionID: String? = nil
    ) -> ProcessEntry {
        ProcessEntry(
            pid: pid, ppid: ppid, tty: nil, command: command,
            hostSessionID: hostSessionID, sessionID: sessionID
        )
    }

    private var tree: [ProcessEntry] {
        [
            entry(pid: 1, ppid: 0, command: "/sbin/launchd"),
            entry(pid: 4300, ppid: 1, command: "/Applications/Devin.app/Contents/MacOS/Devin"),
            entry(pid: 4301, ppid: 4300, command: "/Applications/Devin.app/Devin Helper"),
            entry(pid: 3700, ppid: 1, command: "/Applications/Claude.app/Contents/MacOS/Claude"),
        ]
    }

    /// The measured case: two Devin terminals, same inherited id, neither of them a desktop
    /// session — so neither adopts it.
    func testTerminalSessionsNeverAdoptAnInheritedSessionID() {
        let entries = tree + [
            entry(pid: 70600, ppid: 4301, command: "/opt/homebrew/bin/claude",
                  sessionID: "f40578fd-95f1-4460-bf64-1a19318bac14"),
            entry(pid: 93797, ppid: 4301, command: "/opt/homebrew/bin/claude",
                  sessionID: "f40578fd-95f1-4460-bf64-1a19318bac14"),
        ]
        let found = ProcessScanner.discover(
            entries: entries, agentCommands: ["claude"], coveredPIDs: []
        )
        XCTAssertEqual(found.map(\.pid), [70600, 93797])
        XCTAssertEqual(found.map(\.host), [.devin, .devin])
        XCTAssertTrue(found.allSatisfy { $0.sessionID == nil })
        XCTAssertTrue(found.allSatisfy { $0.hostRef == nil })
    }

    func testADesktopSessionAdoptsBothIDs() {
        let entries = tree + [
            entry(pid: 31844, ppid: 3700, command: "/Users/you/Library/…/claude",
                  hostSessionID: "local_060ba98a-3da7-4d5c-a641-c173ffc87ce4",
                  sessionID: "1d9e4b77-0c52-4a36-8f21-77a5c3b9d401")
        ]
        let found = ProcessScanner.discover(
            entries: entries, agentCommands: ["claude"], coveredPIDs: []
        )
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].host, .claudeDesktop)
        XCTAssertEqual(found[0].sessionID, "1d9e4b77-0c52-4a36-8f21-77a5c3b9d401")
        XCTAssertEqual(found[0].hostRef, "local_060ba98a-3da7-4d5c-a641-c173ffc87ce4")
        XCTAssertNotNil(Jumper.desktopLink(hostRef: found[0].hostRef))
    }

    /// The real desktop sessions on this Mac carry the host id but no `CLAUDE_CODE_SESSION_ID`,
    /// so the row keeps the synthetic id and still jumps correctly.
    func testADesktopSessionWithNoSessionIDKeepsTheSyntheticOne() {
        let entries = tree + [
            entry(pid: 54780, ppid: 3700, command: "/Users/you/Library/…/claude",
                  hostSessionID: "local_ec3625f5-cab7-44fd-a451-4406506b7361")
        ]
        let found = ProcessScanner.discover(
            entries: entries, agentCommands: ["claude"], coveredPIDs: []
        )
        XCTAssertEqual(found.count, 1)
        XCTAssertNil(found[0].sessionID)
        XCTAssertEqual(found[0].hostRef, "local_ec3625f5-cab7-44fd-a451-4406506b7361")
    }

    /// A process nobody could place, but which carries the desktop id, *is* a desktop session.
    func testAnUnplaceableProcessWithADesktopIDBecomesADesktopSession() {
        let entries = tree + [
            entry(pid: 4242, ppid: 1, command: "/opt/homebrew/bin/claude",
                  hostSessionID: "local_abc123")
        ]
        let found = ProcessScanner.discover(
            entries: entries, agentCommands: ["claude"], coveredPIDs: []
        )
        XCTAssertEqual(found.first?.host, .claudeDesktop)
        XCTAssertEqual(found.first?.hostRef, "local_abc123")
    }

    /// Two desktop processes claiming one id is the same inheritance problem, one level up.
    func testTwoDesktopProcessesSharingAnIDBothLoseIt() {
        let entries = tree + [
            entry(pid: 31844, ppid: 3700, command: "/Users/you/Library/…/claude",
                  hostSessionID: "local_shared", sessionID: "shared-id"),
            entry(pid: 54780, ppid: 3700, command: "/Users/you/Library/…/claude",
                  hostSessionID: "local_shared", sessionID: "shared-id"),
        ]
        let found = ProcessScanner.discover(
            entries: entries, agentCommands: ["claude"], coveredPIDs: []
        )
        XCTAssertEqual(found.count, 2)
        XCTAssertTrue(found.allSatisfy { $0.sessionID == nil && $0.hostRef == nil })
    }

    /// End to end: the synthesised rows the panel actually gets.
    func testTheScannedSessionsCarryUniqueIdentifiers() {
        let sessions = ProcessScanRunner().scan(
            coveredPIDs: [], agentCommands: ProcessScanner.defaultCommands
        )
        XCTAssertEqual(
            Set(sessions.map(\.sessionID)).count, sessions.count,
            "a duplicate id would drop a live row out of the list"
        )
        for session in sessions where session.host == .claudeDesktop {
            if let reference = session.hostRef {
                XCTAssertNotNil(
                    Jumper.desktopLink(hostRef: reference),
                    "a desktop host_ref that cannot make a link is worse than none"
                )
            }
        }
        for session in sessions where session.host != .claudeDesktop {
            XCTAssertNil(session.hostRef, "only desktop rows read the environment (SPEC §9.1)")
            XCTAssertTrue(session.sessionID.hasPrefix("discovered-"))
        }
    }
}
