import AppKit
import SwiftUI
import XCTest
@testable import Lookout

extension AttentionCardTests {
    // MARK: - Layout

    func layout<V: View>(_ view: V) -> NSSize {
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize
    }

    func testTheCardLaysOutAtItsFixedWidthAndInsideItsHeightCap() throws {
        let (model, coordinator) = makeModel()
        coordinator.present(session())
        model.present(coordinator.current, request: try request())

        let size = layout(AttentionCardView(model: model))
        XCTAssertEqual(size.width, metrics.cardWidth, accuracy: 0.5)
        XCTAssertLessThanOrEqual(size.height, metrics.cardMaxHeight)
        XCTAssertGreaterThan(size.height, 200)

        // A question with three options, and a done card, both fit too.
        model.present(coordinator.current, request: try request(kind: "question"))
        XCTAssertLessThanOrEqual(
            layout(AttentionCardView(model: model)).height, metrics.cardMaxHeight
        )

        coordinator.closeAll()
        settings.cardOnDone = true
        var finished = session(id: "d", state: .done)
        finished.lastMessage = "All green — 42 tests pass."
        coordinator.present(finished)
        model.present(coordinator.current, request: nil)
        XCTAssertLessThanOrEqual(
            layout(AttentionCardView(model: model)).height, metrics.cardMaxHeight
        )
    }

    /// SPEC §13.2: the source chip sits on its own row beside `SUGGESTION`, so the card must
    /// still fit its fixed width and its height cap, and the two labels must fit that row side
    /// by side with the 8 pt gap between them.
    func testTheClaudeSourceLabelFitsItsOwnRowAndTheCardStillFits() throws {
        // A stubbed runner: this suite must never spawn the real `claude`.
        let claude = ClaudeCLISuggester(home: home)
        claude.runner = { _, _, _, _, _ in
            Shell.Result(stdout: "Allow — it only reads.\n", exitCode: 0, timedOut: false)
        }
        let coordinator = AttentionCoordinator(settings: settings)
        let model = AttentionCardModel(
            settings: settings, coordinator: coordinator,
            suggester: Suggester(claude: claude), home: home
        )
        model.jumper = { _ in }
        settings.suggestionSource = .claude
        settings.claudeModel = "haiku"
        XCTAssertEqual(model.suggestionSourceLabel, "Claude · haiku")

        coordinator.present(session())
        model.present(coordinator.current, request: try request())

        let size = layout(AttentionCardView(model: model))
        XCTAssertEqual(size.width, metrics.cardWidth, accuracy: 0.5)
        XCTAssertLessThanOrEqual(size.height, metrics.cardMaxHeight)

        // The label row: section label + gap + chip, inside the card's content width.
        let sectionLabel = layout(CardSectionLabel(text: "Suggestion"))
        let chip = layout(Text("Claude · haiku").font(metrics.chip))
        XCTAssertLessThanOrEqual(
            sectionLabel.width + metrics.controlGap + chip.width,
            metrics.cardWidth - 2 * metrics.padding,
            "the source chip must not crowd the section label"
        )
        XCTAssertEqual(chip.height, sectionLabel.height, accuracy: 4, "one rhythm on the row")

        // Other sources: heuristic says nothing, Ollama names its model.
        settings.suggestionSource = .heuristic
        XCTAssertNil(model.suggestionSourceLabel)
        settings.suggestionSource = .ollama
        settings.ollamaModel = "qwen3.5:4b"
        XCTAssertEqual(model.suggestionSourceLabel, "Ollama · qwen3.5:4b")
    }

    /// SPEC §13.2: a Claude that cannot answer hands the card the heuristic and one line saying
    /// why — without ever overwriting what an action put on the status line.
    func testTheFallbackNoteReachesTheStatusLineButNeverOverwritesAnAction() {
        let claude = ClaudeCLISuggester(home: home)
        claude.runner = { _, _, _, _, _ in
            Shell.Result(stdout: "", exitCode: 1, timedOut: false)
        }
        let coordinator = AttentionCoordinator(settings: settings)
        let model = AttentionCardModel(
            settings: settings, coordinator: coordinator,
            suggester: Suggester(claude: claude), home: home
        )
        model.jumper = { _ in }
        settings.suggestionSource = .claude
        coordinator.present(session())
        model.present(coordinator.current, request: nil)

        let deadline = Date().addingTimeInterval(10)
        while model.isSuggesting, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(model.isSuggesting)
        XCTAssertEqual(model.suggestionNote, "Claude unavailable → heuristic")
        XCTAssertEqual(model.statusLine, "Claude unavailable → heuristic")
        XCTAssertTrue(model.statusLineIsError)
        XCTAssertEqual(model.suggestion, "Allow — runs `rm -rf build`")

        // An action's own status wins the line back.
        model.text = "go ahead"
        model.copyAndGo()
        XCTAssertEqual(model.statusLine, "Copied and opened Cursor")
        XCTAssertFalse(model.statusLineIsError)
    }

    func testEveryButtonKeepsTheEightPointGapAndItsOwnRoom() {
        let row = layout(
            HStack(spacing: metrics.controlGap) {
                CardButton(title: "Send", tone: .primary, action: {})
                CardButton(title: "Copy & go", tone: .secondary, action: {})
                CardButton(title: "Ignore", tone: .quiet, action: {})
            }
        )
        XCTAssertLessThanOrEqual(
            row.width, metrics.cardWidth - 2 * metrics.padding,
            "the three buttons must fit the card without squeezing"
        )
        XCTAssertEqual(row.height, 26, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(metrics.controlGap, 8)

        let answerRow = layout(
            HStack(spacing: metrics.controlGap) {
                CardButton(title: "Allow", tone: .primary, action: {})
                CardButton(title: "Deny", tone: .danger, action: {})
            }
        )
        XCTAssertLessThanOrEqual(answerRow.width, metrics.cardWidth - 2 * metrics.padding)
    }

    /// SPEC §11.4: the command box shows at most six lines and scrolls past that, so a 200-line
    /// command cannot grow the card.
    func testTheCommandBoxIsCappedAtSixLines() {
        let short = layout(CommandBox(text: "npm test").frame(width: 340))
        let long = layout(
            CommandBox(text: (0..<200).map { "line \($0)" }.joined(separator: "\n"))
                .frame(width: 340)
        )
        XCTAssertLessThanOrEqual(
            long.height,
            metrics.commandLineHeight
                * CGFloat(metrics.commandMaxLines) + 16
        )
        XCTAssertLessThanOrEqual(short.height, long.height)
    }
}
