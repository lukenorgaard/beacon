import SwiftUI
import XCTest
@testable import Lookout

/// SPEC §14. Four numbers decide every measurement in the app, so these are the numbers.
final class AppearanceTests: XCTestCase {
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

    // MARK: - Defaults and presets

    func testTheShippedAppearanceIsTheDefaultPreset() {
        let appearance = Appearance.standard
        XCTAssertEqual(appearance.scale, 1.0)
        XCTAssertEqual(appearance.panelWidth, 360)
        XCTAssertEqual(appearance.listMaxHeight, 384)
        XCTAssertEqual(appearance.density, .standard)
        XCTAssertEqual(appearance.preset, .standard)
        XCTAssertEqual(Settings(defaults: defaults).appearance, .standard)
    }

    func testEachPresetSetsItsThreeValues() {
        let cases: [(AppearancePreset, CGFloat, CGFloat, PanelDensity)] = [
            (.compact, 0.90, 340, .compact),
            (.standard, 1.00, 360, .standard),
            (.comfortable, 1.10, 400, .comfortable),
            (.large, 1.25, 460, .comfortable),
        ]
        for (preset, scale, width, density) in cases {
            var appearance = Appearance.standard
            appearance.apply(preset)
            XCTAssertEqual(appearance.scale, scale, accuracy: 0.001, preset.rawValue)
            XCTAssertEqual(appearance.panelWidth, width, preset.rawValue)
            XCTAssertEqual(appearance.density, density, preset.rawValue)
            // And it reports itself as the preset it was just set to.
            XCTAssertEqual(appearance.preset, preset)
        }
    }

    /// A preset sets three values; the list height is left alone, so changing it is not what
    /// makes the picker say Custom.
    func testNudgingAnyOfTheThreeValuesMakesThePresetCustom() {
        var appearance = Appearance.standard.applying(.large)
        XCTAssertEqual(appearance.preset, .large)

        appearance.listMaxHeight = 700
        XCTAssertEqual(appearance.preset, .large, "the list height is not part of a preset")

        appearance.panelWidth = 465
        XCTAssertEqual(appearance.preset, .custom)

        appearance.apply(.comfortable)
        XCTAssertEqual(appearance.preset, .comfortable)
        appearance.scale = 1.15
        XCTAssertEqual(appearance.preset, .custom)

        appearance.apply(.compact)
        appearance.density = .comfortable
        XCTAssertEqual(appearance.preset, .custom)

        // Custom is a readout, not a set of values: picking it changes nothing.
        let before = appearance
        appearance.apply(.custom)
        XCTAssertEqual(appearance, before)
    }

    // MARK: - Clamps (SPEC §14)

    func testEveryValueClampsToItsRange() {
        XCTAssertEqual(Appearance(scale: 4).scale, 1.40)
        XCTAssertEqual(Appearance(scale: 0.1).scale, 0.85)
        XCTAssertEqual(Appearance(panelWidth: 40).panelWidth, 320)
        XCTAssertEqual(Appearance(panelWidth: 9_000).panelWidth, 560)
        XCTAssertEqual(Appearance(listMaxHeight: 10).listMaxHeight, 240)
        XCTAssertEqual(Appearance(listMaxHeight: 10_000).listMaxHeight, 800)

        // And on the way in from a setter, not only from the initialiser.
        var appearance = Appearance.standard
        appearance.scale = 99
        appearance.panelWidth = -20
        appearance.listMaxHeight = 0
        XCTAssertEqual(appearance.scale, 1.40)
        XCTAssertEqual(appearance.panelWidth, 320)
        XCTAssertEqual(appearance.listMaxHeight, 240)
    }

    /// The scale is a 0.05 stepper, so a value between two stops snaps to one — which is also
    /// what keeps the preset comparison exact.
    func testTheScaleSnapsToItsStep() {
        XCTAssertEqual(Appearance(scale: 1.07).scale, 1.05, accuracy: 0.0001)
        XCTAssertEqual(Appearance(scale: 1.13).scale, 1.15, accuracy: 0.0001)
        XCTAssertEqual(Appearance(scale: 0.9).scale, 0.90, accuracy: 0.0001)
        XCTAssertEqual(Appearance(scale: .nan).scale, 1.0)
    }

    /// The two drags of SPEC §14: the right edge changes the width, the corner both.
    func testTheResizeDragsClampToo() {
        XCTAssertEqual(Appearance.standard.resized(width: 420).panelWidth, 420)
        XCTAssertEqual(Appearance.standard.resized(width: 9_000).panelWidth, 560)
        XCTAssertEqual(Appearance.standard.resized(width: 10).panelWidth, 320)

        let corner = Appearance.standard.resized(width: 10, listHeight: 10_000)
        XCTAssertEqual(corner.panelWidth, 320)
        XCTAssertEqual(corner.listMaxHeight, 800)
        // The drag never touches the other two values.
        XCTAssertEqual(corner.scale, Appearance.standard.scale)
        XCTAssertEqual(corner.density, Appearance.standard.density)

        let edge = Appearance.standard.resized(width: 500)
        XCTAssertEqual(edge.listMaxHeight, Appearance.standard.listMaxHeight)
    }

    // MARK: - The metrics the four numbers produce

    func testTheRowHeightIsTheDensityTimesTheScale() {
        // SPEC §15.3: three lines — project, session name, state — so 64 / 72 / 80.
        XCTAssertEqual(Theme.Metrics(Appearance(density: .compact)).rowHeight, 64)
        XCTAssertEqual(Theme.Metrics(Appearance(density: .standard)).rowHeight, 72)
        XCTAssertEqual(Theme.Metrics(Appearance(density: .comfortable)).rowHeight, 80)

        XCTAssertEqual(
            Theme.Metrics(Appearance(scale: 1.25, density: .comfortable)).rowHeight, 100
        )
        XCTAssertEqual(
            Theme.Metrics(Appearance(scale: 0.9, density: .compact)).rowHeight, 58,
            "64 × 0.9 = 57.6, on a whole point because the window is sized from it"
        )
        // SPEC §15.3: only session rows grew. An Agents row is still two lines, without an
        // accent bar to clear.
        XCTAssertEqual(PanelDensity.compact.twoLineRowHeight, 44)
        XCTAssertEqual(PanelDensity.standard.twoLineRowHeight, 52)
        XCTAssertEqual(PanelDensity.comfortable.twoLineRowHeight, 60)
        XCTAssertEqual(
            Theme.Metrics(Appearance(density: .standard)).agentRowHeight, 46
        )
        XCTAssertEqual(
            Theme.Metrics(Appearance(scale: 1.25, density: .comfortable)).agentRowHeight, 68
        )
    }

    func testTheCardFollowsThePanelAndNeverGoesUnder380() {
        XCTAssertEqual(Appearance(panelWidth: 320).cardWidth, 380)
        XCTAssertEqual(Appearance(panelWidth: 360).cardWidth, 380)
        XCTAssertEqual(Appearance(panelWidth: 361).cardWidth, 381)
        XCTAssertEqual(Appearance(panelWidth: 460).cardWidth, 480)
        XCTAssertEqual(Appearance(panelWidth: 560).cardWidth, 580)
        XCTAssertEqual(Theme.Metrics(Appearance(panelWidth: 460)).cardWidth, 480)
    }

    func testTheWidthAndTheListCapAreTheUsersOwnNumbers() {
        let metrics = Theme.Metrics(Appearance(scale: 1.4, panelWidth: 500, listMaxHeight: 600))
        XCTAssertEqual(metrics.width, 500, "a chosen width is a width, not a scaled one")
        XCTAssertEqual(metrics.listMaxHeight, 600)
    }

    /// SPEC §14: strokes stay 1 pt, hit targets never go under 24 pt or under 24 × scale, and
    /// the radii scale.
    func testStrokesStayHitTargetsGrowAndRadiiScale() {
        for scale in stride(from: 0.85, through: 1.40, by: 0.05) {
            let metrics = Theme.Metrics(Appearance(scale: CGFloat(scale)))
            XCTAssertEqual(metrics.stroke, 1, "a hairline is a hairline at every scale")
            XCTAssertEqual(Theme.familyStrokeWidth, 1)
            XCTAssertGreaterThanOrEqual(metrics.hitTarget, 24)
            XCTAssertGreaterThanOrEqual(metrics.hitTarget, 24 * CGFloat(scale) - 0.5)
            // Every clickable thing, not only the icon buttons.
            XCTAssertGreaterThanOrEqual(metrics.buttonHeight, 24)
            XCTAssertGreaterThanOrEqual(metrics.buttonHeight, 24 * CGFloat(scale) - 0.5)
            XCTAssertGreaterThanOrEqual(metrics.tabHeight, 24)
            XCTAssertGreaterThanOrEqual(metrics.tabHeight, 24 * CGFloat(scale) - 0.5)
            XCTAssertGreaterThanOrEqual(metrics.controlGap, 8)
            // The list's inset can never be narrower than the drag zone that sits in it, or the
            // right edge grip would take a click meant for a row.
            XCTAssertGreaterThanOrEqual(metrics.listInset, metrics.resizeEdge)
            // The corner square fits exactly in the air under the content, for the same reason.
            XCTAssertLessThanOrEqual(metrics.resizeCorner, metrics.bottomPadding)
        }

        XCTAssertEqual(Theme.Metrics(Appearance(scale: 1.25)).corner, 17.5)
        XCTAssertEqual(Theme.Metrics(Appearance(scale: 1.25)).rowCorner, 12.5)
        XCTAssertEqual(Theme.Metrics.standard.corner, 14)
        XCTAssertEqual(Theme.Metrics.standard.rowCorner, 10)
    }

    /// Everything the panel's own height is computed from scales with it (SPEC §14), and the cap
    /// is still a cap.
    func testThePanelHeightMathScalesAndStillCaps() {
        let big = Theme.Metrics(Appearance(scale: 1.25, panelWidth: 460, density: .comfortable))
        XCTAssertEqual(big.listHeight(rows: 1), big.rowHeight)
        XCTAssertEqual(big.listHeight(rows: 3), 3 * big.rowHeight + 2 * big.rowGap)
        XCTAssertEqual(big.listHeight(rows: 400), big.listMaxHeight)
        XCTAssertEqual(big.listHeight(rows: 0), big.emptyHeight)
        XCTAssertTrue(big.listOverflows(rows: 400))
        XCTAssertFalse(big.listOverflows(rows: 1))

        XCTAssertGreaterThan(big.headerHeight, Theme.Metrics.standard.headerHeight)
        XCTAssertGreaterThan(big.tabsHeight, Theme.Metrics.standard.tabsHeight)
        XCTAssertGreaterThan(big.usageCardHeight, Theme.Metrics.standard.usageCardHeight)
        XCTAssertGreaterThan(big.barHeight, Theme.Metrics.standard.barHeight)
        XCTAssertGreaterThan(big.setupWidth, Theme.Metrics.standard.setupWidth)

        let total = big.totalHeight(tab: .sessions, rows: 500, cards: 0, extraLine: false)
        XCTAssertEqual(
            total, big.headerHeight + big.tabsHeight + big.listMaxHeight + big.bottomPadding
        )
        // A list cap the user chose is what bounds the window, at every scale.
        let tall = Theme.Metrics(Appearance(scale: 1.4, listMaxHeight: 800))
        XCTAssertEqual(tall.listHeight(rows: 500), 800)
    }

    // MARK: - Persistence (SPEC §14 / §5.5)

    func testTheAppearancePersistsAndAnOutOfRangeStoredValueIsClamped() {
        let settings = Settings(defaults: defaults)
        settings.apply(preset: .large)
        settings.appearance.listMaxHeight = 640

        let reopened = Settings(defaults: defaults)
        XCTAssertEqual(reopened.appearance.scale, 1.25, accuracy: 0.001)
        XCTAssertEqual(reopened.appearance.panelWidth, 460)
        XCTAssertEqual(reopened.appearance.listMaxHeight, 640)
        XCTAssertEqual(reopened.appearance.density, .comfortable)
        XCTAssertEqual(reopened.appearance.preset, .large)
        XCTAssertEqual(reopened.metrics.rowHeight, 100)

        // A defaults entry from somewhere else cannot put the panel outside its ranges.
        defaults.set(9.0, forKey: "appearanceScale")
        defaults.set(2_000.0, forKey: "appearancePanelWidth")
        defaults.set("nonsense", forKey: "appearanceDensity")
        let hostile = Settings(defaults: defaults)
        XCTAssertEqual(hostile.appearance.scale, 1.40)
        XCTAssertEqual(hostile.appearance.panelWidth, 560)
        XCTAssertEqual(hostile.appearance.density, .standard)

        hostile.resetAppearance()
        XCTAssertEqual(hostile.appearance, .standard)
        XCTAssertEqual(Settings(defaults: defaults).appearance, .standard)
    }

    /// SPEC §14: a drag changes the width live and writes it once, on mouse-up.
    func testADragIsLiveButOnlyPersistsOnMouseUp() {
        let settings = Settings(defaults: defaults)
        settings.beginAppearanceDrag()
        for width in stride(from: CGFloat(361), through: 500, by: 20) {
            settings.appearance = settings.appearance.resized(width: width)
        }
        XCTAssertEqual(settings.appearance.panelWidth, 481, "live while the pointer moves")
        XCTAssertEqual(
            Settings(defaults: defaults).appearance.panelWidth, 360,
            "nothing written yet — a drag must not be sixty defaults writes a second"
        )

        settings.endAppearanceDrag()
        XCTAssertEqual(Settings(defaults: defaults).appearance.panelWidth, 481)

        // And after the drag, an ordinary change persists again.
        settings.appearance.panelWidth = 420
        XCTAssertEqual(Settings(defaults: defaults).appearance.panelWidth, 420)
    }
}
