import XCTest
@testable import Lookout

/// SPEC §19.4, the app half: the four record fields, the window each model resolves to, what the
/// chip says and when it turns red, its tooltip, the header's "to compact" tail, and the two
/// Settings values behind all of it.
final class ContextChipTests: XCTestCase {
    private let decoder = JSONDecoder()

    private func session(
        id: String = "s1", agent: SessionAgent = .claude, model: String? = "claude-sonnet-5",
        tokens: Int? = nil, window: Int? = nil, at: Date? = nil, state: SessionState = .working
    ) -> Session {
        var session = Session()
        session.sessionID = id
        session.agent = agent
        session.state = state
        session.model = model
        session.contextTokens = tokens
        session.contextWindow = window
        session.contextAt = at
        return session
    }

    // MARK: - §19.1's record fields

    func testTheFourContextFieldsDecodeAndSurviveARoundTrip() throws {
        let json = """
        {
          "session_id": "s1",
          "agent": "claude",
          "model": "claude-fable-5-1",
          "context_tokens": 412000,
          "context_window": 1000000,
          "context_at": "2026-09-04T09:05:10Z",
          "context_compacted_at": "2026-09-04T08:40:00Z"
        }
        """
        let session = try decoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.contextTokens, 412_000)
        XCTAssertEqual(session.contextWindow, 1_000_000)
        XCTAssertEqual(session.contextAt, ISO8601.date("2026-09-04T09:05:10Z"))
        XCTAssertEqual(session.contextCompactedAt, ISO8601.date("2026-09-04T08:40:00Z"))

        let again = try decoder.decode(Session.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(again.contextTokens, session.contextTokens)
        XCTAssertEqual(again.contextWindow, session.contextWindow)
        XCTAssertEqual(again.contextAt, session.contextAt)
        XCTAssertEqual(again.contextCompactedAt, session.contextCompactedAt)
    }

    /// An older reporter writes none of them, and a compaction writes `context_tokens: null`
    /// (SPEC §19.1). Both mean "not measured", and neither may fail the decode.
    func testMissingAndNullContextFieldsDecodeToNil() throws {
        let missing = try decoder.decode(
            Session.self, from: Data(#"{"session_id": "s1"}"#.utf8)
        )
        XCTAssertNil(missing.contextTokens)
        XCTAssertNil(missing.contextWindow)
        XCTAssertNil(missing.contextAt)
        XCTAssertNil(missing.contextCompactedAt)

        let compacted = try decoder.decode(Session.self, from: Data("""
        {
          "session_id": "s1",
          "context_tokens": null,
          "context_window": null,
          "context_at": null,
          "context_compacted_at": "2026-09-04T08:40:00Z"
        }
        """.utf8))
        XCTAssertNil(compacted.contextTokens)
        XCTAssertNil(compacted.contextWindow)
        XCTAssertNil(compacted.contextAt)
        XCTAssertEqual(compacted.contextCompactedAt, ISO8601.date("2026-09-04T08:40:00Z"))
        XCTAssertNil(
            compacted.contextGauge(windows: .standard),
            "a compacted session has no chip until the next measurement"
        )
    }

    /// A malformed value is the same non-event as a missing one — the row loses its chip, the
    /// session does not disappear.
    func testAMalformedContextValueLeavesTheRestOfTheSessionIntact() throws {
        let session = try decoder.decode(Session.self, from: Data("""
        {"session_id": "s1", "project": "Lookout", "context_tokens": "lots", "context_at": "soon"}
        """.utf8))
        XCTAssertEqual(session.project, "Lookout")
        XCTAssertNil(session.contextTokens)
        XCTAssertNil(session.contextAt)
    }

    // MARK: - §19.3 window resolution

    func testEveryModelFamilyResolvesToItsOwnWindow() {
        let table = ContextWindows.standard
        XCTAssertEqual(table.window(for: session(model: "claude-fable-5-1")), 1_000_000)
        XCTAssertEqual(table.window(for: session(model: "anthropic/claude-opus-5[1m]")), 1_000_000)
        XCTAssertEqual(table.window(for: session(model: "claude-sonnet-5")), 1_000_000)
        XCTAssertEqual(table.window(for: session(model: "claude-haiku-4-5")), 200_000)
        // Neither a named family nor Codex: "other Claude".
        XCTAssertEqual(table.window(for: session(model: "claude-something-new")), 200_000)
        XCTAssertEqual(table.window(for: session(model: nil)), 200_000)
    }

    func testACodexRecordsOwnWindowBeatsTheTableAndTheCodexRowIsTheFallback() {
        let table = ContextWindows.standard
        let reported = session(agent: .codex, model: "gpt-5.6-sol", window: 400_000)
        XCTAssertEqual(table.window(for: reported), 400_000, "the record's own window wins")

        let silent = session(agent: .codex, model: "gpt-5.6-sol")
        XCTAssertEqual(table.window(for: silent), 258_400, "codex row, not other Claude")

        var zeroed = silent
        zeroed.contextWindow = 0
        XCTAssertEqual(table.window(for: zeroed), 258_400, "a zero window is no window")
    }

    func testAnEditedWindowIsWhatTheGaugeMeasuresAgainst() {
        var table = ContextWindows.standard
        table.windows["sonnet"] = 200_000
        let gauge = session(model: "claude-sonnet-5", tokens: 100_000)
            .contextGauge(windows: table)
        XCTAssertEqual(gauge?.window, 200_000)
        XCTAssertEqual(gauge?.percentText, "ctx 50 %")
    }

    // MARK: - §19.2 percentage, threshold and tooltip

    func testThePercentTextRoundsAndCapsAtOneHundred() {
        XCTAssertEqual(ContextGauge(tokens: 236_000, window: 1_000_000).percentText, "ctx 24 %")
        XCTAssertEqual(ContextGauge(tokens: 4_000, window: 1_000_000).percentText, "ctx 0 %")
        XCTAssertEqual(ContextGauge(tokens: 995_000, window: 1_000_000).percentText, "ctx 100 %")
        XCTAssertEqual(
            ContextGauge(tokens: 1_400_000, window: 1_000_000).percentText, "ctx 100 %",
            "past the window it pins at 100 % rather than printing 140 %"
        )
    }

    func testTheThresholdBoundaryIsInclusive() {
        let under = ContextGauge(tokens: 399_000, window: 1_000_000)
        let exact = ContextGauge(tokens: 400_000, window: 1_000_000)
        XCTAssertFalse(under.isOverThreshold(), "39.9 % is not over 40 %")
        XCTAssertTrue(exact.isOverThreshold(), "40.0 % is over — the boundary counts")

        // The threshold Settings actually hands over, built the same way (percent / 100).
        XCTAssertTrue(exact.isOverThreshold(Double(40) / 100))
        XCTAssertFalse(exact.isOverThreshold(Double(45) / 100))
        XCTAssertTrue(exact.isOverThreshold(Double(10) / 100))
        XCTAssertTrue(
            ContextGauge(tokens: 900_000, window: 1_000_000).isOverThreshold(Double(90) / 100)
        )
    }

    func testNoMeasurementMeansNoGaugeAtAll() {
        XCTAssertNil(session(tokens: nil).contextGauge(windows: .standard))
        XCTAssertNil(
            session(tokens: 0).contextGauge(windows: .standard),
            "zero tokens is the reporter saying nothing, not a 0 % chip"
        )
        XCTAssertNotNil(session(tokens: 1).contextGauge(windows: .standard))
    }

    func testTheTooltipSpellsTokensInKAndMAndSaysHowOldItIs() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let gauge = ContextGauge(
            tokens: 236_000, window: 1_000_000, measuredAt: now.addingTimeInterval(-12)
        )
        XCTAssertEqual(
            gauge.tooltip(now: now),
            "236k of 1.0M tokens in context · measured 12s ago"
        )

        let codex = ContextGauge(
            tokens: 96_400, window: 258_400, measuredAt: now.addingTimeInterval(-195)
        )
        XCTAssertEqual(
            codex.tooltip(now: now),
            "96k of 258k tokens in context · measured 3m ago"
        )

        let unmeasured = ContextGauge(tokens: 812, window: 200_000)
        XCTAssertEqual(unmeasured.tooltip(now: now), "812 of 200k tokens in context")
    }

    func testTokenTextPicksItsUnitAfterRounding() {
        XCTAssertEqual(ContextGauge.tokenText(0), "0")
        XCTAssertEqual(ContextGauge.tokenText(999), "999")
        XCTAssertEqual(ContextGauge.tokenText(1_000), "1k")
        XCTAssertEqual(ContextGauge.tokenText(236_400), "236k")
        XCTAssertEqual(ContextGauge.tokenText(999_600), "1.0M")
        XCTAssertEqual(ContextGauge.tokenText(1_240_000), "1.2M")
        XCTAssertEqual(ContextGauge.tokenText(1_260_000), "1.3M")
    }

    // MARK: - §19.2 header text

    func testTheHeaderDetailGainsToCompactOnlyWhenThereIsSomethingToCompact() {
        let base = "8 claude · 2 codex"
        XCTAssertEqual(Session.appendingToCompact(base, count: 0), base)
        XCTAssertEqual(Session.appendingToCompact(base, count: 1), "8 claude · 2 codex · 1 to compact")
        XCTAssertEqual(Session.appendingToCompact(base, count: 2), "8 claude · 2 codex · 2 to compact")
        XCTAssertEqual(
            Session.appendingToCompact("", count: 3), "3 to compact",
            "nothing to break down means no leading separator"
        )
    }

    /// The count itself: over-threshold sessions only, held ones included (SPEC §19.2).
    func testTheToCompactCountCountsEveryLiveSessionOverTheThreshold() {
        let windows = ContextWindows.standard
        let warm = session(id: "a", tokens: 100_000)                    // 10 %
        let hot = session(id: "b", tokens: 500_000)                     // 50 %
        var held = session(id: "c", tokens: 900_000, state: .idle)      // 90 %, on hold
        held.isHeld = true
        let unmeasured = session(id: "d")

        let over = [warm, hot, held, unmeasured].filter {
            $0.contextGauge(windows: windows)?.isOverThreshold() ?? false
        }
        XCTAssertEqual(over.map(\.sessionID), ["b", "c"])
    }

    // MARK: - Settings round-trip

    func testTheThresholdAndTheWindowTablePersistAndReset() {
        let suiteName = "io.github.lukenorgaard.beacon.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let settings = Settings(defaults: defaults)
        XCTAssertEqual(settings.contextWarnPercent, 40, "SPEC §19.2's default")
        XCTAssertEqual(settings.contextWarnFraction, 0.40, accuracy: 0.0001)
        XCTAssertEqual(settings.contextWindows, .standard)

        settings.contextWarnPercent = 65
        settings.contextWindows.windows["sonnet"] = 750_000

        let reopened = Settings(defaults: defaults)
        XCTAssertEqual(reopened.contextWarnPercent, 65)
        XCTAssertEqual(reopened.contextWarnFraction, 0.65, accuracy: 0.0001)
        XCTAssertEqual(reopened.contextWindows.windows["sonnet"], 750_000)
        XCTAssertEqual(
            reopened.contextWindows.windows["fable"], 1_000_000,
            "editing one row leaves the others alone"
        )

        reopened.contextWindows = .standard
        XCTAssertEqual(Settings(defaults: defaults).contextWindows, .standard, "Reset to defaults")
    }

    func testTheThresholdIsClampedToItsRangeAndItsStep() {
        XCTAssertEqual(Settings.clampWarnPercent(40), 40)
        XCTAssertEqual(Settings.clampWarnPercent(5), 10, "below §19.2's 10 %")
        XCTAssertEqual(Settings.clampWarnPercent(120), 90, "above §19.2's 90 %")
        XCTAssertEqual(Settings.clampWarnPercent(43), 45, "off the 5-point step")

        let suiteName = "io.github.lukenorgaard.beacon.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        defaults.set(200, forKey: "contextWarnPercent")
        XCTAssertEqual(Settings(defaults: defaults).contextWarnPercent, 90, "a hand-edited value")

        let settings = Settings(defaults: defaults)
        settings.contextWarnPercent = 3
        XCTAssertEqual(settings.contextWarnPercent, 10)
        XCTAssertEqual(
            Settings(defaults: defaults).contextWarnPercent, 10,
            "the clamped value is what persists"
        )
    }

    // MARK: - §19.2/§19.4 the chip yields before the name does

    func testTheChipFitsBesideALongNameAtTheDesignWidth() {
        let metrics = Theme.Metrics.standard
        let name = "Document the sample command-line tool and keep the examples consistent"
        XCTAssertTrue(
            metrics.contextChipFits(name: name, chip: "ctx 24 %", dot: false),
            "360 pt holds a long name plus the chip"
        )
        XCTAssertTrue(
            metrics.contextChipFits(name: name, chip: "ctx 100 %", dot: true),
            "the widest chip, dot included, still fits at 360 pt"
        )
    }

    /// The narrowest panel at the largest text: the chip is dropped outright rather than clipped,
    /// and the name keeps the line.
    func testTheChipIsDroppedRatherThanClippedWhenTheRowRunsOut() {
        let cramped = Theme.Metrics(
            Appearance(scale: 1.40, panelWidth: 320, listMaxHeight: 480, density: .compact)
        )
        let name = "Document the sample command-line tool and keep the examples consistent"
        XCTAssertFalse(
            cramped.contextChipFits(name: name, chip: "ctx 100 %", dot: true, pinned: true),
            "no room for both, so §19.2's chip is the half that goes"
        )
        XCTAssertTrue(
            cramped.contextChipFits(name: nil, chip: "ctx 24 %", dot: false),
            "a row with no name on line 2 has room for the chip at any width"
        )
    }

    /// The floor is a *measured* twelve characters of the real name, not an average — the
    /// fit answer has to be about the string the row will actually draw.
    func testTheNameFloorIsTwelveCharactersOfTheNameItself() {
        XCTAssertEqual(Theme.Metrics.contextNameFloor, 12)
        let metrics = Theme.Metrics.standard
        let wide = String(repeating: "W", count: 40)
        let narrow = String(repeating: "i", count: 40)
        XCTAssertGreaterThan(
            metrics.contextChipWidth("ctx 100 %", dot: true),
            metrics.contextChipWidth("ctx 100 %", dot: false),
            "the dot and its gap are part of what has to fit"
        )
        // Both fit at 360 pt, but the wide one leaves measurably less room behind it.
        XCTAssertTrue(metrics.contextChipFits(name: wide, chip: "ctx 24 %", dot: false))
        XCTAssertTrue(metrics.contextChipFits(name: narrow, chip: "ctx 24 %", dot: false))
    }
}
