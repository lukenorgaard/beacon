import XCTest
@testable import Lookout

final class SessionModelTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testDecodesAFullStateFile() throws {
        let json = """
        {
          "schema": 1,
          "agent": "claude",
          "session_id": "ab813983-4f21-4c0e-9a17-2f5b6c8d1e00",
          "state": "needs_you",
          "reason": "permission",
          "detail": "Bash: rm -rf build",
          "cwd": "/Users/you/Desktop/daily-notes",
          "project": "daily-notes",
          "title": "Fix the login redirect loop",
          "last_message": "Done — tests pass.",
          "pid": 85281,
          "tty": "ttys005",
          "host": "cursor",
          "host_pid": 43085,
          "host_ref": "w0t0p0:ABCD",
          "entrypoint": "cli",
          "transcript_path": "/Users/you/.claude/projects/x/ab81.jsonl",
          "started_at": "2026-09-02T09:02:43Z",
          "state_since": "2026-09-02T09:05:10Z",
          "updated_at": "2026-09-02T09:05:10Z"
        }
        """
        let session = try decoder.decode(Session.self, from: Data(json.utf8))

        XCTAssertEqual(session.agent, .claude)
        XCTAssertEqual(session.state, .needsYou)
        XCTAssertEqual(session.host, .cursor)
        XCTAssertEqual(session.hostPID, 43085)
        XCTAssertEqual(session.pid, 85281)
        XCTAssertEqual(session.project, "daily-notes")
        XCTAssertEqual(session.tty, "ttys005")
        XCTAssertEqual(session.transcriptPath, "/Users/you/.claude/projects/x/ab81.jsonl")
        XCTAssertNotNil(session.startedAt)
        XCTAssertEqual(session.stateSince, ISO8601.date("2026-09-02T09:05:10Z"))
        XCTAssertFalse(session.isDiscovered)

        XCTAssertEqual(session.statusLabel, "Needs permission · Bash")
        XCTAssertEqual(session.secondaryText, "rm -rf build")
        XCTAssertEqual(session.detailTool, "Bash")
    }

    /// SPEC §16.2: the reporter's new `shell_pid`, which is what the editor companion matches a
    /// terminal on. Absent in an older reporter's file, and that has to stay harmless.
    func testShellPidDecodesAndSurvivesARoundTrip() throws {
        let json = """
        {"session_id": "s1", "host": "cursor", "pid": 85281, "shell_pid": 85280}
        """
        let session = try decoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.shellPid, 85_280)

        let encoded = try JSONEncoder().encode(session)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(object["shell_pid"] as? Int, 85_280)
        XCTAssertEqual(try decoder.decode(Session.self, from: encoded).shellPid, 85_280)

        let older = try decoder.decode(
            Session.self, from: Data(#"{"session_id": "s2", "host": "cursor"}"#.utf8)
        )
        XCTAssertNil(older.shellPid)
        let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(older))
        XCTAssertNil((reencoded as? [String: Any])?["shell_pid"], "absent stays absent")

        // A non-numeric value degrades to nil rather than failing the whole decode.
        let odd = try decoder.decode(
            Session.self,
            from: Data(#"{"session_id": "s3", "shell_pid": "not a pid"}"#.utf8)
        )
        XCTAssertNil(odd.shellPid)
        XCTAssertEqual(odd.sessionID, "s3")
    }

    func testDecodesAMinimalStateFile() throws {
        // Only `session_id` is really required; everything else has to degrade quietly.
        let json = """
        { "session_id": "minimal-1", "cwd": "/Users/you/Desktop/Voyager" }
        """
        let session = try decoder.decode(Session.self, from: Data(json.utf8))

        XCTAssertEqual(session.sessionID, "minimal-1")
        XCTAssertEqual(session.schema, 1)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.host, .unknown)
        XCTAssertEqual(session.agent, .unknown)
        // `project` is only ever basename(cwd), so a missing one is recoverable.
        XCTAssertEqual(session.project, "Voyager")
        XCTAssertNil(session.pid)
        XCTAssertNil(session.stateSince)
        XCTAssertEqual(session.timeInState(), 0)
        XCTAssertEqual(session.statusLabel, "Idle")
    }

    func testUnknownEnumValuesAndUnknownFieldsDoNotBreakTheDecode() throws {
        let json = """
        {
          "schema": 7,
          "session_id": "future-1",
          "state": "meditating",
          "host": "warp",
          "agent": "gemini",
          "cwd": "/tmp/x",
          "brand_new_field": {"nested": [1, 2, 3]}
        }
        """
        let session = try decoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.schema, 7)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.host, .unknown)
        XCTAssertEqual(session.agent.name, "gemini")
        XCTAssertEqual(session.agent.glyph, "G")
        XCTAssertTrue(session.agent.glyphIsLetter)
    }

    func testMissingSessionIDIsTheOnlyFatalCase() {
        let json = #"{"state": "working"}"#
        XCTAssertThrowsError(try decoder.decode(Session.self, from: Data(json.utf8)))
    }

    func testRoundTripsThroughEncode() throws {
        let original = try decoder.decode(
            Session.self,
            from: Data(#"{"session_id":"x","state":"done","host":"iterm","agent":"codex","cwd":"/a/b","updated_at":"2026-09-02T09:20:02Z"}"#.utf8)
        )
        let data = try JSONEncoder().encode(original)
        let again = try decoder.decode(Session.self, from: data)
        XCTAssertEqual(original, again)
    }

    func testStatusLabelsAndSecondaryTextPerState() throws {
        func session(_ json: String) throws -> Session {
            try decoder.decode(Session.self, from: Data(json.utf8))
        }
        XCTAssertEqual(
            try session(#"{"session_id":"1","state":"needs_you","reason":"question","detail":"Which DB?"}"#)
                .statusLabel,
            "Question for you"
        )
        XCTAssertEqual(
            try session(#"{"session_id":"2","state":"done","last_message":"All green."}"#)
                .secondaryText,
            "All green."
        )
        XCTAssertEqual(try session(#"{"session_id":"3","state":"working"}"#).statusLabel, "Working…")
        XCTAssertEqual(
            try session(#"{"session_id":"4","state":"running","reason":"discovered"}"#).statusLabel,
            "Running · no hooks"
        )
    }

    /// SPEC §15.3: line 2 of a row — a home-folder name is not the session, so the row says what
    /// the session *is*, not only where it runs.
    func testTheSessionNameIsTheDesktopTitleThenThePromptThenTheFolder() throws {
        func session(_ json: String) throws -> Session {
            try decoder.decode(Session.self, from: Data(json.utf8))
        }

        // The desktop app's own title wins over the first prompt.
        let both = try session(
            #"{"session_id":"1","state":"working","title":"Fix the login redirect loop","#
                + #""desktop_title":"Lookout menu bar app"}"#
        )
        XCTAssertEqual(both.sessionName, "Lookout menu bar app")
        XCTAssertFalse(both.sessionNameIsPath)

        // No desktop title: the first prompt.
        XCTAssertEqual(
            try session(#"{"session_id":"2","state":"working","title":"Rewrite onboarding"}"#)
                .sessionName,
            "Rewrite onboarding"
        )

        // Neither — a row discovered without hooks — falls back to where it is running, with
        // the home directory shortened away.
        let home = NSHomeDirectory()
        let discovered = try session(
            #"{"session_id":"3","state":"running","reason":"discovered","cwd":"#
                + "\"\(home)/Desktop/Beacon\"}"
        )
        XCTAssertEqual(discovered.sessionName, "~/Desktop/Beacon")
        XCTAssertTrue(discovered.sessionNameIsPath)
        XCTAssertEqual(Format.tildePath("/opt/homebrew/bin"), "/opt/homebrew/bin")
        XCTAssertEqual(Format.tildePath(home), "~")

        // Nothing at all: no second line rather than an empty one.
        XCTAssertNil(try session(#"{"session_id":"4","state":"idle"}"#).sessionName)

        // A very long title is cut here, not by the label.
        let long = try session(
            "{\"session_id\":\"5\",\"state\":\"working\",\"title\":\""
                + String(repeating: "x", count: 200) + "\"}"
        )
        XCTAssertEqual(
            long.sessionName?.count, Session.sessionNameLimit + 1, "90 characters plus the ellipsis"
        )

        // SPEC §15.3: line 3 never repeats line 2.
        XCTAssertEqual(discovered.secondaryText, "\(home)/Desktop/Beacon")
        XCTAssertNil(discovered.rowDetail, "line 3 drops what line 2 already says")
        XCTAssertEqual(
            try session(
                #"{"session_id":"6","state":"done","title":"t","last_message":"All green."}"#
            ).rowDetail,
            "All green."
        )
    }

    func testEveryFixtureFileDecodes() throws {
        let files = try FileManager.default
            .contentsOfDirectory(atPath: Fixtures.sessionsDirectory.path)
            .filter { $0.hasSuffix(".json") }
        XCTAssertEqual(files.count, 6, "the six sample state files should all be there")

        var states = Set<SessionState>()
        var hosts = Set<SessionHost>()
        for name in files {
            let url = Fixtures.sessionsDirectory.appendingPathComponent(name)
            let session = try decoder.decode(Session.self, from: Data(contentsOf: url))
            XCTAssertEqual(session.pid, 1, "fixtures use pid 1 so liveness pruning keeps them")
            XCTAssertFalse(session.project.isEmpty)
            states.insert(session.state)
            hosts.insert(session.host)
        }
        XCTAssertEqual(states, [.needsYou, .done, .working, .idle])
        XCTAssertEqual(hosts, [.cursor, .devin, .terminal, .iterm, .claudeDesktop])
    }

    func testHeaderSummaryCountsEveryAgentByName() throws {
        let sessions = try [
            #"{"session_id":"1","agent":"claude","state":"working"}"#,
            #"{"session_id":"2","agent":"claude","state":"idle"}"#,
            #"{"session_id":"3","agent":"codex","state":"done"}"#,
            #"{"session_id":"4","agent":"gemini","state":"running"}"#,
        ].map { try decoder.decode(Session.self, from: Data($0.utf8)) }

        XCTAssertEqual(Session.summary(sessions), "4 agents · 2 claude · 1 codex · 1 gemini")
        XCTAssertEqual(Session.summary([]), "No sessions")
    }

    func testDurationSpelling() {
        XCTAssertEqual(Format.duration(0), "0s")
        XCTAssertEqual(Format.duration(48), "48s")
        XCTAssertEqual(Format.duration(180), "3m")
        XCTAssertEqual(Format.duration(3600), "1h")
        XCTAssertEqual(Format.duration(4320), "1h 12m")
        XCTAssertEqual(Format.duration(-5), "0s")
    }
}
