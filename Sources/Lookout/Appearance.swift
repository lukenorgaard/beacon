import CoreGraphics
import Foundation

/// SPEC §14: how tall a row is before the scale factor. Three steps, so "make it roomier" is one
/// click and not a stepper hunt.
enum PanelDensity: String, CaseIterable, Equatable {
    case compact
    case standard = "default"
    case comfortable

    var label: String {
        switch self {
        case .compact: return "Compact"
        case .standard: return "Default"
        case .comfortable: return "Comfortable"
        }
    }

    /// A session row's height at scale 1. Three lines since SPEC §15.3 — project, session name,
    /// state — so 64 / 72 / 80 where two lines needed 44 / 52 / 60.
    var rowHeight: CGFloat {
        switch self {
        case .compact: return 64
        case .standard: return 72
        case .comfortable: return 80
        }
    }

    /// The two-line height the Agents tab keeps (SPEC §15.3: only session rows grew).
    var twoLineRowHeight: CGFloat {
        switch self {
        case .compact: return 44
        case .standard: return 52
        case .comfortable: return 60
        }
    }
}

/// The four presets of SPEC §14 plus the one the panel *reports* when the values match none of
/// them. A preset sets three values — scale, width, density; the list height is left alone,
/// because how much of the screen the list may take is a screen question, not a text-size one.
enum AppearancePreset: String, CaseIterable, Equatable {
    case compact
    case standard = "default"
    case comfortable
    case large
    case custom

    var label: String {
        switch self {
        case .compact: return "Compact"
        case .standard: return "Default"
        case .comfortable: return "Comfortable"
        case .large: return "Large"
        case .custom: return "Custom"
        }
    }

    var values: (scale: CGFloat, panelWidth: CGFloat, density: PanelDensity)? {
        switch self {
        case .compact: return (0.90, 340, .compact)
        case .standard: return (1.00, 360, .standard)
        case .comfortable: return (1.10, 400, .comfortable)
        case .large: return (1.25, 460, .comfortable)
        case .custom: return nil
        }
    }
}

/// SPEC §14. Four numbers decide every measurement in the app; `Theme.Metrics` turns them into
/// fonts and points, and nothing else is allowed to hard-code a size.
struct Appearance: Equatable {
    static let scaleRange: ClosedRange<CGFloat> = 0.85...1.40
    static let scaleStep: CGFloat = 0.05
    static let widthRange: ClosedRange<CGFloat> = 320...560
    static let widthStep: CGFloat = 10
    static let listHeightRange: ClosedRange<CGFloat> = 240...800
    static let listHeightStep: CGFloat = 16
    /// The card never gets narrower than the 380 pt SPEC §11.4 drew it at.
    static let minimumCardWidth: CGFloat = 380

    /// Every setter clamps, so no drag, no stepper and no stale defaults entry can put a value
    /// outside its range — the clamp lives with the value, not at each call site.
    var scale: CGFloat {
        didSet { scale = Appearance.clamp(scale: scale) }
    }

    var panelWidth: CGFloat {
        didSet { panelWidth = Appearance.clamp(width: panelWidth) }
    }

    var listMaxHeight: CGFloat {
        didSet { listMaxHeight = Appearance.clamp(listHeight: listMaxHeight) }
    }

    var density: PanelDensity

    init(
        scale: CGFloat = 1,
        panelWidth: CGFloat = 360,
        listMaxHeight: CGFloat = 384,
        density: PanelDensity = .standard
    ) {
        self.scale = Appearance.clamp(scale: scale)
        self.panelWidth = Appearance.clamp(width: panelWidth)
        self.listMaxHeight = Appearance.clamp(listHeight: listMaxHeight)
        self.density = density
    }

    /// What the app ships with (SPEC §14's **Default** preset).
    static let standard = Appearance()

    /// SPEC §14: the card follows the panel and never goes under 380 pt.
    var cardWidth: CGFloat { max(Appearance.minimumCardWidth, panelWidth + 20) }

    /// The preset these values *are*, or `.custom` once one of them has been nudged.
    var preset: AppearancePreset {
        for preset in AppearancePreset.allCases {
            guard let values = preset.values else { continue }
            if abs(scale - values.scale) < 0.001,
               abs(panelWidth - values.panelWidth) < 0.5,
               density == values.density {
                return preset
            }
        }
        return .custom
    }

    /// Applying `.custom` is a no-op on purpose: Custom is a readout, not a set of values.
    mutating func apply(_ preset: AppearancePreset) {
        guard let values = preset.values else { return }
        scale = values.scale
        panelWidth = values.panelWidth
        density = values.density
    }

    func applying(_ preset: AppearancePreset) -> Appearance {
        var copy = self
        copy.apply(preset)
        return copy
    }

    /// The right-edge drag (SPEC §14).
    func resized(width: CGFloat) -> Appearance {
        var copy = self
        copy.panelWidth = width
        return copy
    }

    /// The bottom-right corner drag: both at once.
    func resized(width: CGFloat, listHeight: CGFloat) -> Appearance {
        var copy = self
        copy.panelWidth = width
        copy.listMaxHeight = listHeight
        return copy
    }

    // MARK: - Clamps

    /// Snapped to the 0.05 step first, so the preset comparison above stays exact and a dragged
    /// or hand-edited defaults value cannot land between two stops.
    static func clamp(scale value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 1 }
        let stepped = ((value / scaleStep).rounded() * scaleStep * 100).rounded() / 100
        return min(max(stepped, scaleRange.lowerBound), scaleRange.upperBound)
    }

    static func clamp(width value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 360 }
        return min(max(value.rounded(), widthRange.lowerBound), widthRange.upperBound)
    }

    static func clamp(listHeight value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 384 }
        return min(max(value.rounded(), listHeightRange.lowerBound), listHeightRange.upperBound)
    }
}
