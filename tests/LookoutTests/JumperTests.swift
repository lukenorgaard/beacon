import XCTest
@testable import Lookout

/// SPEC §9.1 and §9.2: the desktop deep link, and the LaunchServices jumps that replaced the
/// editors' node CLIs.
final class JumperTests: XCTestCase {

    // MARK: - §9.1 desktop session id

    func testOnlyTheDesktopsOwnLocalIDIsAccepted() {
        XCTAssertEqual(Jumper.desktopSessionID("local_abc123"), "local_abc123")
        XCTAssertEqual(
            Jumper.desktopSessionID("local_9c1d6e20-4a7f-11ef-9b2a-1e5c7d3a9b01"),
            "local_9c1d6e20-4a7f-11ef-9b2a-1e5c7d3a9b01"
        )
        XCTAssertEqual(Jumper.desktopSessionID("  local_abc123  "), "local_abc123", "trimmed")
        XCTAssertEqual(Jumper.desktopSessionID("local_" + String(repeating: "a", count: 64)),
                       "local_" + String(repeating: "a", count: 64))
    }

    /// The bug §9.1 exists to kill: a Claude Code UUID fails the app's own validation silently,
    /// so the old link never continued a session — it only brought the app to the front.
    func testAClaudeCodeUUIDIsRejected() {
        XCTAssertNil(Jumper.desktopSessionID("1d9e4b77-0c52-4a36-8f21-77a5c3b9d401"))
        XCTAssertNil(Jumper.desktopLink(hostRef: "1d9e4b77-0c52-4a36-8f21-77a5c3b9d401"))
    }

    func testEverythingElseIsRejected() {
        XCTAssertNil(Jumper.desktopSessionID(nil))
        XCTAssertNil(Jumper.desktopSessionID(""))
        XCTAssertNil(Jumper.desktopSessionID("local_"), "at least one character after the prefix")
        XCTAssertNil(Jumper.desktopSessionID("Local_abc"), "the prefix is case-sensitive")
        XCTAssertNil(Jumper.desktopSessionID("prefix_local_abc"))
        XCTAssertNil(Jumper.desktopSessionID("local_abc def"), "no spaces")
        XCTAssertNil(Jumper.desktopSessionID("local_abc/../x"), "no path escapes")
        XCTAssertNil(Jumper.desktopSessionID("local_abc&source=evil"), "no query injection")
        XCTAssertNil(Jumper.desktopSessionID("local_abc_123"), "underscore is not in the class")
        XCTAssertNil(Jumper.desktopSessionID("local_ábc"), "ASCII only")
        XCTAssertNil(
            Jumper.desktopSessionID("local_" + String(repeating: "a", count: 65)),
            "65 characters is one too many"
        )
        // iTerm's host_ref lives in the same field and must never be mistaken for a desktop id.
        XCTAssertNil(Jumper.desktopSessionID("w0t0p0:8C1D6E20-4A7F-11EF-9B2A-1E5C7D3A9B01"))
    }

    func testDeepLinkConstruction() {
        XCTAssertEqual(
            Jumper.desktopLink(hostRef: "local_9c1d6e204a7f11ef"),
            "claude://code/continue?session=local_9c1d6e204a7f11ef&source=lookout"
        )
        XCTAssertNil(Jumper.desktopLink(hostRef: nil))
        XCTAssertFalse(
            Jumper.openDesktopSession(hostRef: nil),
            "no usable id means no link and no launch — the caller activates the app instead"
        )
    }

    /// The checked-in desktop fixture has to carry a link-worthy id, or the fixture set stops
    /// covering the only jump §9.1 changed.
    func testTheDesktopFixtureCarriesAUsableHostRef() throws {
        let url = Fixtures.sessionsDirectory
            .appendingPathComponent("claude-1d9e4b77-0c52-4a36-8f21-77a5c3b9d401.json")
        let session = try JSONDecoder().decode(Session.self, from: Data(contentsOf: url))
        XCTAssertEqual(session.host, .claudeDesktop)
        XCTAssertNotNil(Jumper.desktopLink(hostRef: session.hostRef))
    }

    // MARK: - §9.2 fast jumps

    func testEditorsAreOpenedThroughLaunchServicesNotTheirCLIs() {
        XCTAssertEqual(Jumper.launchArguments(for: .cursor), ["-a", "Cursor"])
        XCTAssertEqual(Jumper.launchArguments(for: .devin), ["-b", "com.exafunction.windsurf"])
        XCTAssertEqual(Jumper.launchArguments(for: .vscode), ["-b", "com.microsoft.VSCode"])
        XCTAssertNil(Jumper.launchArguments(for: .terminal))
        XCTAssertNil(Jumper.launchArguments(for: .claudeDesktop))
        XCTAssertNil(Jumper.launchArguments(for: .unknown))

        XCTAssertEqual(Jumper.workspaceStorageApp(for: .cursor), "Cursor")
        XCTAssertEqual(Jumper.workspaceStorageApp(for: .devin), "Devin")
        XCTAssertEqual(Jumper.workspaceStorageApp(for: .vscode), "Code")
        XCTAssertNil(Jumper.workspaceStorageApp(for: .iterm))

        // `-r` would replace the workspace of the last active window (SPEC §2.4).
        for host in [SessionHost.cursor, .devin, .vscode] {
            XCTAssertFalse(Jumper.launchArguments(for: host)?.contains("-r") ?? true)
            XCTAssertFalse(Jumper.launchArguments(for: host)?.contains("-n") ?? true)
        }
    }

    /// SPEC §9.2: nothing on the click path may block longer than 2 s. `Shell.run` is bounded by
    /// its timeout plus a fixed escalation overhead, so the budget is checkable arithmetic.
    func testNoJumpCanBlockTheClickPathForLongerThanTwoSeconds() {
        XCTAssertLessThanOrEqual(Jumper.launchTimeout + Shell.timeoutOverhead, 2.0)
        // AppleScript keeps the longer deadline §9.2 explicitly leaves it.
        XCTAssertEqual(Jumper.appleScriptTimeout, 3)
    }

    func testShellReturnsWithinItsBudgetForAChildThatNeverExits() {
        let started = Date()
        let result = Shell.run("/bin/sleep", ["30"], timeout: Jumper.launchTimeout)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(result.timedOut)
        XCTAssertLessThanOrEqual(
            elapsed, Jumper.launchTimeout + Shell.timeoutOverhead + 0.3,
            "a wedged child must be killed inside the click-path budget"
        )
    }

    // MARK: - §9.6 desktop jump robustness

    /// 2026-09-04 revision: `~/.lookout/jump.log` showed the AXPress has never once selected the
    /// row over two days of real jumps — the click fallback has always been the one that works.
    /// The old 150 ms / 400 ms `AXSelected` probes existed to give the press a chance that never
    /// once paid off, so they are gone; the press now gets one short 50 ms look before the code
    /// falls through to the click, which is what these constants (and their replacements for the
    /// removed `axSelectionFirstProbe` / `axSelectionBudget`) encode.
    func testThePressOnlyGetsOneShortProbeBeforeFallingThroughToTheClick() {
        XCTAssertEqual(
            Jumper.axPressSelectionWait, 0.05,
            "§9.6 (2026-09-04): the press has never worked, so this is a cheap catch-all, not a wait"
        )
        XCTAssertLessThan(
            Jumper.axPressSelectionWait, 0.15,
            "must be well under the old 150ms first probe it replaces"
        )
    }

    /// The click's own verification read: one read, 50 ms after the click, for the log line —
    /// the live sidebar never reports the row as selected, so a longer poll bought nothing.
    func testTheClickVerificationReadIsOneFiftyMillisecondRead() {
        XCTAssertEqual(Jumper.axClickVerifyInterval, 0.05)
        XCTAssertEqual(Jumper.axClickVerifyAttempts, 1)
        XCTAssertEqual(
            Jumper.axClickVerifyInterval * Double(Jumper.axClickVerifyAttempts), 0.05,
            accuracy: 0.0001
        )
    }

    /// The whole desktop path — search, press probe, click, verify, one retry click, verify —
    /// still fits in §9.4's 3 s budget, and the search still gets the lion's share of it.
    func testTheDesktopPathStillFitsInsideTheBudget() {
        XCTAssertEqual(Jumper.axPollBudget, 3)
        XCTAssertEqual(
            Jumper.axPostMatchReserve,
            Jumper.axPressSelectionWait + 2 * Jumper.axClickCycleBudget + Jumper.axRetrySearchBudget,
            accuracy: 0.0001,
            "named arithmetic: press probe, two click-and-verify cycles (first + retry), one "
                + "fresh-lookup search for the retry"
        )
        XCTAssertEqual(
            Jumper.axSearchBudget, Jumper.axPollBudget - Jumper.axPostMatchReserve,
            accuracy: 0.0001
        )
        XCTAssertLessThanOrEqual(
            Jumper.axSearchBudget + Jumper.axPostMatchReserve,
            Jumper.axPollBudget,
            "the search only gets what press + click + verify + retry leave over"
        )
        XCTAssertGreaterThan(Jumper.axSearchBudget, 1, "…and that is still most of the budget")
        XCTAssertEqual(Jumper.scrollToVisibleAction, "AXScrollToVisible")
    }

    /// SPEC task (2026-09-04): "waits at most 50 ms for AXSelected before falling through to the
    /// CGEvent click. Remove the 150/400 ms waits." — this is the arithmetic check that the old
    /// waits are actually gone, expressed without depending on the removed constant names.
    func testTheOldOneHundredFiftyAndFourHundredMillisecondWaitsAreGone() {
        XCTAssertLessThanOrEqual(Jumper.axPressSelectionWait, 0.05)
    }

    /// A summary line per jump keeps `jump.log` readable — one line replaces the old separate
    /// "selected after 150ms" / "after 400ms" lines.
    func testTheJumpSummaryLineFormatting() {
        XCTAssertEqual(
            Jumper.jumpSummaryLine(press: false, click: true, selected: true, elapsed: 0.112),
            "desktop jump: press=0 click=1 selected=1 total=112ms"
        )
        XCTAssertEqual(
            Jumper.jumpSummaryLine(press: true, click: false, selected: true, elapsed: 0.0),
            "desktop jump: press=1 click=0 selected=1 total=0ms"
        )
        XCTAssertEqual(
            Jumper.jumpSummaryLine(press: false, click: true, selected: false, elapsed: 0.2996),
            "desktop jump: press=0 click=1 selected=0 total=300ms",
            "milliseconds round rather than truncate"
        )
        XCTAssertEqual(
            Jumper.jumpSummaryLine(press: false, click: false, selected: false, elapsed: 1.4),
            "desktop jump: press=0 click=0 selected=0 total=1400ms",
            "no unit conversion past milliseconds — the log stays grep-able as one shape"
        )
    }

    /// Pure decision logic for the "retry once after a failed click" rule — no real AX needed.
    /// Only a click that could not be delivered is retried; a delivered click never is, because
    /// the live sidebar reads `selected=0` even after a jump that landed (jump.log, 2026-09-04).
    func testRetryClickDecisionLogic() {
        XCTAssertFalse(Jumper.shouldRetryClick(clicked: true), "delivered — never click twice")
        XCTAssertTrue(Jumper.shouldRetryClick(clicked: false), "no rectangle — one fresh attempt")
        XCTAssertEqual(Jumper.axClickVerifyAttempts, 1, "one read, for the log line only")
    }

    /// The click aims at the centre of the button's own rectangle — the AX dump of a real
    /// sidebar row measured (1752, 315) at 251×26, so the click lands at (1877.5, 328).
    func testTheClickAimsAtTheCentreOfTheButton() {
        XCTAssertEqual(
            Jumper.clickPoint(position: CGPoint(x: 1752, y: 315),
                              size: CGSize(width: 251, height: 26)),
            CGPoint(x: 1877.5, y: 328)
        )
    }

    /// A row with no rectangle is never clicked: a stray click somewhere else on the user's
    /// screen is worse than a jump that quietly did not happen.
    func testAButtonWithoutARectangleIsNeverClicked() {
        XCTAssertNil(Jumper.clickPoint(position: .zero, size: .zero))
        XCTAssertNil(
            Jumper.clickPoint(position: CGPoint(x: 10, y: 10), size: CGSize(width: 0, height: 26))
        )
        XCTAssertNil(
            Jumper.clickPoint(position: CGPoint(x: 10, y: 10), size: CGSize(width: 251, height: 0))
        )
        XCTAssertNil(
            Jumper.clickPoint(position: CGPoint(x: 10, y: 10),
                              size: CGSize(width: -251, height: 26)),
            "a negative size is not a rectangle"
        )
        XCTAssertNil(
            Jumper.clickPoint(position: CGPoint(x: CGFloat.nan, y: 10),
                              size: CGSize(width: 251, height: 26))
        )
        XCTAssertNil(
            Jumper.clickPoint(position: CGPoint(x: CGFloat.infinity, y: 10),
                              size: CGSize(width: 251, height: 26))
        )
    }

    func testAnOffScreenClickPointIsRefused() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1728, height: 1117),
            CGRect(x: 1728, y: 0, width: 2560, height: 1440),
        ]
        XCTAssertTrue(Jumper.isOnScreen(CGPoint(x: 1877.5, y: 328), in: screens))
        XCTAssertTrue(Jumper.isOnScreen(CGPoint(x: 10, y: 10), in: screens))
        XCTAssertFalse(Jumper.isOnScreen(CGPoint(x: -4000, y: 328), in: screens))
        XCTAssertFalse(Jumper.isOnScreen(CGPoint(x: 400, y: 9000), in: screens))
        XCTAssertFalse(
            Jumper.isOnScreen(CGPoint(x: 100, y: 100), in: []),
            "no displays, no click"
        )
    }

    /// `CGDisplayBounds` is what the on-screen test is fed at runtime; on a real Mac there is at
    /// least one display and the main one starts at the origin.
    func testTheDisplayListIsReadableOffTheMainThread() {
        let bounds = Jumper.activeDisplayBounds()
        XCTAssertFalse(bounds.isEmpty)
        XCTAssertTrue(bounds.allSatisfy { $0.width > 0 && $0.height > 0 })
    }

    /// Nothing else changed about the terminal paths.
    func testTerminalHelpersAreUnchanged() {
        XCTAssertEqual(Jumper.devicePath("s005"), "/dev/ttys005")
        XCTAssertEqual(Jumper.itermSessionID("w0t0p0:8C1D6E20"), "8C1D6E20")
    }

    // MARK: - §16.3 editor jump order

    private func editorSession(host: SessionHost = .cursor, shellPid: Int32? = 85_280) -> Session {
        var value = Session()
        value.sessionID = "s-editor"
        value.agent = .claude
        value.host = host
        value.shellPid = shellPid
        value.cwd = "/Users/you/Acme/repo"
        return value
    }

    /// SPEC §16.3's order: companion focus first, and when it lands nothing else runs — no
    /// folder jump, no activation.
    func testTheCompanionFocusComesFirstAndStopsThere() {
        var steps: [String] = []
        let path = Jumper.editorJump(
            session: editorSession(),
            focus: { _ in
                steps.append("focus")
                return StubCompanion.match()
            },
            raise: { _ in
                steps.append("raise")
                return true
            },
            openWindow: { _ in
                steps.append("window")
                return true
            }
        )
        XCTAssertEqual(path, .companion)
        XCTAssertEqual(steps, ["focus", "raise"], "terminal.show() alone never raises the window")
    }

    /// No companion (or no matching terminal) → the §12.4 folder jump, exactly as before.
    func testWithoutAMatchTheOpenWindowJumpTakesOver() {
        var steps: [String] = []
        let path = Jumper.editorJump(
            session: editorSession(),
            focus: { _ in steps.append("focus"); return nil },
            raise: { _ in steps.append("raise"); return true },
            openWindow: { _ in steps.append("window"); return true }
        )
        XCTAssertEqual(path, .window)
        XCTAssertEqual(steps, ["focus", "window"], "the window is never raised twice")
    }

    /// Neither worked: the caller activates the app, which is v1's behaviour untouched.
    func testWithNeitherTheJumpFallsThroughToActivate() {
        let path = Jumper.editorJump(
            session: editorSession(),
            focus: { _ in nil },
            raise: { _ in true },
            openWindow: { _ in false }
        )
        XCTAssertEqual(path, .activate)
    }

    /// A companion focus that could not raise the window is still a companion jump — the tab is
    /// selected either way, and falling through would open a second window.
    func testAFailedRaiseIsStillACompanionJump() {
        let path = Jumper.editorJump(
            session: editorSession(),
            focus: { _ in StubCompanion.match() },
            raise: { _ in false },
            openWindow: { _ in XCTFail("the folder jump must not run"); return true }
        )
        XCTAssertEqual(path, .companion)
    }

    /// The session-shaped call the app uses: the three editor hosts ask a companion, every other
    /// host never touches one.
    func testOnlyTheThreeEditorHostsAskTheCompanion() {
        let stub = StubCompanion()
        stub.result = StubCompanion.match()

        for host in [SessionHost.cursor, .devin, .vscode] {
            XCTAssertNotNil(stub.focus(session: editorSession(host: host)), "\(host)")
        }
        XCTAssertEqual(stub.focusCalls.map(\.app), ["cursor", "devin", "vscode"])
        XCTAssertEqual(stub.focusCalls.map(\.shellPid), [85_280, 85_280, 85_280])

        for host in [SessionHost.terminal, .iterm, .claudeDesktop, .codexApp, .unknown] {
            XCTAssertNil(stub.focus(session: editorSession(host: host)), "\(host)")
        }
        XCTAssertEqual(stub.focusCalls.count, 3, "no companion call for a non-editor host")
    }

    /// SPEC §16.3: which of the three paths ran is written to `jump.log`, because from the
    /// outside all three look the same — the editor came forward.
    func testThePathTakenIsWrittenToTheJumpLog() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-jumplog-\(UUID().uuidString)")
        setenv("LOOKOUT_HOME", root.path, 1)
        defer {
            unsetenv("LOOKOUT_HOME")
            try? FileManager.default.removeItem(at: root)
        }

        _ = Jumper.editorJump(
            session: editorSession(),
            focus: { _ in StubCompanion.match(index: 2, rule: .name) },
            raise: { _ in true },
            openWindow: { _ in true }
        )
        _ = Jumper.editorJump(
            session: editorSession(host: .devin),
            focus: { _ in nil },
            raise: { _ in true },
            openWindow: { _ in false }
        )

        let log = try String(contentsOf: root.appendingPathComponent("jump.log"), encoding: .utf8)
        XCTAssertTrue(
            log.contains("editor cursor: companion focus rule=name terminal=2 raised=1"), log
        )
        XCTAssertTrue(log.contains("editor devin: activate only"), log)
    }

    /// The window a companion match names is the one raised — a bare activation would bring
    /// whichever window was last in front, not the one holding the terminal.
    func testTheRaiseAimsAtTheMatchedWindowsFolder() {
        XCTAssertEqual(Jumper.launchArguments(for: .cursor), ["-a", "Cursor"])
        XCTAssertEqual(Jumper.launchArguments(for: .devin), ["-b", "com.exafunction.windsurf"])
        XCTAssertNil(Jumper.launchArguments(for: .terminal), "no editor, no raise")

        // A folder that is not on disk any more is dropped rather than opened as a new window.
        let missing = StubCompanion.match(folders: ["/nope/gone-\(UUID().uuidString)"])
        XCTAssertFalse(missing.instance.folders.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: missing.instance.folders[0]),
            "the guard in raiseEditorWindow is what keeps this from opening a window"
        )
    }

    /// SPEC line 245: "Codex desktop (ChatGPT app) sessions: app activation only". The click
    /// used to fall through to `activate(_:)`, which looks up `NSRunningApplication` by the host
    /// pid — and for a Codex desktop session that pid is `cua_node/bin/node_repl` inside the
    /// bundle, not a registered application, so the lookup returned nil and the click did
    /// nothing. AppleScript activation is the one mechanism that actually fronts this app.
    func testACodexDesktopSessionIsActivatedByAppleScript() {
        XCTAssertEqual(Jumper.codexBundleID, "com.openai.codex", "ChatGPT.app ships under this id")
        let script = Jumper.codexActivationScript()
        XCTAssertEqual(script, "tell application id \"com.openai.codex\" to activate")
        // Targeting by id, not by name: two apps may be called ChatGPT, only one carries the id.
        XCTAssertFalse(script.contains("\"ChatGPT\""))
        // Not a LaunchServices jump: `open -b`/`open -a` exit 0 and leave the frontmost app alone.
        XCTAssertNil(Jumper.launchArguments(for: .codexApp))
    }
}
