import AppKit
import Combine
import SwiftUI

extension SettingsView {
    // MARK: - Pricing (SPEC §17.6)

    /// The four column labels, once — every row below lines its fields up under these rather
    /// than repeating a label over each field (see the comment where this is used).
    var pricingHeader: some View {
        HStack(spacing: 6) {
            Text("").frame(width: 46, alignment: .leading)
            Text("In").frame(width: 42)
            Text("Out").frame(width: 42)
            Text("C-read").frame(width: 42)
            Text("C-write").frame(width: 42)
        }
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)
    }

    func pricingRow(_ key: String) -> some View {
        HStack(spacing: 6) {
            Text(key.capitalized)
                .font(.system(size: 11))
                .frame(width: 46, alignment: .leading)
            pricingField("In", model: key, priceBinding(key, \.input))
            pricingField("Out", model: key, priceBinding(key, \.output))
            pricingField("cache-read", model: key, priceBinding(key, \.cacheRead))
            pricingField("cache-write", model: key, priceBinding(key, \.cacheWrite))
        }
    }

    private func pricingField(_ label: String, model: String, _ value: Binding<String>) -> some View {
        // A plain `text:` binding, like every other field in this form. Caught by rendering this
        // to a PNG: a bordered `TextField` whose *content* is a single character ("3", "1", "4")
        // negotiates a smaller intrinsic size than its 4-model neighbours even under the same
        // `.frame(width: 42)`, shifting that one field — `priceText` below keeps every value at
        // least 4 characters (fixed 2 decimals) so the short-content case never comes up. Pinning
        // an explicit height instead was tried and made it worse: it starved the row's own
        // spacing in the surrounding `VStack`, so rows overlapped each other.
        TextField("", text: value)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 10).monospacedDigit())
            .frame(width: 42)
            .accessibilityLabel("\(label) price for \(model)")
    }

    /// Reads/writes one of `ModelPrice`'s four fields for one model key as plain text, creating
    /// the model's entry (all zero) the first time it is typed into if the table did not already
    /// have one. Unparseable text (mid-edit, or cleared) is simply not written — the field keeps
    /// showing the last valid value rather than silently zeroing a price.
    private func priceBinding(_ key: String, _ field: WritableKeyPath<ModelPrice, Double>) -> Binding<String> {
        Binding(
            get: { SettingsView.priceText(settings.pricing.models[key]?[keyPath: field] ?? 0) },
            set: { newValue in
                guard let parsed = Double(newValue.replacingOccurrences(of: ",", with: ".")) else { return }
                var price = settings.pricing.models[key]
                    ?? ModelPrice(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)
                price[keyPath: field] = parsed
                settings.pricing.models[key] = price
            }
        )
    }

    /// `15.00`, `0.30`, `18.75` — always two decimal places (never trimmed): every value stays at
    /// least 4 characters, which sidesteps the single-character field-sizing bug documented above
    /// `pricingField`.
    private static func priceText(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    // MARK: - Context per session (SPEC §19.2, §19.3)

    /// "Suggest compact at 40 %" — its own row, with the stepper at the trailing edge and the
    /// value beside it, so nothing sits on top of anything.
    var contextThresholdRow: some View {
        HStack(spacing: SettingsView.gap) {
            Text("Suggest compact at")
                .font(.system(size: 11))
            Spacer(minLength: SettingsView.gap)
            Text("\(settings.contextWarnPercent) %")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            Stepper(
                "Suggest compact at",
                value: $settings.contextWarnPercent,
                in: ContextGauge.warnPercentRange,
                step: ContextGauge.warnPercentStep
            )
            .labelsHidden()
        }
    }

    /// One editable window per model family, laid out under the pricing rows and lined up with
    /// them: the same 46 pt name column, then a single field.
    ///
    /// Bug fix, 2026-09-06: this used to write to `settings.contextWindows` on every keystroke,
    /// so retyping "200,000" into "500,000" passed a "5", then "50", then "500" … through a
    /// binding that committed each one immediately — every row read against that tiny window and
    /// turned red for the length of the retype. The field's live text now lives in
    /// `contextWindowTexts`, and only `commitContextWindow` ever writes to Settings, run on
    /// submit or on losing focus — never mid-keystroke.
    func contextWindowRow(_ key: String) -> some View {
        HStack(spacing: 6) {
            Text(ContextWindows.label(for: key))
                .font(.system(size: 11))
                .frame(width: 92, alignment: .leading)
            TextField("", text: contextWindowTextBinding(key))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10).monospacedDigit())
                .frame(width: 88)
                .focused($focusedContextWindowKey, equals: key)
                .onSubmit { commitContextWindow(key) }
                .onChange(of: focusedContextWindowKey) { previous, current in
                    guard previous == key, current != key else { return }
                    commitContextWindow(key)
                }
                .accessibilityLabel("Context window for \(ContextWindows.label(for: key))")
            Spacer(minLength: SettingsView.gap)
        }
    }

    /// The live text for one field: the not-yet-committed buffer while it is being edited,
    /// otherwise the persisted, grouped value.
    private func contextWindowTextBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { contextWindowTexts[key] ?? SettingsView.windowText(persistedContextWindow(key)) },
            set: { contextWindowTexts[key] = $0 }
        )
    }

    private func persistedContextWindow(_ key: String) -> Int {
        settings.contextWindows.windows[key] ?? ContextWindows.standard.windows[key] ?? 0
    }

    /// Submit or focus loss only: parses the field's buffer and writes it to Settings when — and
    /// only when — it is a real value; either way the field is left showing the persisted number,
    /// grouped, never the raw digits the owner was mid-typing.
    private func commitContextWindow(_ key: String) {
        if let text = contextWindowTexts[key], let parsed = SettingsView.parseContextWindow(text) {
            settings.contextWindows.windows[key] = parsed
        }
        contextWindowTexts[key] = SettingsView.windowText(persistedContextWindow(key))
    }

    /// The floor below which a typed number cannot be a real context window — it exists so an
    /// in-progress retype ("200,000" → "5" → "50" → … → "500,000") never commits a value small
    /// enough to divide every row's percentage by (almost) nothing and turn it red before the
    /// owner finishes typing.
    static let minContextWindow = 1_000

    /// Digits only, then the floor above — pure, so the validation is testable without a view.
    /// Unparseable text or anything below the floor is refused the same way: `nil`, and the
    /// caller restores the field instead of clearing it.
    static func parseContextWindow(_ text: String) -> Int? {
        let digits = text.filter(\.isNumber)
        guard let parsed = Int(digits), parsed >= minContextWindow else { return nil }
        return parsed
    }

    /// `1,000,000` — a seven-digit window is unreadable as a run of digits, and every value in
    /// this table is at least six.
    private static let windowFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSize = 3
        formatter.groupingSeparator = ","
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func windowText(_ value: Int) -> String {
        windowFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
