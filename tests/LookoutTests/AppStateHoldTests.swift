import AppKit
import XCTest
@testable import Lookout

/// The "Put on hold" manual override (the owner: "one can be finished or on hold ... not closing
/// it") wired all the way through `AppState`: the auto-clear sweep, the sort, the header/status
/// counts, and suppressing the notification/card path.
///
/// `apply(_:)` and `handle(transition:from:)` are internal rather than private exactly so a
/// headless test can drive them directly, without `start()` — which would touch the network, the
/// notification center and Carbon (see `AppState.refreshCodexUsage()` for the same reasoning).
final class AppStateHoldTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var settings: Lookout.Settings!
    private var state: AppState!
    private var temporary: URL?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        suiteName = "io.github.lukenorgaard.beacon.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = Lookout.Settings(defaults: defaults)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-hold-\(UUID().uuidString)")
        temporary = root
        state = AppState(
            settings: settings,
            store: SessionStore(home: root),
            usage: UsageClient(),
            home: LookoutHome(root: root)
        )
        // `handle(transition:)` calls `Notifier.notify` for an un-suppressed needs_you/done
        // transition; `UNUserNotificationCenter` crashes the whole test binary outside a real
        // app bundle, so every test here goes through the card (`state.attention`) instead.
        settings.notifyNeedsYou = false
        settings.notifyDone = false
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        temporary = nil
        state = nil
        settings = nil
        defaults = nil
        super.tearDown()
    }

    /// `stateSince` lands safely in the past relative to *real* wall-clock time — unlike
    /// `SortOrderTests`' fixed epoch, `SessionHold.shouldClear` compares this against a real
    /// `Date()` held timestamp, so it must not accidentally land in the future.
    private func session(_ id: String, _ value: SessionState, minutesAgo: Double = 60) -> Session {
        var session = Session()
        session.sessionID = id
        session.state = value
        session.project = id
        session.stateSince = Date().addingTimeInterval(-minutesAgo * 60)
        return session
    }

    // MARK: - Sort and counts

    func testAHeldSessionSortsBelowIdleAndOutOfTheWorkingCount() {
        settings.heldSessions["held"] = Date()
        state.apply([
            session("held", .working),
            session("idle", .idle),
            session("working", .working),
        ])

        XCTAssertEqual(state.allSessions.map(\.id), ["working", "idle", "held"])
        XCTAssertTrue(state.allSessions.last?.isHeld ?? false)
        XCTAssertEqual(state.workingCount, 1, "the held session is excluded from the count while held")
    }

    func testAHeldSessionCountsAsIdleForTheFilterChipsAndIsHiddenWithIdle() {
        settings.heldSessions["held"] = Date()
        state.apply([session("held", .done), session("working", .working)])

        let held = try! XCTUnwrap(state.allSessions.first { $0.id == "held" })
        XCTAssertEqual(StateFilter.of(held), .idle)

        settings.showIdle = false
        state.apply([session("held", .done), session("working", .working)])
        XCTAssertEqual(
            state.visibleSessions.map(\.id), ["working"],
            "on hold is treated like idle — hidden right along with it"
        )
    }

    func testTheHeaderExcludesAHeldSessionsUnseenDoneCountAndTheStatusDotStaysGrey() {
        settings.heldSessions["held"] = Date()
        state.apply([session("held", .done)])
        XCTAssertEqual(state.unseenDoneCount, 0)
        XCTAssertEqual(
            state.statusColor, .systemGray,
            "a held, finished session must not light the status dot green"
        )
    }

    // MARK: - Auto-clear (needs_you always wins)

    func testNeedsYouWinsSortsOnTopAndClearsTheHold() {
        settings.heldSessions["held"] = Date()
        state.apply([session("held", .needsYou), session("other", .working)])

        XCTAssertEqual(state.allSessions.first?.id, "held")
        XCTAssertFalse(state.allSessions.first?.isHeld ?? true)
        XCTAssertNil(settings.heldSessions["held"], "needs_you clears the hold outright")
    }

    func testAFreshWorkingTurnClearsTheHoldOnTheNextApply() {
        let heldAt = Date(timeIntervalSince1970: 1_800_000_000)
        settings.heldSessions["held"] = heldAt
        var fresh = session("held", .working)
        fresh.stateSince = heldAt.addingTimeInterval(120)
        state.apply([fresh])

        XCTAssertNil(settings.heldSessions["held"])
        XCTAssertFalse(state.allSessions.first?.isHeld ?? true)
    }

    func testAQuietDoneKeepsTheHoldAcrossAnApply() {
        let heldAt = Date(timeIntervalSince1970: 1_800_000_000)
        settings.heldSessions["held"] = heldAt
        var done = session("held", .done)
        done.stateSince = heldAt.addingTimeInterval(120)
        state.apply([done])

        XCTAssertEqual(settings.heldSessions["held"], heldAt)
        XCTAssertTrue(state.allSessions.first?.isHeld ?? false)
    }

    // MARK: - toggleHold (the row's context menu)

    func testToggleHoldSetsAndClearsTheEntry() {
        let target = session("s1", .idle)
        state.apply([target])
        XCTAssertFalse(state.isHeld(state.allSessions[0]))

        state.toggleHold(for: target)
        XCTAssertNotNil(settings.heldSessions["s1"])

        state.toggleHold(for: target)
        XCTAssertNil(settings.heldSessions["s1"])
    }

    // MARK: - Notification/card suppression

    func testAHeldSessionsDoneTransitionOpensNoCard() {
        settings.cardOnDone = true
        settings.heldSessions["s1"] = Date()
        state.handle(transition: session("s1", .done), from: .working)
        XCTAssertNil(state.attention.current)
        XCTAssertNotNil(settings.heldSessions["s1"], "a quiet done keeps the hold")
    }

    /// The control: without a hold the same transition opens a card normally, so the previous
    /// test's `nil` is really the hold suppressing it and not some other setting.
    func testWithoutAHoldTheSameDoneTransitionDoesOpenACard() {
        settings.cardOnDone = true
        state.handle(transition: session("s1", .done), from: .working)
        XCTAssertEqual(state.attention.current?.id, "s1")
    }

    func testNeedsYouStillOpensACardAndClearsTheHold() {
        settings.heldSessions["s1"] = Date()
        state.handle(transition: session("s1", .needsYou), from: .working)
        XCTAssertEqual(state.attention.current?.id, "s1")
        XCTAssertNil(settings.heldSessions["s1"])
    }

    func testAnUnrelatedSessionsTransitionIsUnaffectedByAnothersHold() {
        settings.heldSessions["held"] = Date()
        state.handle(transition: session("other", .needsYou), from: .working)
        XCTAssertEqual(state.attention.current?.id, "other")
    }

    // MARK: - History tab fallback (Settings → General → Panel)

    func testVisibleCasesDropsHistoryWhenTheSwitchIsOffAndKeepsItWhenOn() {
        // SPEC §18: Sentinel rides along on its own switch, which defaults on — the History
        // half of the rule is unchanged, which is what this test is still about.
        XCTAssertEqual(
            PanelTab.visibleCases(showHistory: true, showSentinel: false),
            [.sessions, .agents, .history, .usage]
        )
        XCTAssertEqual(
            PanelTab.visibleCases(showHistory: false, showSentinel: false),
            [.sessions, .agents, .usage]
        )
        XCTAssertEqual(
            PanelTab.visibleCases(showHistory: true),
            [.sessions, .agents, .history, .usage, .sentinel]
        )
    }

    func testResolveTabFallsBackToSessionsWhenHistoryIsSelectedAndTheSwitchIsOff() {
        state.tab = .history
        settings.showHistoryTab = false
        state.resolveTabIfNeeded()
        XCTAssertEqual(state.tab, .sessions)
    }

    func testResolveTabLeavesHistorySelectedWhenTheSwitchIsOn() {
        state.tab = .history
        settings.showHistoryTab = true
        state.resolveTabIfNeeded()
        XCTAssertEqual(state.tab, .history)
    }

    func testResolveTabDoesNothingWhenAnotherTabIsSelected() {
        state.tab = .agents
        settings.showHistoryTab = false
        state.resolveTabIfNeeded()
        XCTAssertEqual(state.tab, .agents)
    }
}
