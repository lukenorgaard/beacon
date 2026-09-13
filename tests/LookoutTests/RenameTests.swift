import AppKit
import XCTest
@testable import Lookout

/// SPEC §15.4's panel and §15.5's "rename the real session too": which mechanism a session gets,
/// exactly what goes down it, and the rule that outranks all of them — the local name is saved
/// whatever happens on the wire.
final class RenameTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var settings: Lookout.Settings!
    private var root: URL!
    private var home: LookoutHome!
    private var names: SessionNames!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        suiteName = "io.github.lukenorgaard.beacon.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = Lookout.Settings(defaults: defaults)
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-rename-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        home = LookoutHome(root: root)
        names = SessionNames(home: home)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        if let root { try? FileManager.default.removeItem(at: root) }
        names = nil
        home = nil
        root = nil
        settings = nil
        defaults = nil
        super.tearDown()
    }

    private func session(
        id: String = "s1",
        host: SessionHost = .cursor,
        state: SessionState = .working,
        agent: SessionAgent = .claude,
        title: String? = "fix the audit script"
    ) -> Session {
        var value = Session()
        value.sessionID = id
        value.agent = agent
        value.host = host
        value.state = state
        value.title = title
        value.cwd = "/Users/you/Desktop/Nimbus"
        value.project = "Nimbus"
        value.pid = 4242
        value.tty = "ttys005"
        value.hostRef = "w0t0p0:6E4A0000-1111"
        return value
    }

    /// A model whose three side effects are recorded instead of performed.
    private final class Recorder {
        var sent: [(String, Session)] = []
        var typed: [(String, Session)] = []
        var copied: [String] = []
        var jumped: [Session] = []
        var closed = 0
        var companion: [(String, Session)] = []
        var sendResult: SessionMessenger.Result = .sent(reply: nil)
        var typeResult = true
        var companionResult: CompanionMatch?
    }

    private func model(_ recorder: Recorder) -> RenameModel {
        let model = RenameModel(names: names, settings: settings, home: home)
        model.sender = { text, session, completion in
            recorder.sent.append((text, session))
            completion(recorder.sendResult)
        }
        model.typer = { command, session, completion in
            recorder.typed.append((command, session))
            completion(recorder.typeResult)
        }
        model.copier = { recorder.copied.append($0) }
        model.jumper = { recorder.jumped.append($0) }
        // SPEC §16.3: no test may reach a real editor window; "no match" is the machine that
        // has not installed the companion.
        model.companion = { command, session, completion in
            recorder.companion.append((command, session))
            completion(recorder.companionResult)
        }
        model.onClose = { recorder.closed += 1 }
        return model
    }

    // MARK: - The panel (SPEC §15.4)

    func testTheFieldIsPrefilledWithTheNameTheRowShows() {
        let recorder = Recorder()
        let panel = model(recorder)
        panel.begin(session())
        XCTAssertEqual(panel.text, "fix the audit script")
        XCTAssertEqual(panel.originalName, "fix the audit script")
    }

    func testARenamedSessionPrefillsItsCustomName() {
        names.setName("Nimbus fase 0", for: "s1")
        let recorder = Recorder()
        let panel = model(recorder)
        panel.begin(names.decorate(session()))
        XCTAssertEqual(panel.text, "Nimbus fase 0")
        // The name it replaced is still reachable, which is what the header line shows.
        XCTAssertEqual(panel.originalName, "fix the audit script")
    }

    func testSaveStoresTheNameAndClosesThePanel() {
        let recorder = Recorder()
        let panel = model(recorder)
        panel.begin(session())
        panel.alsoRenameInSession = false
        panel.text = "  Nimbus fase 0  "
        panel.save()

        XCTAssertEqual(names.name(for: "s1"), "Nimbus fase 0")
        XCTAssertEqual(recorder.closed, 1)
        XCTAssertNil(panel.session)
    }

    func testAnEmptyFieldRemovesTheOverride() {
        names.setName("Nimbus fase 0", for: "s1")
        let recorder = Recorder()
        let panel = model(recorder)
        panel.begin(names.decorate(session()))
        panel.text = "   "
        XCTAssertTrue(panel.clears)
        // Nothing to push into a session either — there is no name to push.
        XCTAssertFalse(panel.canPushToSession)
        panel.save()

        XCTAssertNil(names.name(for: "s1"))
        XCTAssertEqual(recorder.closed, 1)
        XCTAssertTrue(recorder.sent.isEmpty)
        XCTAssertTrue(recorder.copied.isEmpty)
    }

    func testCancelChangesNothing() {
        names.setName("Nimbus fase 0", for: "s1")
        let recorder = Recorder()
        let panel = model(recorder)
        panel.begin(names.decorate(session()))
        panel.text = "Something else"
        panel.cancel()

        XCTAssertEqual(names.name(for: "s1"), "Nimbus fase 0")
        XCTAssertEqual(recorder.closed, 1)
        XCTAssertTrue(recorder.sent.isEmpty)
    }

    func testSaveTwiceOnlyActsOnce() {
        let recorder = Recorder()
        let panel = model(recorder)
        panel.begin(session(host: .claudeDesktop))
        panel.text = "Voyager"
        recorder.sendResult = .failed(reason: "socket closed")
        panel.save()
        // The panel is now showing the failure and waiting for Close; ⏎ must not resend.
        panel.save()
        XCTAssertEqual(recorder.sent.count, 1)
    }

    // MARK: - Which mechanism (SPEC §15.5)

    func testCodexGetsNoMechanismAtAll() {
        let value = session(host: .terminal, state: .idle, agent: .codex)
        XCTAssertEqual(RenameDelivery.channel(for: value), RenameChannel.none)
        XCTAssertNil(RenameChannel.none.subtitle(host: .terminal))

        let panel = model(Recorder())
        panel.begin(value)
        XCTAssertFalse(panel.showsChannelCheckbox)
        // Default on "wherever a mechanism exists" — and off where none does.
        XCTAssertFalse(panel.alsoRenameInSession)
    }

    func testAClaudeDesktopSessionUsesItsTitleTool() {
        XCTAssertEqual(RenameDelivery.channel(for: session(host: .claudeDesktop)), .title)
        // The entrypoint is enough on its own — a desktop session need not say so twice.
        var byEntrypoint = session(host: .unknown)
        byEntrypoint.entrypoint = "claude-desktop"
        XCTAssertEqual(RenameDelivery.channel(for: byEntrypoint), .title)
        XCTAssertEqual(
            RenameChannel.title.subtitle(host: .claudeDesktop), "via the session's title tool"
        )
    }

    func testAnIdleOrDoneTerminalSessionIsTypedInto() {
        for state in [SessionState.idle, .done] {
            XCTAssertEqual(RenameDelivery.channel(for: session(host: .terminal, state: state)),
                           .typed, "state \(state)")
            XCTAssertEqual(RenameDelivery.channel(for: session(host: .iterm, state: state)),
                           .typed, "state \(state)")
        }
        XCTAssertEqual(RenameChannel.typed.subtitle(host: .terminal), "typed into the Terminal tab")
        XCTAssertEqual(RenameChannel.typed.subtitle(host: .iterm), "typed into the iTerm tab")
    }

    /// SPEC §15.5: typing into a tab mid-turn would land in the middle of whatever the agent is
    /// doing, so a busy terminal falls back to the Cursor rule.
    func testABusyTerminalSessionFallsBackToTheClipboard() {
        for state in [SessionState.working, .needsYou, .running] {
            XCTAssertEqual(RenameDelivery.channel(for: session(host: .terminal, state: state)),
                           .paste, "state \(state)")
        }
    }

    func testEveryOtherHostCopiesAndJumps() {
        for host in [SessionHost.cursor, .devin, .vscode, .unknown, .codexApp] {
            XCTAssertEqual(
                RenameDelivery.channel(for: session(host: host, state: .idle)), .paste,
                "host \(host)"
            )
        }
        XCTAssertEqual(RenameChannel.paste.subtitle(host: .cursor), "copied — paste it there")
    }

    // MARK: - What goes down it (SPEC §15.5)

    func testTheDesktopMessageIsTheOneTheSpecWrites() {
        XCTAssertEqual(
            RenameDelivery.message(name: "Nimbus fase 0"),
            "Rename this session to: \"Nimbus fase 0\". Use your session-title tool to set "
                + "exactly that title, then reply with only: renamed."
        )
    }

    func testTheTypedCommandIsSlashRename() {
        XCTAssertEqual(RenameDelivery.command(name: "Nimbus fase 0"), "/rename Nimbus fase 0")
    }

    func testADesktopRenameGoesOutThroughTheMessenger() {
        let recorder = Recorder()
        let panel = model(recorder)
        panel.begin(session(host: .claudeDesktop))
        panel.text = "Nimbus fase 0"
        panel.save()

        XCTAssertEqual(recorder.sent.count, 1)
        XCTAssertEqual(recorder.sent.first?.0, RenameDelivery.message(name: "Nimbus fase 0"))
        XCTAssertEqual(names.name(for: "s1"), "Nimbus fase 0")
        XCTAssertEqual(recorder.closed, 1)
    }

    func testATerminalRenameIsTypedIntoTheTab() {
        let recorder = Recorder()
        let panel = model(recorder)
        panel.begin(session(host: .terminal, state: .idle))
        panel.text = "Nimbus fase 0"
        panel.save()

        XCTAssertEqual(recorder.typed.count, 1)
        XCTAssertEqual(recorder.typed.first?.0, "/rename Nimbus fase 0")
        XCTAssertTrue(recorder.copied.isEmpty)
        XCTAssertEqual(names.name(for: "s1"), "Nimbus fase 0")
    }

    func testACursorRenameCopiesJumpsAndSaysSo() {
        let recorder = Recorder()
        let panel = model(recorder)
        panel.begin(session(host: .cursor))
        panel.text = "Nimbus fase 0"
        panel.save()

        XCTAssertEqual(recorder.copied, ["/rename Nimbus fase 0"])
        XCTAssertEqual(recorder.jumped.count, 1)
        XCTAssertEqual(panel.status, RenameDelivery.pasteStatus)
        XCTAssertTrue(panel.isFinished)
        // The panel stays up: the instruction is the only place that sentence exists.
        XCTAssertEqual(recorder.closed, 0)
        XCTAssertEqual(names.name(for: "s1"), "Nimbus fase 0")
    }

    /// SPEC §16.3: with a companion answering, `/rename` goes straight into the session's own
    /// terminal tab and there is nothing left to paste.
    func testACursorRenameGoesThroughTheCompanionWhenOneMatches() {
        let recorder = Recorder()
        recorder.companionResult = StubCompanion.match()
        let panel = model(recorder)
        panel.begin(session(host: .cursor))
        panel.text = "Nimbus fase 0"
        panel.save()

        XCTAssertEqual(recorder.companion.map(\.0), ["/rename Nimbus fase 0"])
        XCTAssertTrue(recorder.copied.isEmpty, "nothing is copied when the companion delivered")
        XCTAssertTrue(recorder.jumped.isEmpty, "and the editor is not brought forward either")
        XCTAssertEqual(panel.status, RenameDelivery.companionStatus)
        XCTAssertEqual(panel.status, "Renamed via companion")
        XCTAssertFalse(panel.statusIsError)
        XCTAssertTrue(panel.isFinished)
        XCTAssertFalse(panel.isWorking)
        XCTAssertEqual(names.name(for: "s1"), "Nimbus fase 0")
    }

    /// No companion → §15.5's clipboard rule, unchanged.
    func testACursorRenameFallsBackToTheClipboardWithoutACompanion() {
        let recorder = Recorder()
        let panel = model(recorder)
        panel.begin(session(host: .devin))
        panel.text = "Nimbus fase 0"
        panel.save()

        XCTAssertEqual(recorder.companion.count, 1, "the companion is asked first")
        XCTAssertEqual(recorder.copied, ["/rename Nimbus fase 0"])
        XCTAssertEqual(recorder.jumped.count, 1)
        XCTAssertEqual(panel.status, RenameDelivery.pasteStatus)
    }

    /// A `.paste` host that no companion can ever reach never pays for the round trip.
    func testAnUnknownHostSkipsTheCompanion() {
        let recorder = Recorder()
        recorder.companionResult = StubCompanion.match()
        let panel = model(recorder)
        panel.begin(session(host: .unknown))
        panel.text = "Nimbus fase 0"
        panel.save()

        XCTAssertTrue(recorder.companion.isEmpty)
        XCTAssertEqual(recorder.copied, ["/rename Nimbus fase 0"])
        XCTAssertEqual(panel.status, RenameDelivery.pasteStatus)
    }

    /// The rename is logged with the channel that carried it (SPEC §11.4's audit).
    func testACompanionRenameIsLoggedAsSuch() throws {
        let recorder = Recorder()
        recorder.companionResult = StubCompanion.match()
        let panel = model(recorder)
        panel.begin(session(host: .vscode))
        panel.text = "Nimbus fase 0"
        panel.save()

        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: home.answersLog.path), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        let log = try String(contentsOf: home.answersLog, encoding: .utf8)
        XCTAssertTrue(log.contains("rename · companion"), log)
    }

    func testTheCheckboxOffKeepsTheRenameLocal() {
        let recorder = Recorder()
        let panel = model(recorder)
        panel.begin(session(host: .claudeDesktop))
        panel.alsoRenameInSession = false
        panel.text = "Nimbus fase 0"
        panel.save()

        XCTAssertTrue(recorder.sent.isEmpty)
        XCTAssertEqual(names.name(for: "s1"), "Nimbus fase 0")
        XCTAssertEqual(recorder.closed, 1)
    }

    // MARK: - Failure (SPEC §15.5)

    func testASocketFailureStillSavesTheLocalName() throws {
        let recorder = Recorder()
        recorder.sendResult = .failed(reason: "no messaging socket")
        let panel = model(recorder)
        panel.begin(session(host: .claudeDesktop))
        panel.text = "Nimbus fase 0"
        panel.save()

        XCTAssertEqual(names.name(for: "s1"), "Nimbus fase 0")
        XCTAssertTrue(panel.statusIsError)
        XCTAssertEqual(
            panel.status, "Renamed here, but the session did not take it: no messaging socket"
        )
        XCTAssertTrue(panel.isFinished)
        XCTAssertEqual(recorder.closed, 0)
        // And the name survives a restart, which is the whole point of writing it first.
        XCTAssertEqual(SessionNames(home: home).name(for: "s1"), "Nimbus fase 0")
    }

    func testATabThatCannotBeFoundFallsBackToTheClipboard() {
        let recorder = Recorder()
        recorder.typeResult = false
        let panel = model(recorder)
        panel.begin(session(host: .terminal, state: .idle))
        panel.text = "Nimbus fase 0"
        panel.save()

        XCTAssertEqual(recorder.copied, ["/rename Nimbus fase 0"])
        XCTAssertEqual(recorder.jumped.count, 1)
        XCTAssertEqual(names.name(for: "s1"), "Nimbus fase 0")
        XCTAssertTrue(panel.status?.contains(RenameDelivery.pasteStatus) == true)
    }

    // MARK: - The audit line (SPEC §15.5)

    func testEveryOutcomeIsLoggedAsARename() throws {
        let recorder = Recorder()
        let panel = model(recorder)
        panel.begin(session(host: .cursor))
        panel.text = "Nimbus fase 0"
        panel.save()

        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: home.answersLog.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let log = try String(contentsOf: home.answersLog, encoding: .utf8)
        XCTAssertTrue(log.contains("Nimbus/s1"))
        XCTAssertTrue(log.contains("rename"))
        XCTAssertTrue(log.contains("copied"))
    }

    // MARK: - AppleScript composition (SPEC §15.5)

    func testAQuoteInANameCannotEscapeTheAppleScriptString() {
        let literal = Jumper.appleScriptLiteral(#"say "hi" \ now"#)
        XCTAssertEqual(literal, #"say \"hi\" \\ now"#)
    }

    func testANewlineInANameCannotRunASecondCommand() {
        XCTAssertEqual(Jumper.appleScriptLiteral("one\nrm -rf /"), "one rm -rf /")
        XCTAssertEqual(Jumper.appleScriptLiteral("one\r\ntwo"), "one  two")
    }

    func testTypingNeedsATargetTheHostCanActuallyGive() {
        // No tty and no iTerm reference: nothing is typed anywhere.
        var blind = session(host: .terminal, state: .idle)
        blind.tty = nil
        XCTAssertFalse(Jumper.typeIntoTerminal(tty: blind.tty, command: "/rename x"))
        XCTAssertFalse(Jumper.typeIntoITerm(reference: nil, command: "/rename x"))
        XCTAssertFalse(Jumper.type(command: "/rename x", into: session(host: .cursor)))
    }

    // MARK: - Where the panel sits (SPEC §15.4)

    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = NSSize(width: 320, height: 180)

    func testThePanelDocksToTheRightOfTheListAlignedWithTheRow() {
        let panel = NSRect(x: 700, y: 500, width: 360, height: 320)
        let row = NSRect(x: 708, y: 700, width: 344, height: 64)
        let placement = RenameDock.place(
            panel: panel, row: row, size: size, screen: screen, cardVisible: false, gap: 8
        )
        XCTAssertEqual(placement.side, .right)
        XCTAssertEqual(placement.origin.x, panel.maxX + 8)
        // Top edge level with the row's top.
        XCTAssertEqual(placement.origin.y + size.height, row.maxY)
    }

    func testItGoesLeftWhenTheRightWouldRunOffTheScreen() {
        let panel = NSRect(x: 1060, y: 500, width: 360, height: 320)
        let row = NSRect(x: 1068, y: 700, width: 344, height: 64)
        let placement = RenameDock.place(
            panel: panel, row: row, size: size, screen: screen, cardVisible: false, gap: 8
        )
        XCTAssertEqual(placement.side, .left)
        XCTAssertEqual(placement.origin.x, 1060 - 8 - 320)
    }

    /// SPEC §15.4: the card already has the side, so the rename panel goes under the row.
    func testItGoesUnderTheRowWhenTheCardIsOut() {
        let panel = NSRect(x: 900, y: 500, width: 360, height: 320)
        let row = NSRect(x: 908, y: 700, width: 344, height: 64)
        let placement = RenameDock.place(
            panel: panel, row: row, size: size, screen: screen, cardVisible: true, gap: 8
        )
        XCTAssertEqual(placement.side, .below)
        XCTAssertEqual(placement.origin.x, panel.minX)
        XCTAssertEqual(placement.origin.y + size.height, row.minY - 8)
    }

    func testItIsAlwaysFullyOnTheScreen() {
        let panel = NSRect(x: 900, y: 20, width: 360, height: 320)
        let row = NSRect(x: 908, y: 30, width: 344, height: 64)
        let placement = RenameDock.place(
            panel: panel, row: row, size: size, screen: screen, cardVisible: true, gap: 8
        )
        XCTAssertGreaterThanOrEqual(placement.origin.y, screen.minY)
        XCTAssertLessThanOrEqual(placement.origin.y + size.height, screen.maxY)
        XCTAssertGreaterThanOrEqual(placement.origin.x, screen.minX)
        XCTAssertLessThanOrEqual(placement.origin.x + size.width, screen.maxX)
    }

    /// SwiftUI measures a row from the top of the window; screens count from the bottom.
    func testARowRectIsConvertedOutOfSwiftUICoordinates() {
        let window = NSRect(x: 1000, y: 400, width: 360, height: 320)
        let row = CGRect(x: 8, y: 60, width: 344, height: 64)
        let converted = RenameDock.screenRect(
            row: row, contentHeight: 320, windowFrame: window
        )
        XCTAssertEqual(converted.minX, 1008)
        // 320 - 124 = 196 points up from the window's bottom edge.
        XCTAssertEqual(converted.minY, 400 + 196)
        XCTAssertEqual(converted.height, 64)
    }
}
