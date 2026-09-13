import XCTest
@testable import Lookout

/// SPEC §9.4: the `claude://code/continue` deep link is gated off in this desktop build, so a
/// desktop session is reached by activating the app and pressing its sidebar button. That button
/// is named `<Status> <desktop_title>`, which makes two things worth testing without a running
/// desktop app: the pure matcher, and the `desktop_title` field the matcher is fed from.
final class DesktopTitleTests: XCTestCase {
    private let decoder = JSONDecoder()

    private func session(_ json: String) throws -> Session {
        try decoder.decode(Session.self, from: Data(json.utf8))
    }

    // MARK: - The sidebar matcher

    func testAnExactTitleMatches() {
        let names = ["New chat", "Lookout menu bar app", "Settings"]
        XCTAssertEqual(Jumper.matchIndex(desktopTitle: "Lookout menu bar app", in: names), 1)
    }

    /// What the sidebar really renders (measured in §9.4): the status word, a space, the title.
    func testAStatusPrefixedSuffixMatches() {
        let names = [
            "New chat",
            "Running Terminal session overlay widget",
            "Idle Hacking monitoring og sikkerhedssystem",
        ]
        XCTAssertEqual(
            Jumper.matchIndex(desktopTitle: "Hacking monitoring og sikkerhedssystem", in: names), 2
        )
        for status in Jumper.desktopStatusPrefixes {
            XCTAssertEqual(
                Jumper.matchIndex(desktopTitle: "Ship it", in: ["\(status) Ship it"]), 0,
                "\(status) is a status word"
            )
        }

        // Read off the live sidebar's AX tree on 2026-09-02; `Unread response` is not in §9.4's
        // list but is what the app actually renders for a session with an unread reply.
        for measured in ["Running", "Idle", "Unread response"] {
            XCTAssertTrue(
                Jumper.desktopStatusPrefixes.contains(measured),
                "\(measured) was measured on the real sidebar"
            )
        }
    }

    /// A button that merely happens to end with the title must never beat the sidebar row.
    func testAStatusPrefixBeatsANonStatusSuffixMatchWhateverTheOrder() {
        let statusLast = ["Open Ship it", "Running Ship it"]
        XCTAssertEqual(Jumper.matchIndex(desktopTitle: "Ship it", in: statusLast), 1)

        let statusFirst = ["Running Ship it", "Open Ship it"]
        XCTAssertEqual(Jumper.matchIndex(desktopTitle: "Ship it", in: statusFirst), 0)
    }

    /// An exact hit is stronger than a stray suffix, weaker than the real sidebar shape.
    func testRankOrderIsStatusPrefixThenExactThenAnyOtherSuffix() {
        XCTAssertEqual(Jumper.matchRank(name: "Running Ship it", target: "Ship it"), 0)
        XCTAssertEqual(Jumper.matchRank(name: "Ship it", target: "Ship it"), 1)
        XCTAssertEqual(Jumper.matchRank(name: "Reopen Ship it", target: "Ship it"), 2)
        XCTAssertNil(Jumper.matchRank(name: "Ship it later", target: "Ship it"))
        XCTAssertNil(
            Jumper.matchRank(name: "RunningShip it", target: "Ship it"),
            "the suffix has to start on a space, or every title is a substring of something"
        )
    }

    func testNoMatchAtAll() {
        XCTAssertNil(Jumper.matchIndex(desktopTitle: "Ship it", in: []))
        XCTAssertNil(
            Jumper.matchIndex(desktopTitle: "Ship it", in: ["New chat", "Running Something else"])
        )
        XCTAssertNil(
            Jumper.matchIndex(desktopTitle: "ship it", in: ["Running Ship it"]),
            "the desktop title is copied verbatim from the transcript, so case is signal"
        )
        XCTAssertNil(Jumper.matchIndex(desktopTitle: "   ", in: ["Running "]), "nothing to match")
    }

    /// Two sessions can carry the same title; pressing the first one in tree order is a
    /// defensible answer and a stable one.
    func testAmbiguityGoesToTheFirstButtonInTreeOrder() {
        let names = ["Running Ship it", "Running Ship it", "Idle Ship it"]
        XCTAssertEqual(Jumper.matchIndex(desktopTitle: "Ship it", in: names), 0)

        let mixed = ["Open Ship it", "Reopen Ship it"]
        XCTAssertEqual(
            Jumper.matchIndex(desktopTitle: "Ship it", in: mixed), 0,
            "equal rank keeps the first"
        )
    }

    func testWhitespaceAroundEitherSideIsIgnored() {
        XCTAssertEqual(
            Jumper.matchIndex(desktopTitle: "  Ship it  ", in: ["  Running Ship it\n"]), 0
        )
    }

    // MARK: - The click-path budget (§9.4 + §9.2)

    func testTheAccessibilitySearchIsBounded() {
        XCTAssertEqual(Jumper.axPollBudget, 3, "§9.4 gives the sidebar search 3 s")
        XCTAssertEqual(Jumper.axPollInterval, 0.1)
        XCTAssertEqual(Jumper.axElementCap, 3000)
        XCTAssertEqual(Jumper.desktopBundleID, "com.anthropic.claudefordesktop")
        XCTAssertLessThanOrEqual(
            Double(Jumper.axMessagingTimeout), Jumper.axPollBudget,
            "one wedged AX call must not outlive the whole search"
        )
    }

    /// Nothing to press without a title, and the answer arrives immediately — there is no point
    /// polling for a button that cannot exist.
    func testAnEmptyDesktopTitleIsNeverSearchedFor() {
        let started = Date()
        XCTAssertFalse(Jumper.pressDesktopSession(named: "   "))
        XCTAssertLessThan(Date().timeIntervalSince(started), Jumper.axPollBudget)
    }

    // MARK: - The field (§9.4)

    func testDesktopTitleDecodes() throws {
        let value = try session("""
        {"session_id":"s1","desktop_title":"Lookout menu bar app","title":"Build the panel"}
        """)
        XCTAssertEqual(value.desktopTitle, "Lookout menu bar app")
        XCTAssertEqual(value.title, "Build the panel")
    }

    func testAMissingOrBlankDesktopTitleIsAsGoodAsAbsent() throws {
        XCTAssertNil(try session("{\"session_id\":\"s1\"}").desktopTitle)

        let blank = try session(
            "{\"session_id\":\"s1\",\"desktop_title\":\"  \",\"title\":\"Prompt\"}"
        )
        XCTAssertEqual(blank.displayTitle, "Prompt", "whitespace never wins over a real title")

        let neither = try session("{\"session_id\":\"s1\"}")
        XCTAssertNil(neither.displayTitle)
    }

    func testDesktopTitleSurvivesARoundTrip() throws {
        let value = try session("""
        {"session_id":"s1","desktop_title":"Lookout menu bar app"}
        """)
        let again = try decoder.decode(Session.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(again.desktopTitle, "Lookout menu bar app")
    }

    // MARK: - The row (§9.4: "rows show desktop_title when present, else title")

    func testTheRowPrefersTheDesktopTitle() throws {
        let working = try session("""
        {"session_id":"s1","state":"working","title":"Build the panel",
         "desktop_title":"Lookout menu bar app"}
        """)
        XCTAssertEqual(working.displayTitle, "Lookout menu bar app")
        XCTAssertEqual(working.secondaryText, "Lookout menu bar app")

        let noDesktopTitle = try session("""
        {"session_id":"s2","state":"working","title":"Build the panel"}
        """)
        XCTAssertEqual(noDesktopTitle.secondaryText, "Build the panel")
    }

    func testTheOtherStatesPreferItToo() throws {
        let json = { (state: String) in
            """
            {"session_id":"s1","state":"\(state)","title":"Prompt","desktop_title":"Desktop"}
            """
        }
        XCTAssertEqual(try session(json("idle")).secondaryText, "Desktop")
        XCTAssertEqual(try session(json("needs_you")).secondaryText, "Desktop")
        XCTAssertEqual(try session(json("running")).secondaryText, "Desktop")
        XCTAssertEqual(try session(json("done")).secondaryText, "Desktop", "no last_message here")
    }

    /// Sub-agents still own the working line — the desktop title does not displace them (§9.3).
    func testSubagentTextStillWinsTheWorkingLine() throws {
        let value = try session("""
        {"session_id":"s1","state":"working","title":"Prompt","desktop_title":"Desktop",
         "subagents":[{"id":"a","type":"general-purpose","description":"Translate module three"}]}
        """)
        XCTAssertEqual(value.secondaryText, "1 agent · Translate module three")
    }

    func testTheTooltipShowsBothTitlesWhenTheyDiffer() throws {
        let drifted = try session("""
        {"session_id":"s1","cwd":"/Users/you/Desktop/Lookout","title":"Build the panel",
         "desktop_title":"Lookout menu bar app"}
        """)
        let lines = drifted.tooltip.components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("Lookout menu bar app"))
        XCTAssertTrue(lines.contains("Prompt: Build the panel"))

        let same = try session("""
        {"session_id":"s1","title":"Build the panel","desktop_title":"Build the panel"}
        """)
        let sameLines = same.tooltip.components(separatedBy: "\n")
        XCTAssertTrue(sameLines.contains("Build the panel"))
        XCTAssertFalse(
            sameLines.contains("Prompt: Build the panel"),
            "one title, one line — the tooltip only doubles up when they have drifted apart"
        )

        let onlyPrompt = try session("{\"session_id\":\"s1\",\"title\":\"Build the panel\"}")
        XCTAssertFalse(onlyPrompt.tooltip.contains("Prompt: "))
    }

    /// SPEC §9.4: a process the scanner found has no transcript reading behind it, so it has no
    /// desktop title and its jump is activation only.
    func testDiscoveredDesktopSessionsHaveNoDesktopTitle() {
        var discovered = Session()
        discovered.sessionID = "discovered-1"
        discovered.host = .claudeDesktop
        discovered.isDiscovered = true
        discovered.state = .running

        XCTAssertNil(discovered.desktopTitle)
        XCTAssertNil(discovered.displayTitle)
    }

    // MARK: - The fixture

    func testTheDesktopFixtureCarriesADesktopTitle() throws {
        let url = Fixtures.sessionsDirectory
            .appendingPathComponent("claude-1d9e4b77-0c52-4a36-8f21-77a5c3b9d401.json")
        let value = try decoder.decode(Session.self, from: Data(contentsOf: url))

        XCTAssertEqual(value.host, .claudeDesktop)
        XCTAssertEqual(value.desktopTitle, "Lookout menu bar app")
        XCTAssertEqual(value.title, "Build the Lookout panel")
        XCTAssertEqual(value.displayTitle, "Lookout menu bar app")
        // `done` still leads with the last message; the titles are the tooltip's business.
        XCTAssertEqual(value.secondaryText, "Done — 24 tests pass and the migration is reversible.")
        XCTAssertTrue(value.tooltip.contains("Prompt: Build the Lookout panel"))
        XCTAssertNotNil(
            Jumper.matchIndex(
                desktopTitle: try XCTUnwrap(value.desktopTitle),
                in: ["New chat", "Running Lookout menu bar app"]
            )
        )
    }
}
