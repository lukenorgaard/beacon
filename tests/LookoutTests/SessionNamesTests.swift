import Combine
import XCTest
@testable import Lookout

/// SPEC §15.4: `~/.lookout/names.json`, what a renamed row shows, and the one case that is easy
/// to lose — a discovered row that gets a hook file, and a new session id with it.
final class SessionNamesTests: XCTestCase {
    private var root: URL!
    private var home: LookoutHome!
    private var cancellables = Set<AnyCancellable>()

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-names-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        home = LookoutHome(root: root)
    }

    override func tearDown() {
        cancellables.removeAll()
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        home = nil
        super.tearDown()
    }

    private func session(
        id: String, pid: Int32? = nil, title: String? = nil, cwd: String = "/Users/you/x",
        state: SessionState = .working, discovered: Bool = false
    ) -> Session {
        var value = Session()
        value.sessionID = id
        value.pid = pid
        value.title = title
        value.cwd = cwd
        value.project = Session.projectName(for: cwd)
        value.state = state
        value.isDiscovered = discovered
        return value
    }

    // MARK: - The file (SPEC §15.4)

    func testANameSurvivesAReopen() {
        let store = SessionNames(home: home)
        XCTAssertTrue(store.setName("Nova v2 mobil", for: "abc-123"))
        XCTAssertEqual(store.name(for: "abc-123"), "Nova v2 mobil")

        // A brand-new store, same file: this is what a restart looks like.
        let reopened = SessionNames(home: home)
        XCTAssertEqual(reopened.name(for: "abc-123"), "Nova v2 mobil")
        XCTAssertNotNil(reopened.seen["abc-123"])
    }

    func testTheFileHasTheShapeSpecifiedAndIsPrivate() throws {
        let store = SessionNames(home: home)
        store.setName("Longevity", for: "abc-123")

        let data = try Data(contentsOf: home.names)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual((object["names"] as? [String: String])?["abc-123"], "Longevity")
        XCTAssertNotNil((object["seen"] as? [String: String])?["abc-123"])

        let attributes = try FileManager.default.attributesOfItem(atPath: home.names.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    /// SPEC §15.4 spells the file as a flat `{id: name}` map; the app writes the two-key shape
    /// so it can prune. Both have to load, or an upgrade would silently drop every name.
    func testAFlatFileStillLoads() throws {
        try Data(#"{"abc-123":"Nimbus"}"#.utf8).write(to: home.names)
        let store = SessionNames(home: home)
        XCTAssertEqual(store.name(for: "abc-123"), "Nimbus")
        // And it is stamped, so the 30 days start now rather than in 1970.
        XCTAssertNotNil(store.seen["abc-123"])
    }

    func testAnEmptyNameRemovesTheOverride() {
        let store = SessionNames(home: home)
        store.setName("Voyager", for: "abc-123")
        XCTAssertTrue(store.setName("   ", for: "abc-123"))
        XCTAssertNil(store.name(for: "abc-123"))
        XCTAssertNil(store.seen["abc-123"])
        XCTAssertEqual(SessionNames(home: home).name(for: "abc-123"), nil)
    }

    func testWritingIsAtomicAndLeavesNoTemporaryBehind() {
        let store = SessionNames(home: home)
        store.setName("One", for: "a")
        store.setName("Two", for: "a")
        store.setName("Three", for: "b")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: home.names.appendingPathExtension("tmp").path)
        )
        XCTAssertEqual(SessionNames(home: home).names, ["a": "Two", "b": "Three"])
    }

    /// An empty store must not bring the file into existence — the render tests point at the
    /// checked-in fixtures, and nothing may be written there.
    func testAnEmptyStoreNeverCreatesTheFile() {
        let store = SessionNames(home: home)
        store.observe([session(id: "a", pid: 10)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.names.path))
    }

    // MARK: - Pruning (SPEC §15.4)

    func testEntriesGoneFor30DaysArePruned() {
        var names = ["fresh": "Fresh", "stale": "Stale"]
        let now = Date()
        var seen = [
            "fresh": now.addingTimeInterval(-29 * 24 * 60 * 60),
            "stale": now.addingTimeInterval(-31 * 24 * 60 * 60),
        ]
        XCTAssertTrue(SessionNames.prune(names: &names, seen: &seen, now: now))
        XCTAssertEqual(names, ["fresh": "Fresh"])
        XCTAssertEqual(Array(seen.keys), ["fresh"])
    }

    func testAStampWithoutANameIsDroppedToo() {
        var names: [String: String] = [:]
        var seen = ["orphan": Date()]
        XCTAssertTrue(SessionNames.prune(names: &names, seen: &seen, now: Date()))
        XCTAssertTrue(seen.isEmpty)
    }

    func testAStillRunningSessionIsNeverPruned() {
        let store = SessionNames(home: home)
        store.setName("Alive", for: "a", now: Date().addingTimeInterval(-40 * 24 * 60 * 60))
        // Seen right now: the stamp is refreshed before the prune runs.
        store.observe([session(id: "a", pid: 10)])
        XCTAssertEqual(store.name(for: "a"), "Alive")
    }

    func testObserveDropsANameWhoseSessionHasBeenGoneTooLong() {
        let store = SessionNames(home: home)
        store.setName("Gone", for: "a", now: Date().addingTimeInterval(-40 * 24 * 60 * 60))
        store.setName("Here", for: "b")
        store.observe([session(id: "b", pid: 11)])
        XCTAssertNil(store.name(for: "a"))
        XCTAssertEqual(store.name(for: "b"), "Here")
    }

    // MARK: - Observability (SPEC §15.4)

    func testARenamePublishes() {
        let store = SessionNames(home: home)
        var published: [[String: String]] = []
        store.$names.dropFirst().sink { published.append($0) }.store(in: &cancellables)

        store.setName("Duetime", for: "abc-123")
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.last?["abc-123"], "Duetime")

        // Setting the same name again changes nothing, so it must not publish again.
        store.setName("Duetime", for: "abc-123")
        XCTAssertEqual(published.count, 1)
    }

    /// A refresh that changes nothing must not publish — the panel redraws on every one.
    func testAQuietRefreshDoesNotPublish() {
        let store = SessionNames(home: home)
        store.setName("Voyager", for: "a")
        var count = 0
        store.$names.dropFirst().sink { _ in count += 1 }.store(in: &cancellables)
        store.observe([session(id: "a", pid: 10)])
        store.observe([session(id: "a", pid: 10)])
        XCTAssertEqual(count, 0)
    }

    // MARK: - displayName precedence (SPEC §15.3, §15.4)

    func testTheCustomNameBeatsTheComputedOne() {
        let store = SessionNames(home: home)
        store.setName("Nimbus fase 0", for: "a")
        let row = store.decorate(session(id: "a", title: "fix the audit script"))
        XCTAssertEqual(row.displayName, "Nimbus fase 0")
        XCTAssertEqual(row.sessionName, "fix the audit script")
        XCTAssertFalse(row.sessionNameIsPath)
        XCTAssertEqual(row.displayLabel, "Nimbus fase 0")
    }

    func testWithoutACustomNameNothingChanges() {
        let store = SessionNames(home: home)
        let raw = session(id: "a", title: "fix the audit script")
        XCTAssertEqual(store.decorate(raw), raw)
        XCTAssertEqual(raw.displayName, "fix the audit script")
        XCTAssertEqual(raw.displayLabel, raw.project)
    }

    func testADiscoveredRowWithoutATitleFallsBackToItsPath() {
        let raw = session(id: "a", cwd: NSHomeDirectory() + "/Desktop/Lookout", discovered: true)
        XCTAssertEqual(raw.displayName, "~/Desktop/Lookout")
        XCTAssertTrue(raw.sessionNameIsPath)
    }

    func testTheTooltipKeepsTheNameThatWasReplaced() {
        let store = SessionNames(home: home)
        store.setName("Nimbus fase 0", for: "a")
        let row = store.decorate(session(id: "a", title: "fix the audit script"))
        XCTAssertTrue(row.tooltip.contains("Nimbus fase 0"))
        XCTAssertTrue(row.tooltip.contains("Was: fix the audit script"))
    }

    func testLine3NeverRepeatsACustomName() {
        let store = SessionNames(home: home)
        store.setName("Nova", for: "a")
        var raw = session(id: "a", state: .done)
        raw.lastMessage = "Nova"
        XCTAssertNil(store.decorate(raw).rowDetail)
    }

    func testAVeryLongCustomNameIsCutForTheRow() {
        let store = SessionNames(home: home)
        let long = String(repeating: "æ", count: 200)
        store.setName(long, for: "a")
        // Stored capped, shown capped, and never wider than the row's own limit.
        XCTAssertEqual(store.name(for: "a")?.count, SessionNames.nameLimit)
        let shown = store.decorate(session(id: "a")).displayName ?? ""
        XCTAssertLessThanOrEqual(shown.count, Session.sessionNameLimit + 1)
    }

    // MARK: - Carry-over on a pid merge (SPEC §15.4)

    func testANameFollowsTheSessionWhenAHookFileReplacesADiscoveredRow() {
        let store = SessionNames(home: home)

        // 1. A discovered row, renamed by the id the scanner invented.
        let scanned = session(id: "discovered-4242", pid: 4242, discovered: true)
        store.observe([scanned])
        store.setName("Nova v2 mobil", for: scanned.sessionID)
        XCTAssertEqual(store.decorate(scanned).displayName, "Nova v2 mobil")

        // 2. The hooks report the same process under its real session id; SPEC §9.1 drops the
        //    discovered row, so the only thing both rows share is the pid.
        let reported = session(id: "abc-123", pid: 4242)
        XCTAssertEqual(
            Session.merge(files: [reported], discovered: []).map(\.sessionID), ["abc-123"]
        )
        store.observe([reported])

        XCTAssertEqual(store.name(for: "abc-123"), "Nova v2 mobil")
        XCTAssertEqual(store.decorate(reported).displayName, "Nova v2 mobil")
        // Stored under the new id *too*: the old one is still valid until its 30 days run out.
        XCTAssertEqual(store.name(for: "discovered-4242"), "Nova v2 mobil")
    }

    func testCarryOverNeverOverwritesANameTheNewIdAlreadyHas() {
        let pids = ["old": Int32(4242)]
        let names = ["old": "Old", "new": "New"]
        let moves = SessionNames.carryOvers(
            pids: pids, names: names, sessions: [session(id: "new", pid: 4242)]
        )
        XCTAssertTrue(moves.isEmpty)
    }

    func testCarryOverIgnoresADifferentProcess() {
        let moves = SessionNames.carryOvers(
            pids: ["old": 4242], names: ["old": "Old"],
            sessions: [session(id: "new", pid: 9999)]
        )
        XCTAssertTrue(moves.isEmpty)
    }

    func testCarryOverIgnoresARowWithNoPID() {
        let moves = SessionNames.carryOvers(
            pids: ["old": 4242], names: ["old": "Old"], sessions: [session(id: "new")]
        )
        XCTAssertTrue(moves.isEmpty)
    }

    func testAnUnnamedSessionNeverPicksUpSomebodyElsesName() {
        let store = SessionNames(home: home)
        store.observe([session(id: "a", pid: 10), session(id: "b", pid: 11)])
        store.setName("Only A", for: "a")
        store.observe([session(id: "c", pid: 11)])
        XCTAssertNil(store.name(for: "c"))
    }
}
