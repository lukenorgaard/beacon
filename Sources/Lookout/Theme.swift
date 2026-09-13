import AppKit
import SwiftUI

/// Every colour the panel uses. Kept in one place so the panel stays calm: one accent per row,
/// no shadows inside, nothing overlapping anything.
///
/// Sizes do *not* live here any more — they are a value computed from `Appearance`
/// (`Theme.Metrics`, SPEC §14), injected through the environment and read from `Settings` by the
/// AppKit side. Nothing in Lookout hard-codes a point size or a font.
enum Theme {
    // MARK: Surfaces
    /// Cards sit on the panel's translucent HUD ground, so a card drawn only as a tint let the
    /// desktop read straight through it. This is the card's own opaque ground; the tints below
    /// still go on top of it, so a card reads exactly as before, just solid.
    static let cardBase = Color(hex: 0x26282E)
    static let hairline = Color.white.opacity(0.08)
    static let cardFill = Color.white.opacity(0.05)
    static let chipFill = Color.white.opacity(0.12)
    static let hoverFill = Color.white.opacity(0.06)
    static let trackFill = Color.white.opacity(0.10)
    /// An opaque ground for the titled windows (setup), which cannot blend behind themselves.
    static let windowBackground = Color(hex: 0x1B1D21)

    // MARK: Text
    static let textPrimary = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.60)
    static let textTertiary = Color.white.opacity(0.45)

    // MARK: State colours
    static let needsYou = Color(hex: 0xF5A524)
    static let done = Color(hex: 0x34C759)
    static let working = Color(hex: 0x4C8DFF)
    static let idle = Color(hex: 0x8E8E93)
    /// Discovered-but-unreported sessions sit quieter than the ones with hooks.
    static let running = Color(hex: 0x6C7C93)
    /// A manually held session's accent (SPEC: "on hold") — a plain grey, deliberately neither
    /// a state colour nor `idle`'s own, so a held row reads as parked, not as one more idle one.
    static let held = Color.white.opacity(0.38)

    static func color(for state: SessionState) -> Color {
        switch state {
        case .needsYou: return needsYou
        case .done: return done
        case .working: return working
        case .running: return running
        case .idle: return idle
        }
    }

    // MARK: Family colours (SPEC §9.5)

    /// The exact five §9.5 names. Pastel on purpose: they tint a whole row, and the state accent
    /// bar has to keep winning the eye.
    static let familyClaude = Color(hex: 0xF5A97F)
    static let familyCodex = Color(hex: 0x7CC4FA)
    static let familyLocal = Color(hex: 0x2DD4BF)
    static let familyAPI = Color(hex: 0xA78BFA)
    static let familyOther = Color(hex: 0xB4B8C8)

    static func color(for family: SessionFamily) -> Color {
        switch family {
        case .claude: return familyClaude
        case .codex: return familyCodex
        case .local: return familyLocal
        case .api: return familyAPI
        case .other: return familyOther
        }
    }

    /// The row treatment §9.5 specifies: a 1 pt outline at 45 % (25 % for a discovered row) over
    /// a 5 % fill of the same colour, and the model chip at 18 %.
    static let familyStroke: Double = 0.45
    static let familyStrokeDiscovered: Double = 0.25
    static let familyFill: Double = 0.05
    static let familyChipFill: Double = 0.18
    /// SPEC §14: strokes stay 1 pt at every scale. Only the radius they follow grows.
    static let familyStrokeWidth: CGFloat = 1

    // MARK: Usage colours (SPEC §5.3)
    static let usageOK = Color(hex: 0x34C759)
    static let usageWarn = Color(hex: 0xF5A524)
    static let usageCritical = Color(hex: 0xFF453A)

    static func color(for level: UsageLevel) -> Color {
        switch level {
        case .ok: return usageOK
        case .warn: return usageWarn
        case .critical: return usageCritical
        }
    }

    // MARK: Sentinel severity colours (SPEC §18.3, §18.5)

    /// `critical` is deliberately **not** the plain red the needs-you dot uses. The two never
    /// show in the menu bar at once (§18.5: needs-you keeps priority), but a dot that looked
    /// identical would still say "a session needs you" when it means "the machine is in
    /// trouble" — so the machine gets its own hue.
    static let signalCritical = Color(hex: 0xFF375F)
    static let signalWarning = usageWarn
    static let signalInfo = working

    static func color(for severity: SignalSeverity) -> Color {
        switch severity {
        case .info: return signalInfo
        case .warning: return signalWarning
        case .critical: return signalCritical
        }
    }

    /// SPEC §18.5: what `AppState.statusColor` paints the menu-bar dot with while a critical
    /// system signal is active. The AppKit side needs an `NSColor`, and converting on every
    /// status-item redraw would be wasteful.
    static let signalCriticalNSColor = NSColor(signalCritical)

    /// The bar gradient: the state colour into a lighter tint of itself.
    static func gradient(_ base: Color) -> LinearGradient {
        LinearGradient(
            colors: [base, base.opacity(0.55).lighter()],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// A lighter tint for the right-hand end of a bar.
    func lighter() -> Color {
        Color(nsColor: NSColor(self).blended(withFraction: 0.35, of: .white) ?? NSColor(self))
    }
}

/// The panel's translucent ground. A background, never an overlay — nothing is layered on
/// top of a control.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
