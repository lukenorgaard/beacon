import AppKit
import SwiftUI
import XCTest
@testable import Lookout

/// SPEC §11.4: where the card sits, when it opens, and what its actions do.
final class AttentionCardTests: XCTestCase {
    /// Whatever appearance the test set — the default one unless it says otherwise.
    var metrics: Theme.Metrics { settings.metrics }

    private var suiteName = ""
    private var defaults: UserDefaults!
    var settings: Lookout.Settings!
    var home: LookoutHome!
    private var temporary: URL?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        suiteName = "io.github.lukenorgaard.beacon.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = Lookout.Settings(defaults: defaults)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-card-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporary = root
        home = LookoutHome(root: root)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        temporary = nil
        settings = nil
        defaults = nil
        home = nil
        super.tearDown()
    }

    func session(
        id: String = "s1", state: SessionState = .needsYou, agent: SessionAgent = .claude
    ) -> Session {
        var value = Session()
        value.sessionID = id
        value.state = state
        value.agent = agent
        value.project = "daily-notes"
        value.cwd = "/Users/you/Desktop/daily-notes"
        value.host = .cursor
        value.detail = "Bash: rm -rf build"
        value.pid = 1
        value.stateSince = Date()
        return value
    }

    func request(
        kind: String = "permission", waitsUntil: Date? = Date().addingTimeInterval(45)
    ) throws -> AttentionRequest {
        var json = """
        {"session_id":"s1","request_id":"r1","kind":"\(kind)","tool_name":"Bash",
         "summary":"rm -rf build","command_or_path":"rm -rf build",
         "question":"Which migration?","options":["004","005"]
        """
        if let waitsUntil { json += ",\"waits_until\":\"\(ISO8601.string(waitsUntil))\"" }
        json += "}"
        return try XCTUnwrap(AttentionRequest.decode(Data(json.utf8), name: "claude-s1-r1"))
    }

    // MARK: - Docking geometry (SPEC §11.4)

    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private var cardSize: NSSize { NSSize(width: metrics.cardWidth, height: 420) }

    func testTheCardDocksToThePanelsRightEdgeWithAnEightPointGap() {
        let panel = NSRect(x: 400, y: 300, width: metrics.width, height: 500)
        let placement = CardDock.place(panel: panel, size: cardSize, screen: screen)

        XCTAssertEqual(placement.side, .right)
        XCTAssertEqual(placement.origin.x, panel.maxX + 8)
        XCTAssertEqual(metrics.dockGap, 8)
        XCTAssertEqual(metrics.cardWidth, 380)
        // Top edges line up.
        XCTAssertEqual(placement.origin.y + cardSize.height, panel.maxY)
    }

    func testItGoesToTheLeftEdgeWhenTheRightWouldLeaveTheScreen() {
        // The panel's usual home: 16 pt in from the right edge.
        let panel = NSRect(
            x: screen.maxX - metrics.width - 16, y: 300,
            width: metrics.width, height: 500
        )
        let placement = CardDock.place(panel: panel, size: cardSize, screen: screen)

        XCTAssertEqual(placement.side, .left)
        XCTAssertEqual(placement.origin.x, panel.minX - 8 - cardSize.width)
        XCTAssertGreaterThanOrEqual(placement.origin.x, screen.minX)
        XCTAssertLessThanOrEqual(placement.origin.x + cardSize.width, panel.minX)
    }

    /// Menu bar mode: no panel on screen to dock to, so the card takes the panel's own corner
    /// and still lands on the left of it.
    func testWithNoPanelOnScreenTheCardUsesThePanelsOwnCorner() {
        let anchorFrame = CardDock.defaultAnchor(in: screen)
        XCTAssertEqual(anchorFrame.maxX, screen.maxX - 16)
        XCTAssertEqual(anchorFrame.width, metrics.width)

        let placement = CardDock.place(panel: anchorFrame, size: cardSize, screen: screen)
        XCTAssertEqual(placement.side, .left)
        XCTAssertGreaterThanOrEqual(placement.origin.x, screen.minX)
        XCTAssertLessThanOrEqual(placement.origin.y + cardSize.height, screen.maxY)
    }

    func testTheCardIsAlwaysFullyOnTheScreen() {
        // A screen with room for neither side still gets a card that is entirely on it.
        let narrow = NSRect(x: 0, y: 0, width: 420, height: 500)
        let panel = NSRect(x: 20, y: 0, width: metrics.width, height: 480)
        let placement = CardDock.place(panel: panel, size: cardSize, screen: narrow)
        XCTAssertGreaterThanOrEqual(placement.origin.x, narrow.minX)
        XCTAssertLessThanOrEqual(placement.origin.x + cardSize.width, narrow.maxX)

        // A card taller than the space below the panel's top slides down onto the screen.
        let low = NSRect(x: 400, y: 0, width: metrics.width, height: 120)
        let tall = CardDock.place(
            panel: low, size: NSSize(width: 380, height: 560), screen: screen
        )
        XCTAssertGreaterThanOrEqual(tall.origin.y, screen.minY)
        XCTAssertLessThanOrEqual(tall.origin.y + 560, screen.maxY)
    }

    /// SPEC §11.4: the card takes typing without Lookout stealing the front — which is exactly
    /// the property the panel does *not* have.
    func testTheCardWindowCanBecomeKeyButNeverMain() {
        let window = AttentionCardWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 400))
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertFalse(window.canBecomeMain)
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertFalse(window.styleMask.contains(.titled))
        XCTAssertEqual(window.level, .floating)
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))

        // Escape = Ignore.
        var cancelled = false
        window.onCancel = { cancelled = true }
        window.cancelOperation(nil)
        XCTAssertTrue(cancelled)
    }

    // MARK: - Triggers and opt-in (SPEC §11.4)

    func testACardOpensOnNeedsYouAndOnlyOnDoneWhenAskedFor() {
        let coordinator = AttentionCoordinator(settings: settings)

        coordinator.handle(transition: session(state: .needsYou), from: .working)
        XCTAssertEqual(coordinator.current?.id, "s1")
        XCTAssertEqual(coordinator.current?.trigger, .needsYou)

        coordinator.closeAll()
        coordinator.handle(transition: session(id: "s2", state: .done), from: .working)
        XCTAssertNil(coordinator.current, "done is off by default (SPEC §11.4)")

        settings.cardOnDone = true
        coordinator.handle(transition: session(id: "s2", state: .done), from: .working)
        XCTAssertEqual(coordinator.current?.id, "s2")

        // Working and idle never open a card.
        coordinator.closeAll()
        coordinator.handle(transition: session(id: "s3", state: .working), from: .idle)
        coordinator.handle(transition: session(id: "s4", state: .idle), from: .working)
        XCTAssertNil(coordinator.current)
    }

    func testTheMasterToggleAndThePerSessionOptInBothGate() {
        let coordinator = AttentionCoordinator(settings: settings)

        settings.attentionCards = false
        coordinator.handle(transition: session(), from: .working)
        XCTAssertNil(coordinator.current)

        settings.attentionCards = true
        settings.cardsForNewSessions = false
        coordinator.handle(transition: session(), from: .working)
        XCTAssertNil(coordinator.current, "a new session is opted out")

        // …until this one session is opted in by hand (the row's right-click menu).
        settings.setCards(true, for: "s1")
        XCTAssertTrue(settings.cardsEnabled(for: "s1"))
        coordinator.handle(transition: session(), from: .working)
        XCTAssertEqual(coordinator.current?.id, "s1")

        // And the other way round.
        settings.cardsForNewSessions = true
        settings.setCards(false, for: "s9")
        XCTAssertFalse(settings.cardsEnabled(for: "s9"))
        XCTAssertTrue(settings.cardsEnabled(for: "s8"), "everyone else follows the default")
    }

    func testIgnoreLastsUntilTheNextTransitionOfThatSession() {
        let coordinator = AttentionCoordinator(settings: settings)
        coordinator.handle(transition: session(), from: .working)
        XCTAssertNotNil(coordinator.current)

        coordinator.ignoreCurrent()
        XCTAssertNil(coordinator.current)

        // The same state arriving again does not reopen it.
        coordinator.handle(transition: session(), from: .needsYou)
        XCTAssertNil(coordinator.current)

        // A real transition clears the ignore, and the next needs_you opens a card again.
        coordinator.handle(transition: session(state: .working), from: .needsYou)
        coordinator.handle(transition: session(state: .needsYou), from: .working)
        XCTAssertEqual(coordinator.current?.id, "s1")
    }

    func testOneCardAtATimeWithTheRestQueued() {
        let coordinator = AttentionCoordinator(settings: settings)
        coordinator.handle(transition: session(id: "a"), from: .working)
        coordinator.handle(transition: session(id: "b"), from: .working)
        coordinator.handle(transition: session(id: "c"), from: .working)

        XCTAssertEqual(coordinator.current?.id, "a")
        XCTAssertEqual(coordinator.pendingCount, 2)

        coordinator.dismissCurrent()
        XCTAssertEqual(coordinator.current?.id, "b")
        XCTAssertEqual(coordinator.pendingCount, 1)

        // The same session twice is one card, not two.
        coordinator.handle(transition: session(id: "c", state: .working), from: .needsYou)
        coordinator.handle(transition: session(id: "c"), from: .working)
        XCTAssertEqual(coordinator.queue.map(\.id), ["b", "c"])

        // The queue is bounded.
        for index in 0..<20 {
            coordinator.handle(transition: session(id: "x\(index)"), from: .working)
        }
        XCTAssertEqual(coordinator.queue.count, AttentionCoordinator.maxQueue)
    }

    func testTheCardClosesItselfWhenTheSessionLeavesTheState() {
        let coordinator = AttentionCoordinator(settings: settings)
        coordinator.handle(transition: session(id: "a"), from: .working)
        coordinator.handle(transition: session(id: "b"), from: .working)
        XCTAssertEqual(coordinator.queue.count, 2)

        // `a` answered elsewhere (its state file went back to working), `b` still waiting.
        coordinator.apply(sessions: [session(id: "a", state: .working), session(id: "b")])
        XCTAssertEqual(coordinator.queue.map(\.id), ["b"])

        // The session disappears entirely.
        coordinator.apply(sessions: [])
        XCTAssertTrue(coordinator.queue.isEmpty)
    }

    /// The store publishes an empty list before its first read, and a per-session choice must
    /// survive that.
    func testAnEmptySessionListNeverWipesThePerSessionChoices() {
        settings.setCards(false, for: "s1")
        XCTAssertEqual(settings.cardOverrides, ["s1": false])

        XCTAssertFalse(AppState.shouldPrune([]), "the launch-time empty list prunes nothing")
        XCTAssertTrue(AppState.shouldPrune([session()]))

        // What the guard prevents: pruning against nothing keeps nothing.
        settings.pruneCardOverrides(keeping: [])
        XCTAssertTrue(settings.cardOverrides.isEmpty)
    }
}
