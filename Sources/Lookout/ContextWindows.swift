import Foundation

/// SPEC §19.3: how many tokens fit in one model family's context, editable in Settings → Usage
/// under the pricing table. Matched on the record's `model` exactly the way `PricingTable`
/// matches prices — through `Session.modelDisplayName`, so `claude-fable-5-1` and
/// `anthropic/claude-sonnet-5[1m]` both land on a key here without the table ever seeing the raw
/// string.
///
/// The numbers are best knowledge, not documentation — they are editable because they will be
/// wrong one day, and a wrong window is a wrong percentage on every row.
struct ContextWindows: Codable, Equatable {
    var windows: [String: Int]

    /// The key every Claude model that is not one of the four named families falls back to.
    static let otherKey = "other"
    /// SPEC §19.3: Codex's own fallback, used only when the record carries no `context_window`.
    static let codexKey = "codex"

    /// The fixed row order the Settings UI and the tests both use.
    static let orderedModelKeys = ["fable", "opus", "sonnet", "haiku", otherKey, codexKey]

    /// SPEC §19.3's defaults.
    static let standard = ContextWindows(windows: [
        "fable": 1_000_000,
        "opus": 1_000_000,
        "sonnet": 1_000_000,
        "haiku": 200_000,
        otherKey: 200_000,
        codexKey: 258_400,
    ])

    /// What Settings shows in the leftmost column: the key itself, except the two that are not
    /// model names.
    static func label(for key: String) -> String {
        switch key {
        case otherKey: return "Other Claude"
        case codexKey: return "Codex"
        default: return key.capitalized
        }
    }

    /// The table key a raw model string resolves against — `PricingTable`'s own rule, so the two
    /// tables can never disagree about what `claude-opus-5` is called.
    static func family(for model: String) -> String { PricingTable.family(for: model) }

    /// The last-resort window: the edited "other Claude" row, or its default if that row was
    /// somehow deleted from the stored table.
    var fallback: Int {
        windows[ContextWindows.otherKey]
            ?? ContextWindows.standard.windows[ContextWindows.otherKey]
            ?? 200_000
    }

    /// SPEC §19.3's resolution order: the record's own window (Codex reports one) beats the
    /// table; then the model's family row; then Codex's fallback row for a Codex session whose
    /// model name is not in the table (`gpt-5.6-sol` never is); then "other Claude".
    func window(for session: Session) -> Int {
        if let reported = session.contextWindow, reported > 0 { return reported }
        return window(model: session.model, isCodex: session.family == .codex)
    }

    /// The table half of `window(for:)`, without a `Session` — what Settings and the tests
    /// exercise directly.
    func window(model: String?, isCodex: Bool = false) -> Int {
        if let model, let entry = windows[ContextWindows.family(for: model)], entry > 0 {
            return entry
        }
        if isCodex, let codex = windows[ContextWindows.codexKey], codex > 0 { return codex }
        return fallback
    }
}

/// Load/persist for `Settings.contextWindows` — the same JSON-in-`UserDefaults` shape
/// `PricingStorage` uses for the price table it sits under (SPEC §19.3).
enum ContextWindowStorage {
    static func load(_ defaults: UserDefaults, key: String) -> ContextWindows {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(ContextWindows.self, from: data)
        else { return .standard }
        return decoded
    }

    static func persist(_ table: ContextWindows, in defaults: UserDefaults, key: String) {
        guard let data = try? JSONEncoder().encode(table) else { return }
        defaults.set(data, forKey: key)
    }
}

/// SPEC §19.2: one session's context reading — what the row's chip says, what its tooltip says,
/// and whether it is over the threshold. A value with no view in it, so every one of those
/// answers is testable without laying a row out.
struct ContextGauge: Equatable {
    /// Tokens in the prompt at the last measurement (SPEC §19.1).
    let tokens: Int
    /// The window they are measured against — resolved by `ContextWindows`, never zero.
    let window: Int
    /// When the reporter measured. `nil` when the record carried no `context_at`, in which case
    /// the tooltip simply says nothing about age.
    let measuredAt: Date?

    /// SPEC §19.2's default: 40 %.
    static let defaultWarnFraction = 0.40
    /// The Settings stepper's range and step, in percent (SPEC §19.2).
    static let warnPercentRange = 10...90
    static let warnPercentStep = 5

    init(tokens: Int, window: Int, measuredAt: Date? = nil) {
        self.tokens = max(0, tokens)
        self.window = max(1, window)
        self.measuredAt = measuredAt
    }

    /// How full the context is. Not clamped: a measurement past the window is a real thing to
    /// know about, and only the *text* pins itself at 100 %.
    var fraction: Double { Double(tokens) / Double(window) }

    /// `ctx 24 %`, and `ctx 100 %` for anything at or past the window.
    var percentText: String { "ctx \(percent) %" }

    /// The rounded whole percent the chip shows, capped at 100.
    var percent: Int { min(100, Int((fraction * 100).rounded())) }

    /// SPEC §19.2: at or above the threshold the chip turns red and the session counts towards
    /// the header's "to compact". The epsilon is there so a threshold that came back through
    /// `Double(percent) / 100` still compares equal to the fraction it was set from.
    func isOverThreshold(_ threshold: Double = ContextGauge.defaultWarnFraction) -> Bool {
        fraction >= threshold - 1e-9
    }

    /// `236k of 1.0M tokens in context · measured 12s ago` — the chip's tooltip. The age is
    /// spelled with `Format.duration`, the same way every other elapsed number in the panel is.
    func tooltip(now: Date = Date()) -> String {
        let head = "\(ContextGauge.tokenText(tokens)) of \(ContextGauge.tokenText(window)) "
            + "tokens in context"
        guard let measuredAt else { return head }
        let age = Format.duration(max(0, now.timeIntervalSince(measuredAt)))
        return head + " · measured \(age) ago"
    }

    /// `812`, `236k`, `1.0M` — token counts as the tooltip spells them. Rounded before the unit
    /// is chosen, so 999 600 reads `1.0M` and not `1000k`.
    static func tokenText(_ tokens: Int) -> String {
        let value = max(0, tokens)
        if value < 1_000 { return "\(value)" }
        let thousands = Int((Double(value) / 1_000).rounded())
        if thousands < 1_000 { return "\(thousands)k" }
        return String(format: "%.1fM", Double(value) / 1_000_000)
    }
}

extension Session {
    /// SPEC §19.2: the row's gauge, or `nil` when nothing has been measured for this session yet
    /// — a compaction clears the measurement, so a just-compacted session has no chip either,
    /// until the next hook event fills it in again.
    func contextGauge(windows: ContextWindows) -> ContextGauge? {
        guard let tokens = contextTokens, tokens > 0 else { return nil }
        return ContextGauge(
            tokens: tokens, window: windows.window(for: self), measuredAt: contextAt
        )
    }
}
