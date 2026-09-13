import AppKit
import XCTest
@testable import Lookout

/// SPEC §17.4: the presets list, its persistence and its ⌘-key rule, plus the card filling its
/// field from one — never sending.
final class AnswerPresetsTests: XCTestCase {
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

    // MARK: - Defaults and persistence

    func testDefaultsMatchTheSpec() {
        let settings = Settings(defaults: defaults)
        XCTAssertEqual(settings.answerPresets.map(\.text), [
            "Go ahead",
            "Skip it, continue with the next task",
            "Commit what you have and stop",
            "Ask me again in the terminal",
        ])
        XCTAssertEqual(settings.answerPresets.map(\.keyBinding), [1, 2, 3, 4])
    }

    func testPresetsPersistAcrossInstances() {
        let settings = Settings(defaults: defaults)
        settings.answerPresets = [AnswerPreset(text: "Go ahead", keyBinding: 1)]
        XCTAssertEqual(Settings(defaults: defaults).answerPresets.map(\.text), ["Go ahead"])
    }

    func testAddRemoveAndReorderRoundTrip() {
        let settings = Settings(defaults: defaults)
        var presets = settings.answerPresets
        presets.append(AnswerPreset(text: "New one"))
        settings.answerPresets = presets
        XCTAssertEqual(settings.answerPresets.count, 5)

        settings.answerPresets.removeAll { $0.text == "Ask me again in the terminal" }
        XCTAssertEqual(settings.answerPresets.count, 4)

        settings.answerPresets.swapAt(0, 1)
        XCTAssertEqual(settings.answerPresets[0].text, "Skip it, continue with the next task")

        let reopened = Settings(defaults: defaults)
        XCTAssertEqual(reopened.answerPresets.map(\.text), settings.answerPresets.map(\.text))
    }

    /// An empty or corrupt defaults entry falls back to the SPEC §17.4 defaults rather than an
    /// empty list — the card would otherwise show no presets at all after a bad upgrade.
    func testACorruptStoredValueFallsBackToTheDefaults() {
        defaults.set(Data("not json".utf8), forKey: "answerPresets")
        XCTAssertEqual(Settings(defaults: defaults).answerPresets.count, 4)
    }

    // MARK: - The ⌘-key rule (SPEC §17.4)

    func testAssigningAKeyTakesItAwayFromWhoeverHadIt() {
        let a = AnswerPreset(text: "A", keyBinding: 1)
        let b = AnswerPreset(text: "B", keyBinding: nil)
        let reassigned = AnswerPresets.assign([a, b], id: b.id, keyBinding: 1)

        XCTAssertNil(reassigned.first { $0.id == a.id }?.keyBinding, "A lost the key")
        XCTAssertEqual(reassigned.first { $0.id == b.id }?.keyBinding, 1, "B has it now")
    }

    func testClearingAKeyLeavesEveryoneElseAlone() {
        let a = AnswerPreset(text: "A", keyBinding: 1)
        let b = AnswerPreset(text: "B", keyBinding: 2)
        let cleared = AnswerPresets.assign([a, b], id: a.id, keyBinding: nil)
        XCTAssertNil(cleared.first { $0.id == a.id }?.keyBinding)
        XCTAssertEqual(cleared.first { $0.id == b.id }?.keyBinding, 2)
    }

    func testPresetForKeyFindsTheOneBoundToIt() {
        let presets = [
            AnswerPreset(text: "A", keyBinding: 1),
            AnswerPreset(text: "B", keyBinding: 2),
        ]
        XCTAssertEqual(AnswerPresets.preset(for: 2, in: presets)?.text, "B")
        XCTAssertNil(AnswerPresets.preset(for: 9, in: presets))
    }

    // MARK: - The card fills its field, never sends (SPEC §17.4)

    private func session() -> Session {
        var value = Session()
        value.sessionID = "s1"
        value.state = .needsYou
        value.agent = .claude
        value.project = "daily-notes"
        value.host = .cursor
        value.pid = 1
        value.stateSince = Date()
        return value
    }

    func testUsingAPresetFillsTheFieldAndNeverSends() {
        let defaultsForModel = UserDefaults(suiteName: "io.github.lukenorgaard.beacon.tests.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaultsForModel)
        let coordinator = AttentionCoordinator(settings: settings)
        let home = LookoutHome(
            root: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("lookout-presets-\(UUID().uuidString)")
        )
        let model = AttentionCardModel(
            settings: settings, coordinator: coordinator, suggester: Suggester(), home: home
        )
        model.jumper = { _ in }
        coordinator.present(session())
        model.present(coordinator.current, request: nil)

        let preset = AnswerPreset(text: "Go ahead", keyBinding: 1)
        model.use(preset: preset)

        XCTAssertEqual(model.text, "Go ahead")
        XCTAssertNil(model.status, "filling the field from a preset is not an action")
        XCTAssertEqual(coordinator.current?.id, "s1", "nothing was sent, nothing was dismissed")
        defaultsForModel.removePersistentDomain(forName: "io.github.lukenorgaard.beacon.tests")
    }
}
