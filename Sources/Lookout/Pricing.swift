import Foundation

/// USD per million tokens for one model family — four independently editable numbers, because a
/// cache-read token and a cache-write token do not cost the same as an input token (SPEC §17.6).
struct ModelPrice: Codable, Equatable {
    /// USD per 1M input tokens.
    var input: Double
    /// USD per 1M output tokens.
    var output: Double
    /// USD per 1M cache-read tokens.
    var cacheRead: Double
    /// USD per 1M cache-write tokens.
    var cacheWrite: Double

    init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    /// `cacheRead`/`cacheWrite` default to SPEC §17.6's 10 % / 125 % of `input` — a convenience
    /// for building the standard table, not something the type enforces afterwards: each field
    /// is its own editable number in Settings, and nothing re-derives it once it has been typed.
    init(input: Double, output: Double) {
        self.init(input: input, output: output, cacheRead: input * 0.10, cacheWrite: input * 1.25)
    }
}

/// The per-model-family table Settings → Usage edits (SPEC §17.6). Keyed by the same short family
/// name `Session.modelDisplayName` already produces — `claude-fable-5-1` and `claude-sonnet-5`
/// both resolve to a key here (`fable`, `sonnet`) without the table ever seeing the raw string.
struct PricingTable: Codable, Equatable {
    var models: [String: ModelPrice]

    /// The fixed row order the Settings UI and the tests both use.
    static let orderedModelKeys = ["fable", "opus", "sonnet", "haiku"]

    /// SPEC §17.6's defaults: fable 15/75, opus 15/75, sonnet 3/15, haiku 0.8/4, cache read 10 %,
    /// cache write 125 % of input.
    static let standard = PricingTable(models: [
        "fable": ModelPrice(input: 15, output: 75),
        "opus": ModelPrice(input: 15, output: 75),
        "sonnet": ModelPrice(input: 3, output: 15),
        "haiku": ModelPrice(input: 0.8, output: 4),
    ])

    /// The table key a raw model string prices against: `Session.modelDisplayName` already knows
    /// how to turn `claude-fable-5-1` into `Fable`; lower-casing that is the table's key.
    static func family(for model: String) -> String {
        (Session.modelDisplayName(model) ?? model).lowercased()
    }

    func price(for model: String) -> ModelPrice? {
        models[PricingTable.family(for: model)]
    }

    /// One bucket's cost — `nil` (never 0) when the table has no price for the model, so an
    /// unpriced model can be told apart from a genuinely free one.
    func cost(model: String, tokens: TokenBucket) -> Double? {
        guard let price = price(for: model) else { return nil }
        return Double(tokens.inTokens) / 1_000_000 * price.input
            + Double(tokens.outTokens) / 1_000_000 * price.output
            + Double(tokens.cacheRead) / 1_000_000 * price.cacheRead
            + Double(tokens.cacheWrite) / 1_000_000 * price.cacheWrite
    }

    /// Every priced model's cost, summed. `nil` when nothing in `tokens` has a price at all —
    /// the row's cost chip and the Usage tab's total both use this to tell "free" apart from
    /// "the table does not know this model".
    func totalCost(tokens: [String: TokenBucket]) -> Double? {
        var total = 0.0
        var priced = false
        for (model, bucket) in tokens {
            guard let cost = cost(model: model, tokens: bucket) else { continue }
            total += cost
            priced = true
        }
        return priced ? total : nil
    }

    /// Per-model breakdown, most expensive first — the cost chip's tooltip order.
    func breakdown(tokens: [String: TokenBucket]) -> [(model: String, cost: Double?, tokens: TokenBucket)] {
        tokens
            .map { (model: $0.key, cost: cost(model: $0.key, tokens: $0.value), tokens: $0.value) }
            .sorted { ($0.cost ?? -1) > ($1.cost ?? -1) }
    }

    /// `$0.42`, `<$0.01`, `$0.00` — one consistent spelling everywhere a cost is shown.
    static func format(_ usd: Double) -> String {
        if usd <= 0 { return "$0.00" }
        if usd < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", usd)
    }

    /// `≈ $0.42` — every cost figure the owner actually sees (the row chip, the Usage tab's
    /// "Sessions today"): he is on a subscription, so this is always an *estimate* of what the
    /// tokens would cost at API prices, never a real charge.
    static func formatEstimate(_ usd: Double) -> String {
        "≈ " + format(usd)
    }
}

extension Session {
    /// SPEC §17.6: `nil` when there is nothing to price — no tokens recorded at all, or every
    /// model in them unknown to the table — so the row never shows a `$0.00` chip that quietly
    /// means "I don't know".
    func cost(pricing: PricingTable) -> Double? {
        guard !tokens.isEmpty else { return nil }
        return pricing.totalCost(tokens: tokens)
    }

    /// The cost chip's tooltip: a header that says plainly this is an estimate (the owner is on a
    /// subscription, not paying API prices), then one line per priced model.
    func costTooltip(pricing: PricingTable) -> String? {
        guard !tokens.isEmpty else { return nil }
        let lines = pricing.breakdown(tokens: tokens).map { entry -> String in
            let name = Session.modelDisplayName(entry.model) ?? entry.model
            let cost = entry.cost.map(PricingTable.format) ?? "unpriced"
            return "\(name): \(cost) (\(entry.tokens.inTokens) in · \(entry.tokens.outTokens) out)"
        }
        guard !lines.isEmpty else { return nil }
        let header = "API-equivalent estimate at the prices in Settings → Usage"
        return ([header] + lines).joined(separator: "\n")
    }
}

/// Load/persist for `Settings.pricing` — the same JSON-in-`UserDefaults` shape `AnswerPresets`
/// and `HotKeyStorage` already use.
enum PricingStorage {
    static func load(_ defaults: UserDefaults, key: String) -> PricingTable {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(PricingTable.self, from: data)
        else { return .standard }
        return decoded
    }

    static func persist(_ table: PricingTable, in defaults: UserDefaults, key: String) {
        guard let data = try? JSONEncoder().encode(table) else { return }
        defaults.set(data, forKey: key)
    }
}
