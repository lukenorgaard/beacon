import XCTest
@testable import Lookout

/// A slice of real `ps -axo pid=,ppid=,tty=,comm=,args=` output from this Mac, warts included:
/// `comm` truncated to 16 characters, a claude whose path contains spaces, and the `codex
/// mcp-server` helper that Claude Code spawns (SPEC §8.2).
private let psOutput = """
    1     0 ??       /sbin/launchd    /sbin/launchd
 4300     1 ??       /Applications/Cu /Applications/Cursor.app/Contents/MacOS/Cursor
43085  4300 ??       /Applications/Cu /Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper: terminal pty-host
85280 43085 s005     /bin/zsh         /bin/zsh -l
85281 85280 s005     /opt/homebrew/bi /opt/homebrew/bin/claude
90001 85281 s005     /opt/homebrew/bi /opt/homebrew/bin/claude --version
37720     1 ??       /Applications/Cl /Applications/Claude.app/Contents/MacOS/Claude
31841 37720 ??       /Applications/Cl /Applications/Claude.app/Contents/Helpers/disclaimer -- /Users/you/Library/Application Support/Claude/claude-code/2.1.255/claude.app/Contents/MacOS/claude --resume=507e57ba
31844 31841 ??       /Users/you/L /Users/you/Library/Application Support/Claude/claude-code/2.1.255/claude.app/Contents/MacOS/claude --output-format stream-json --model claude-opus-5
32311 31844 ??       /Applications/Ch /Applications/ChatGPT.app/Contents/Resources/codex mcp-server
77001     1 s009     /opt/homebrew/bi /opt/homebrew/bin/gemini chat
55000 43085 s006     /opt/homebrew/bi /opt/homebrew/bin/claude
55001 55000 s006     /opt/homebrew/bi /opt/homebrew/bin/claude
90210     1 ??       /bin/cat         /bin/cat /tmp/claude
61000     1 ??       /usr/local/bin/o /usr/local/bin/ollama serve
"""

final class ProcessScannerTests: XCTestCase {
    private lazy var entries = ProcessTable.parse(psOutput)

    // MARK: Parsing

    func testParsesPidPpidTTYAndTheWholeCommandTail() {
        XCTAssertEqual(entries.count, 15)

        let claude = try! XCTUnwrap(entries.first { $0.pid == 85281 })
        XCTAssertEqual(claude.ppid, 85280)
        XCTAssertEqual(claude.tty, "ttys005")
        XCTAssertTrue(claude.command.hasSuffix("/opt/homebrew/bin/claude"))

        let desktop = try! XCTUnwrap(entries.first { $0.pid == 31844 })
        XCTAssertNil(desktop.tty, "`??` means no controlling terminal")

        // `ps` output has no environment in it, so the §9.1 fields stay empty on that path.
        XCTAssertTrue(entries.allSatisfy { $0.hostSessionID == nil && $0.sessionID == nil })
    }

    func testTTYNormalisation() {
        XCTAssertEqual(ProcessTable.normaliseTTY("s005"), "ttys005")
        XCTAssertEqual(ProcessTable.normaliseTTY("ttys005"), "ttys005")
        XCTAssertNil(ProcessTable.normaliseTTY("??"))
        XCTAssertNil(ProcessTable.normaliseTTY(""))
    }

    func testExecutableCandidatesSurviveTruncationAndSpaces() {
        // A path with spaces is split across `ps` tokens; the basename still has to come out.
        let spaced = "/Users/you/L /Users/you/Library/Application Support/Claude/claude-code/2.1.255/claude.app/Contents/MacOS/claude --output-format"
        XCTAssertTrue(ProcessScanner.executableCandidates(command: spaced).contains("claude"))

        // …but a *following argument* starts with `/`, so this is `cat`, not an agent.
        let cat = "/bin/cat         /bin/cat /tmp/claude"
        XCTAssertFalse(ProcessScanner.executableCandidates(command: cat).contains("claude"))
    }

    // MARK: Discovery

    private func discover(covered: Set<Int32> = []) -> [DiscoveredAgent] {
        ProcessScanner.discover(
            entries: entries,
            agentCommands: ProcessScanner.defaultCommands,
            coveredPIDs: covered
        )
    }

    func testFindsExactlyTheRealAgentSessions() {
        XCTAssertEqual(discover().map(\.pid), [31844, 55000, 77001, 85281])
    }

    /// The one that matters on this Mac: every running `codex` is an mcp-server helper spawned
    /// by a Claude session, and none of them is a session.
    func testCodexMCPServerHelperIsExcluded() {
        XCTAssertFalse(discover().contains { $0.pid == 32311 })
        XCTAssertTrue(ProcessScanner.isExcluded(command: "…/Resources/codex mcp-server"))
        XCTAssertTrue(ProcessScanner.isExcluded(command: "/usr/bin/claude --version"))
        XCTAssertTrue(ProcessScanner.isExcluded(command: "codex app-server"))
        XCTAssertTrue(ProcessScanner.isExcluded(command: "codex mcp serve"))
        XCTAssertTrue(ProcessScanner.isExcluded(command: "claude completion zsh"))
    }

    func testAgentsRunningUnderAnotherAgentAreExcluded() {
        // 55001 is a claude spawned by claude 55000 — a subagent, not a session of its own.
        XCTAssertFalse(discover().contains { $0.pid == 55001 })
    }

    func testAStateFileAlwaysWinsAndItsChildrenStayHidden() {
        let found = discover(covered: [55000])
        XCTAssertFalse(found.contains { $0.pid == 55000 })
        XCTAssertFalse(found.contains { $0.pid == 55001 })
        XCTAssertTrue(found.contains { $0.pid == 85281 })
    }

    func testModelServersAndOrdinaryCommandsAreNotAgents() {
        XCTAssertFalse(discover().contains { $0.pid == 61000 }, "ollama is not an agent")
        XCTAssertFalse(discover().contains { $0.pid == 90210 }, "cat /tmp/claude is not an agent")
        XCTAssertFalse(discover().contains { $0.pid == 90001 }, "--version is not a session")
    }

    // MARK: Shell resolution (SPEC §16.2)

    func testADiscoveredRowCarriesTheNearestShellAncestor() {
        // 85281 claude → 85280 zsh → 43085 Cursor Helper: the companion's `processId` is 85280.
        XCTAssertEqual(discover().first { $0.pid == 85_281 }?.shellPID, 85_280)
        // 55000 claude hangs straight off the pty-host with no shell in between.
        XCTAssertNil(discover().first { $0.pid == 55_000 }?.shellPID)
        // The desktop session's chain is disclaimer → Claude.app, no shell anywhere.
        XCTAssertNil(discover().first { $0.pid == 31_844 }?.shellPID)
    }

    func testTheShellNamesCoverEverySpellingTheTwoSnapshotsProduce() {
        XCTAssertTrue(ProcessScanner.isShell(command: "/bin/zsh -l"))
        XCTAssertTrue(ProcessScanner.isShell(command: "-zsh"), "ps prints a login shell like this")
        XCTAssertTrue(ProcessScanner.isShell(command: "/bin/bash"))
        XCTAssertTrue(ProcessScanner.isShell(command: "/opt/homebrew/bin/fish -i"))
        XCTAssertTrue(ProcessScanner.isShell(command: "/bin/sh -c something"))
        XCTAssertTrue(ProcessScanner.isShell(command: "/opt/homebrew/bin/nu"))
        XCTAssertTrue(ProcessScanner.isShell(command: "/bin/dash"))

        XCTAssertFalse(ProcessScanner.isShell(command: "/opt/homebrew/bin/claude"))
        XCTAssertFalse(ProcessScanner.isShell(command: "/usr/bin/zshfoo"))
        XCTAssertFalse(ProcessScanner.isShell(command: ""))
        XCTAssertFalse(ProcessScanner.isShell(command: "/bin/cat /tmp/zsh"))
    }

    /// The walk takes the *nearest* shell, and gives up rather than climbing forever.
    func testTheShellWalkTakesTheNearestOneAndIsBounded() {
        var index: [Int32: ProcessEntry] = [:]
        func add(_ pid: Int32, _ ppid: Int32, _ command: String) {
            index[pid] = ProcessEntry(pid: pid, ppid: ppid, tty: nil, command: command)
        }
        add(1, 0, "/sbin/launchd")
        add(100, 1, "/bin/zsh")
        add(101, 100, "/bin/bash")
        add(102, 101, "/opt/homebrew/bin/claude")
        XCTAssertEqual(ProcessScanner.shellPID(for: 102, index: index), 101, "nearest, not first")
        XCTAssertEqual(ProcessScanner.shellPID(for: 101, index: index), 100)
        XCTAssertNil(ProcessScanner.shellPID(for: 100, index: index))
        XCTAssertNil(ProcessScanner.shellPID(for: 999, index: index), "an unknown pid walks nowhere")

        // A shell further up than the walk looks (12 ancestors) is not found — the row simply
        // has no shell pid, and the companion falls back to matching the terminal by name.
        var deep: [Int32: ProcessEntry] = [:]
        deep[2] = ProcessEntry(pid: 2, ppid: 1, tty: nil, command: "/bin/zsh")
        for pid in Int32(3)...Int32(20) {
            deep[pid] = ProcessEntry(
                pid: pid, ppid: pid - 1, tty: nil, command: "/usr/bin/wrapper"
            )
        }
        XCTAssertNil(ProcessScanner.shellPID(for: 20, index: deep))
        XCTAssertEqual(ProcessScanner.shellPID(for: 13, index: deep), 2, "within the 12 levels")
    }

    // MARK: Host resolution

    func testClaudeInACursorTerminalResolvesToCursor() {
        let claude = discover().first { $0.pid == 85281 }
        XCTAssertEqual(claude?.host, .cursor)
        XCTAssertEqual(claude?.hostPID, 43085)
        XCTAssertEqual(claude?.tty, "ttys005")
        XCTAssertEqual(claude?.agent, "claude")
    }

    func testClaudeWithNoTTYUnderTheDesktopAppResolvesToClaudeDesktop() {
        let desktop = discover().first { $0.pid == 31844 }
        XCTAssertEqual(desktop?.host, .claudeDesktop)
        XCTAssertEqual(desktop?.hostPID, 31841)
        XCTAssertNil(desktop?.tty)
    }

    func testAnAgentWithNoRecognisableAncestorHasAnUnknownHost() {
        let gemini = discover().first { $0.pid == 77001 }
        XCTAssertEqual(gemini?.agent, "gemini")
        XCTAssertEqual(gemini?.host, .unknown)
        XCTAssertNil(gemini?.hostPID)
        XCTAssertEqual(gemini?.tty, "ttys009")
    }

    func testAnEmptyCommandListFindsNothing() {
        XCTAssertTrue(
            ProcessScanner.discover(entries: entries, agentCommands: [], coveredPIDs: []).isEmpty
        )
    }

    func testACustomCommandListIsHonoured() {
        let found = ProcessScanner.discover(
            entries: entries, agentCommands: ["gemini"], coveredPIDs: []
        )
        XCTAssertEqual(found.map(\.pid), [77001])
    }

    // MARK: lsof

    func testLSOFFieldOutputIsParsed() {
        let output = """
        p85281
        fcwd
        n/Users/you/Desktop/Lookout
        p31844
        fcwd
        n/Users/you/Desktop/Voyager
        """
        XCTAssertEqual(
            ProcessScanRunner.parseLSOF(output),
            [85281: "/Users/you/Desktop/Lookout", 31844: "/Users/you/Desktop/Voyager"]
        )
        XCTAssertTrue(ProcessScanRunner.parseLSOF("").isEmpty)
    }
}

/// Runs against the real machine — the scan has to stay cheap enough for a 5 s tick (SPEC §5.6).
final class LiveProcessScanTests: XCTestCase {
    func testTheRealScanIsQuickAndSurvivesThisMac() {
        let runner = ProcessScanRunner()
        let started = Date()
        let sessions = runner.scan(
            coveredPIDs: [], agentCommands: ProcessScanner.defaultCommands
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 3, "ps + lsof must never hold up the tick")
        for session in sessions {
            XCTAssertEqual(session.state, .running)
            XCTAssertEqual(session.reason, "discovered")
            XCTAssertTrue(session.isDiscovered)
            XCTAssertNotNil(session.pid)
            // SPEC §9.1: the id is the real `CLAUDE_CODE_SESSION_ID` when the process handed one
            // over, and `discovered-<pid>` only when it did not.
            XCTAssertFalse(session.sessionID.isEmpty)
            if !session.sessionID.hasPrefix("discovered-") {
                XCTAssertEqual(
                    ProcessScanner.sanitisedIdentifier(session.sessionID), session.sessionID,
                    "an id read out of an environment must have been sanitised"
                )
            }
            // A host_ref that came from the environment is either a usable desktop id or nothing.
            if let reference = session.hostRef {
                XCTAssertEqual(
                    ProcessScanner.sanitisedIdentifier(reference), reference
                )
            }
        }
        print("live scan: \(sessions.count) agent(s) in \(Int(elapsed * 1000)) ms")
        for session in sessions {
            print("   \(session.agent.name) pid \(session.pid ?? 0) host \(session.host.rawValue) tty \(session.tty ?? "-") cwd \(session.cwd)")
        }

        // Same pids, second time round: ids and start times must be stable across ticks.
        let again = runner.scan(coveredPIDs: [], agentCommands: ProcessScanner.defaultCommands)
        let firstIDs = Set(sessions.map(\.sessionID))
        let secondIDs = Set(again.map(\.sessionID))
        XCTAssertTrue(
            secondIDs.isSuperset(of: firstIDs.intersection(secondIDs)),
            "session ids must not churn between ticks"
        )
    }

    /// The ChatGPT app's code-mode host keeps long-lived `codex sandbox` helpers alive under
    /// `cua_node/bin/node_repl`. They are not sessions, and listing them put three identical
    /// rows in the panel for one project.
    func testCodexSandboxHelperIsExcluded() {
        XCTAssertTrue(ProcessScanner.isExcluded(
            command: "/Applications/ChatGPT.app/Contents/Resources/codex sandbox -c shell_environment_policy.inherit=\"all\""
        ))
        // A real session that merely picks a sandbox policy must survive: the marker is the
        // `sandbox` subcommand, not the `--sandbox` flag.
        XCTAssertFalse(ProcessScanner.isExcluded(command: "codex exec --sandbox read-only \"do a thing\""))
        XCTAssertFalse(ProcessScanner.isExcluded(command: "claude --sandbox workspace-write"))
    }
}

/// The libproc snapshot that replaced the `ps` fork (SPEC §5.6 performance rules).
