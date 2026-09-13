import AppKit
import SwiftUI
import XCTest
@testable import Lookout

extension PanelRenderTests {
    func testPinnedSessionsStayAboveGroupsAtSmallAndLargeSizes() {
        func session(_ id: String, agent: SessionAgent, project: String) -> Session {
            var row = Session()
            row.sessionID = id
            row.agent = agent
            row.project = project
            row.cwd = "/fictional/\(project)"
            row.title = "Improve the checkout flow"
            row.model = agent == .codex ? "gpt-6-astra" : "claude-sonnet-4-6"
            row.state = .working
            return row
        }
        let sessions = [
            session("claude-pin", agent: .claude, project: "Voyager"),
            session("codex-pin", agent: .codex, project: "Docs"),
            session("claude-rest", agent: .claude, project: "Voyager"),
            session("codex-rest", agent: .codex, project: "Docs"),
        ]
        settings.sessionOrder = .pinned
        settings.pinnedSessions = ["claude-pin", "codex-pin"]
        state.apply(sessions)
        for appearance in [
            Appearance(scale: 0.85, panelWidth: 320, listMaxHeight: 480, density: .compact),
            Appearance(scale: 1.25, panelWidth: 460, listMaxHeight: 600, density: .comfortable),
        ] {
            settings.appearance = appearance
            let sections = state.sessionSections
            XCTAssertEqual(sections.headerCount, 4)
            let drawn = sections.items.compactMap { item -> String? in
                if case .row(let session) = item { return session.id }
                return nil
            }
            XCTAssertEqual(Array(drawn.prefix(2)), ["claude-pin", "codex-pin"])
            let size = render(
                PanelView(state: state, settings: settings, onTogglePin: {}, onOpenSettings: {}),
                named: "pinned-sessions-\(Int(appearance.panelWidth))"
            )
            XCTAssertEqual(size.width, settings.metrics.width, accuracy: 0.5)
            XCTAssertGreaterThan(size.height, settings.metrics.listHeight(
                rows: sections.rowCount, headers: sections.headerCount
            ))
        }
    }
}
