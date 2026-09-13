import XCTest
@testable import Lookout

/// Codex sessions sit under their own header in the Sessions list; everything else keeps its
/// place above them. Within each part, sessions of one project cluster together, and the panel's
/// height accounts for every header it draws.
final class SessionSectionsTests: XCTestCase {

    private func session(_ id: String, _ agent: SessionAgent, cwd: String = "") -> Session {
        var session = Session()
        session.sessionID = id
        session.agent = agent
        session.cwd = cwd
        session.project = cwd.isEmpty ? "" : URL(fileURLWithPath: cwd).lastPathComponent
        return session
    }

    private func rows(_ items: [SessionSections.Item]) -> [String] {
        items.compactMap { if case .row(let session) = $0 { return session.sessionID } else { return nil } }
    }

    private func headers(_ items: [SessionSections.Item]) -> [String] {
        items.compactMap {
            switch $0 {
            case .section(let title, let count): return "\(title) \(count)"
            case .project(let name, let count, let codex): return "\(codex ? "codex:" : "")\(name) \(count)"
            case .row: return nil
            }
        }
    }

    func testCodexSessionsSplitOffAndBothPartsKeepTheirOrder() {
        let sections = SessionSections([
            session("c1", .claude), session("x1", .codex), session("g1", SessionAgent(raw: "gemini")),
            session("x2", .codex), session("c2", .claude),
        ])
        XCTAssertEqual(sections.others.map(\.sessionID), ["c1", "g1", "c2"])
        XCTAssertEqual(sections.codex.map(\.sessionID), ["x1", "x2"])
        XCTAssertEqual(sections.rowCount, 5)
        // No cwd at all: every row lands in "Other", one bucket per part, plus the divider.
        XCTAssertEqual(headers(sections.items), ["Other 3", "CODEX 2", "codex:Other 2"])
        XCTAssertEqual(rows(sections.items), ["c1", "g1", "c2", "x1", "x2"])
    }

    /// Every cluster carries a header, single-session ones included — a lone row under the
    /// cluster above is exactly what read as "part of that cluster" before.
    func testEveryClusterCarriesAHeaderEvenWithOneSession() {
        let sections = SessionSections([
            session("a", .claude, cwd: "/p/voyager"), session("b", .claude, cwd: "/p/voyager"),
            session("c", .claude, cwd: "/p/docs-site"),
        ])
        XCTAssertEqual(headers(sections.items), ["voyager 2", "docs-site 1"])
        XCTAssertEqual(rows(sections.items), ["a", "b", "c"])
    }

    /// Whatever cannot be placed goes in one bucket, and the bucket is always last.
    func testUnidentifiableRowsShareOneOtherBucketDrawnLast() {
        let sections = SessionSections([
            session("u1", .claude), session("p1", .claude, cwd: "/p/billing-api"), session("u2", .claude),
        ])
        XCTAssertEqual(headers(sections.items), ["billing-api 1", "Other 2"])
        XCTAssertEqual(rows(sections.items), ["p1", "u1", "u2"])
    }

    /// Three voyager sessions, two of them in worktrees whose folder names
    /// are the row titles, interleaved with other projects by the chosen sort order.
    func testWorktreesClusterUnderTheirRepositoryWhereTheFirstOneStood() {
        let repo = "/Users/you/Desktop/voyager"
        let sections = SessionSections([
            session("w1", .claude, cwd: "\(repo)/.worktrees/fix-export"),
            session("lk", .claude, cwd: "/Users/you/Desktop/billing-api"),
            session("root", .claude, cwd: repo),
            session("w2", .claude, cwd: "\(repo)/.claude/worktrees/new-onboarding"),
            session("fb", .claude, cwd: "/Users/you/Desktop/docs-site"),
        ])
        XCTAssertEqual(headers(sections.items), ["voyager 3", "billing-api 1", "docs-site 1"])
        XCTAssertEqual(rows(sections.items), ["w1", "root", "w2", "lk", "fb"],
                       "the cluster sits where its first session stood; rows keep their order")
        XCTAssertEqual(sections.headerCount, 3)
    }

    func testTheCodexPartClustersToo() {
        let sections = SessionSections([
            session("c1", .claude, cwd: "/p/billing-api"),
            session("x1", .codex, cwd: "/p/voyager"),
            session("x2", .codex, cwd: "/p/other"),
            session("x3", .codex, cwd: "/p/voyager"),
        ])
        XCTAssertEqual(headers(sections.items), ["billing-api 1", "CODEX 3", "codex:voyager 2", "codex:other 1"])
        XCTAssertEqual(rows(sections.items), ["c1", "x1", "x3", "x2"])
        XCTAssertEqual(sections.headerCount, 4)
    }

    func testClusterKeys() {
        XCTAssertEqual(SessionSections.clusterKey(session("a", .claude, cwd: "/x/voyager/.worktrees/fix-export")), "voyager")
        XCTAssertEqual(SessionSections.clusterKey(session("a", .claude, cwd: "/x/voyager/.claude/worktrees/w")), "voyager")
        XCTAssertEqual(SessionSections.clusterKey(session("a", .claude, cwd: "/x/billing-api")), "billing-api")
        XCTAssertEqual(SessionSections.clusterKey(session("a", .claude)), SessionSections.otherKey)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(SessionSections.clusterKey(session("h", .claude, cwd: home)), SessionSections.otherKey,
                       "a session sitting in the home folder is not a project")
        XCTAssertEqual(SessionSections.clusterKey(session("b", .claude)), SessionSections.otherKey,
                       "two unplaceable rows share the one bucket")
    }

    func testEveryHeaderIsCountedInTheListHeight() {
        let metrics = Theme.Metrics.standard
        XCTAssertEqual(metrics.listHeight(rows: 3, headers: 0), metrics.listHeight(rows: 3),
                       "no header must mean the upstream height, to the point")
        XCTAssertEqual(
            metrics.listHeight(rows: 3, headers: 2),
            metrics.listHeight(rows: 3) + 2 * (metrics.sectionHeaderHeight + metrics.rowGap),
            accuracy: 0.01
        )
        XCTAssertEqual(metrics.listHeight(rows: 0, headers: 1), metrics.emptyHeight)
        XCTAssertLessThanOrEqual(metrics.listHeight(rows: 400, headers: 9), metrics.listMaxHeight)
    }

    func testPinnedFirstKeepsAllPinsAheadOfProjectGroupsAcrossAgents() {
        let sessions = [
            session("a-pin", .claude, cwd: "/p/alpha"),
            session("b-pin", .claude, cwd: "/p/beta"),
            session("x-pin", .codex, cwd: "/p/alpha"),
            session("a-rest", .claude, cwd: "/p/alpha"),
            session("x-rest", .codex, cwd: "/p/alpha"),
        ]
        let sections = SessionSections(sessions, pinned: ["a-pin", "b-pin", "x-pin"], order: .pinned)
        XCTAssertEqual(rows(sections.items), ["a-pin", "b-pin", "x-pin", "a-rest", "x-rest"])
        XCTAssertEqual(headers(sections.items), ["PINNED 3", "alpha 1", "CODEX 1", "codex:alpha 1"])
        XCTAssertEqual(sections.rowCount, sessions.count)
        XCTAssertEqual(Set(sections.items.map(\.id)).count, sections.items.count)
    }

    func testOtherSortModesKeepTheirExistingGroupsEvenWhenPinsExist() {
        let sessions = [session("a", .claude, cwd: "/p/alpha"), session("b", .codex, cwd: "/p/beta")]
        for order in [SessionOrder.state, .activity, .project] {
            XCTAssertEqual(SessionSections(sessions, pinned: ["b"], order: order), SessionSections(sessions))
        }
    }

    func testAllPinnedAndNoPinnedListsHaveTheCorrectHeaderCounts() {
        let sessions = [session("a", .claude), session("b", .codex)]
        let all = SessionSections(sessions, pinned: ["a", "b"], order: .pinned)
        XCTAssertEqual(headers(all.items), ["PINNED 2"])
        XCTAssertEqual(all.headerCount, 1)
        XCTAssertEqual(rows(all.items), ["a", "b"])
        XCTAssertEqual(SessionSections(sessions, pinned: [], order: .pinned), SessionSections(sessions))
        XCTAssertTrue(SessionSections([], pinned: ["a"], order: .pinned).items.isEmpty)
    }
}
