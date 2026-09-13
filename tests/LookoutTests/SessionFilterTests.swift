import XCTest
@testable import Lookout

/// SPEC §17.3: the chips, the host popover, the four orders, pinning and `showing x of y` — all
/// pure functions of a session list, so none of this needs a window.
final class SessionFilterTests: XCTestCase {
    private func session(
        _ id: String, _ state: SessionState, host: SessionHost = .cursor,
        project: String? = nil, minutesAgo: Double = 0, updatedMinutesAgo: Double? = nil
    ) throws -> Session {
        let since = ISO8601.string(Date(timeIntervalSince1970: 1_800_000_000 - minutesAgo * 60))
        var json = """
        {"session_id":"\(id)","state":"\(state.rawValue)","host":"\(host.rawValue)",
         "state_since":"\(since)"
        """
        if let project { json += ",\"project\":\"\(project)\"" }
        if let updatedMinutesAgo {
            let updated = ISO8601.string(
                Date(timeIntervalSince1970: 1_800_000_000 - updatedMinutesAgo * 60)
            )
            json += ",\"updated_at\":\"\(updated)\""
        }
        json += "}"
        return try JSONDecoder().decode(Session.self, from: Data(json.utf8))
    }

    // MARK: - State chips

    func testAnEmptyStateSetMatchesEverySession() throws {
        let session = try session("a", .working)
        XCTAssertTrue(SessionFilter.matches(session, states: []))
    }

    func testAStateSetOnlyMatchesItsOwnChips() throws {
        let needs = try session("a", .needsYou)
        let working = try session("b", .working)
        XCTAssertTrue(SessionFilter.matches(needs, states: [.needsYou]))
        XCTAssertFalse(SessionFilter.matches(working, states: [.needsYou]))
        XCTAssertTrue(SessionFilter.matches(working, states: [.needsYou, .working]))
    }

    /// `running` (a discovered, hookless session) has no chip of its own — it counts as
    /// `working`, the closer of the two active states.
    func testARunningSessionCountsAsWorking() throws {
        let running = try session("a", .running)
        XCTAssertEqual(StateFilter.of(.running), .working)
        XCTAssertTrue(SessionFilter.matches(running, states: [.working]))
        XCTAssertFalse(SessionFilter.matches(running, states: [.idle]))
    }

    // MARK: - On hold (manual override)

    /// A held session counts and filters under the Idle chip, whatever it was doing underneath.
    func testAHeldSessionCountsAndFiltersAsIdle() throws {
        var held = try session("a", .working)
        held.isHeld = true
        XCTAssertEqual(StateFilter.of(held), .idle)
        XCTAssertTrue(SessionFilter.matches(held, states: [.idle]))
        XCTAssertFalse(SessionFilter.matches(held, states: [.working]))
    }

    /// `needs_you` always wins — even a session somehow still marked `isHeld` (in practice
    /// `AppState` clears the hold via `SessionHold` first) counts and filters as `needs_you`,
    /// never as idle.
    func testAHeldNeedsYouSessionStillCountsAsNeedsYou() throws {
        var held = try session("a", .needsYou)
        held.isHeld = true
        XCTAssertEqual(StateFilter.of(held), .needsYou)
        XCTAssertTrue(SessionFilter.matches(held, states: [.needsYou]))
    }

    // MARK: - Host popover

    func testAnEmptyHostSetMatchesEveryHost() throws {
        let session = try session("a", .working, host: .devin)
        XCTAssertTrue(SessionFilter.matches(session, hosts: []))
    }

    func testAHostSetOnlyMatchesItsOwnHosts() throws {
        let cursor = try session("a", .working, host: .cursor)
        let devin = try session("b", .working, host: .devin)
        XCTAssertTrue(SessionFilter.matches(cursor, hosts: [.cursor]))
        XCTAssertFalse(SessionFilter.matches(devin, hosts: [.cursor]))
    }

    // MARK: - apply(): both filters, then order

    func testApplyCombinesTheStateAndHostFilters() throws {
        let sessions = try [
            session("a", .needsYou, host: .cursor),
            session("b", .needsYou, host: .devin),
            session("c", .working, host: .cursor),
        ]
        let filtered = SessionFilter.apply(
            sessions, states: [.needsYou], hosts: [.cursor], order: .state, pinned: []
        )
        XCTAssertEqual(filtered.map(\.id), ["a"])
    }

    // MARK: - Orders (SPEC §17.3)

    /// `.state` is a no-op: the list already arrives in the §8.2 order.
    func testStateOrderLeavesTheListExactlyAsItArrived() throws {
        let sessions = try [session("b", .working), session("a", .working)]
        XCTAssertEqual(
            SessionFilter.sorted(sessions, order: .state, pinned: []).map(\.id), ["b", "a"]
        )
    }

    func testActivityOrderIsNewestUpdatedFirst() throws {
        let sessions = try [
            session("old", .working, updatedMinutesAgo: 40),
            session("new", .working, updatedMinutesAgo: 1),
            session("mid", .working, updatedMinutesAgo: 10),
        ]
        XCTAssertEqual(
            SessionFilter.sorted(sessions, order: .activity, pinned: []).map(\.id),
            ["new", "mid", "old"]
        )
    }

    func testProjectOrderIsAlphabeticalAndCaseInsensitive() throws {
        let sessions = try [
            session("z", .working, project: "zebra"),
            session("a", .working, project: "Acme"),
            session("m", .working, project: "mid"),
        ]
        XCTAssertEqual(
            SessionFilter.sorted(sessions, order: .project, pinned: []).map(\.id),
            ["a", "m", "z"]
        )
    }

    /// Pinned first, and a tie between two pinned (or two unpinned) sessions keeps the order
    /// they arrived in — the §8.2 state order is always the secondary key.
    func testPinnedOrderPutsPinnedFirstAndKeepsStateOrderAsTheTiebreak() throws {
        let sessions = try [
            session("needs", .needsYou),
            session("done", .done),
            session("working-pinned", .working),
            session("idle-pinned", .idle),
        ]
        let pinned: Set<String> = ["working-pinned", "idle-pinned"]
        XCTAssertEqual(
            SessionFilter.sorted(sessions, order: .pinned, pinned: pinned).map(\.id),
            ["working-pinned", "idle-pinned", "needs", "done"]
        )
    }

    func testPinningNothingIsTheSameAsStateOrder() throws {
        let sessions = try [session("a", .needsYou), session("b", .done)]
        XCTAssertEqual(
            SessionFilter.sorted(sessions, order: .pinned, pinned: []).map(\.id), ["a", "b"]
        )
    }

    // MARK: - `showing x of y` (SPEC §17.3)

    func testSummaryIsNilWhenNothingIsHidden() {
        XCTAssertNil(SessionFilter.summary(shown: 13, total: 13))
    }

    func testSummarySaysShowingXOfY() {
        XCTAssertEqual(SessionFilter.summary(shown: 4, total: 13), "showing 4 of 13")
    }

    // MARK: - Settings persistence (SPEC §17.3)

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "io.github.lukenorgaard.beacon.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testFilterAndOrderSettingsDefaultToAllAndState() {
        let settings = Settings(defaults: defaults)
        XCTAssertTrue(settings.filterStates.isEmpty)
        XCTAssertTrue(settings.filterHosts.isEmpty)
        XCTAssertEqual(settings.sessionOrder, .state)
        XCTAssertTrue(settings.pinnedSessions.isEmpty)
    }

    func testFilterAndOrderSettingsPersistAcrossInstances() {
        let settings = Settings(defaults: defaults)
        settings.filterStates = [.needsYou, .working]
        settings.filterHosts = [.cursor]
        settings.sessionOrder = .pinned

        let reopened = Settings(defaults: defaults)
        XCTAssertEqual(reopened.filterStates, [.needsYou, .working])
        XCTAssertEqual(reopened.filterHosts, [.cursor])
        XCTAssertEqual(reopened.sessionOrder, .pinned)
    }

    func testTogglePinRoundTripsAndIgnoresABlankID() {
        let settings = Settings(defaults: defaults)
        XCTAssertFalse(settings.isPinned("s1"))

        settings.togglePin("s1")
        XCTAssertTrue(settings.isPinned("s1"))
        XCTAssertEqual(Settings(defaults: defaults).pinnedSessions, ["s1"])

        settings.togglePin("s1")
        XCTAssertFalse(settings.isPinned("s1"))

        settings.togglePin("")
        XCTAssertTrue(settings.pinnedSessions.isEmpty, "a blank id is not a session")
    }

    func testPrunePinnedDropsSessionsThatNoLongerExist() {
        let settings = Settings(defaults: defaults)
        settings.togglePin("s1")
        settings.togglePin("s2")
        settings.prunePinned(keeping: ["s2"])
        XCTAssertEqual(settings.pinnedSessions, ["s2"])
    }
}
