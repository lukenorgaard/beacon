import XCTest
@testable import Lookout

/// SPEC §17.6: the pricing table's math, its defaults, persistence, and what a session's cost
/// chip and tooltip actually say.
final class PricingTests: XCTestCase {
    // MARK: - Defaults

    func testStandardMatchesTheSpecsFourModelFamilies() {
        let table = PricingTable.standard
        XCTAssertEqual(table.models["fable"], ModelPrice(input: 15, output: 75))
        XCTAssertEqual(table.models["opus"], ModelPrice(input: 15, output: 75))
        XCTAssertEqual(table.models["sonnet"], ModelPrice(input: 3, output: 15))
        XCTAssertEqual(table.models["haiku"], ModelPrice(input: 0.8, output: 4))
    }

    /// SPEC §17.6: cache read 10 %, cache write 125 % of input — computed once into the
    /// convenience initialiser, then independently editable from there.
    func testTheTwoArgumentInitialiserDerivesCacheFromInput() {
        let price = ModelPrice(input: 10, output: 50)
        XCTAssertEqual(price.cacheRead, 1, accuracy: 0.0001)
        XCTAssertEqual(price.cacheWrite, 12.5, accuracy: 0.0001)
    }

    // MARK: - Family resolution

    func testFamilyResolvesTheSameWayModelDisplayNameDoes() {
        XCTAssertEqual(PricingTable.family(for: "claude-fable-5-1"), "fable")
        XCTAssertEqual(PricingTable.family(for: "claude-sonnet-5"), "sonnet")
        XCTAssertEqual(PricingTable.family(for: "claude-opus-5"), "opus")
        XCTAssertEqual(PricingTable.family(for: "claude-haiku-4-5-20251001"), "haiku")
        // Unrecognised shapes fall back to the raw (lower-cased) string, same as
        // `Session.modelDisplayName`'s own "something odd beats nothing" rule.
        XCTAssertEqual(PricingTable.family(for: "llama-3.3-70b"), "llama")
    }

    // MARK: - Cost math

    func testCostSumsAllFourBucketsAtTheirOwnRates() throws {
        let table = PricingTable.standard
        // sonnet: in 3, out 15, cacheRead 0.3, cacheWrite 3.75 per 1M.
        let tokens = TokenBucket(inTokens: 1_000_000, outTokens: 1_000_000, cacheRead: 1_000_000, cacheWrite: 1_000_000)
        let cost = try XCTUnwrap(table.cost(model: "claude-sonnet-5", tokens: tokens))
        XCTAssertEqual(cost, 3 + 15 + 0.3 + 3.75, accuracy: 0.0001)
    }

    func testAnUnpricedModelReturnsNilNotZero() {
        let table = PricingTable.standard
        XCTAssertNil(table.cost(model: "gpt-5.6-sol", tokens: TokenBucket(inTokens: 1000)))
    }

    func testZeroTokensStillPricesToZeroForAKnownModel() {
        let table = PricingTable.standard
        XCTAssertEqual(table.cost(model: "claude-haiku-4-5", tokens: TokenBucket()), 0)
    }

    // MARK: - Session totals

    func testTotalCostIsNilWhenNothingInTheMapIsPriced() {
        let table = PricingTable.standard
        XCTAssertNil(table.totalCost(tokens: ["gpt-5.6-sol": TokenBucket(inTokens: 500)]))
        XCTAssertNil(table.totalCost(tokens: [:]))
    }

    func testTotalCostSumsOnlyThePricedModelsAndIgnoresTheRest() throws {
        let table = PricingTable.standard
        let tokens: [String: TokenBucket] = [
            "claude-haiku-4-5": TokenBucket(inTokens: 1_000_000, outTokens: 0),
            "gpt-5.6-sol": TokenBucket(inTokens: 1_000_000, outTokens: 0),
        ]
        XCTAssertEqual(try XCTUnwrap(table.totalCost(tokens: tokens)), 0.8, accuracy: 0.0001)
    }

    func testBreakdownIsSortedMostExpensiveFirst() {
        let table = PricingTable.standard
        let tokens: [String: TokenBucket] = [
            "claude-haiku-4-5": TokenBucket(inTokens: 1_000_000),
            "claude-opus-5": TokenBucket(inTokens: 1_000_000),
        ]
        let breakdown = table.breakdown(tokens: tokens)
        XCTAssertEqual(breakdown.count, 2)
        XCTAssertEqual(breakdown[0].model, "claude-opus-5")
        XCTAssertEqual(breakdown[1].model, "claude-haiku-4-5")
    }

    // MARK: - Formatting

    func testFormatSpellsZeroTinyAndOrdinaryAmountsDifferently() {
        XCTAssertEqual(PricingTable.format(0), "$0.00")
        XCTAssertEqual(PricingTable.format(-1), "$0.00")
        XCTAssertEqual(PricingTable.format(0.001), "<$0.01")
        XCTAssertEqual(PricingTable.format(0.42), "$0.42")
        XCTAssertEqual(PricingTable.format(12.3), "$12.30")
    }

    /// The wording fix: every cost figure the owner actually sees is prefixed "≈" — he is on a
    /// subscription, not paying API prices.
    func testFormatEstimatePrefixesEveryAmountWithTheApproximationSign() {
        XCTAssertEqual(PricingTable.formatEstimate(0.42), "≈ $0.42")
        XCTAssertEqual(PricingTable.formatEstimate(12.3), "≈ $12.30")
        XCTAssertEqual(PricingTable.formatEstimate(0), "≈ $0.00")
    }

    // MARK: - Session integration

    private func session(tokens: [String: TokenBucket]) -> Session {
        var session = Session()
        session.sessionID = "s1"
        session.tokens = tokens
        return session
    }

    func testASessionWithNoTokensHasNoCost() {
        let session = session(tokens: [:])
        XCTAssertNil(session.cost(pricing: .standard))
        XCTAssertNil(session.costTooltip(pricing: .standard))
    }

    func testASessionsCostIsTheTablesTotal() throws {
        let session = session(tokens: ["claude-haiku-4-5": TokenBucket(inTokens: 1_000_000)])
        XCTAssertEqual(try XCTUnwrap(session.cost(pricing: .standard)), 0.8, accuracy: 0.0001)
    }

    func testTheTooltipListsEveryModelIncludingUnpricedOnes() throws {
        let session = session(tokens: [
            "claude-haiku-4-5": TokenBucket(inTokens: 1_000_000, outTokens: 500_000),
            "gpt-5.6-sol": TokenBucket(inTokens: 2_000_000),
        ])
        let tooltip = try XCTUnwrap(session.costTooltip(pricing: .standard))
        XCTAssertTrue(tooltip.contains("Haiku"), tooltip)
        XCTAssertTrue(tooltip.contains("unpriced"), tooltip)
    }

    /// The wording fix: the tooltip starts by saying plainly this is an estimate, not a charge.
    func testTheTooltipStartsWithTheApiEquivalentEstimateLine() throws {
        let session = session(tokens: ["claude-haiku-4-5": TokenBucket(inTokens: 1_000_000)])
        let tooltip = try XCTUnwrap(session.costTooltip(pricing: .standard))
        XCTAssertTrue(
            tooltip.hasPrefix("API-equivalent estimate at the prices in Settings → Usage"),
            tooltip
        )
    }

    // MARK: - Persistence (SPEC §17.6's editable table)

    func testPricingStorageRoundTripsThroughUserDefaults() {
        let suite = "io.github.lukenorgaard.beacon.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var custom = PricingTable.standard
        custom.models["sonnet"] = ModelPrice(input: 4, output: 20, cacheRead: 0.4, cacheWrite: 5)
        PricingStorage.persist(custom, in: defaults, key: "pricingTable")

        let loaded = PricingStorage.load(defaults, key: "pricingTable")
        XCTAssertEqual(loaded, custom)
        XCTAssertEqual(loaded.models["sonnet"]?.input, 4)
    }

    func testPricingStorageFallsBackToStandardWhenNothingIsStored() {
        let suite = "io.github.lukenorgaard.beacon.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(PricingStorage.load(defaults, key: "pricingTable"), .standard)
    }

    /// `Settings.pricing` itself, editable and persisted like every other feature's table.
    func testSettingsPersistsAnEditedPricingTable() {
        let suite = "io.github.lukenorgaard.beacon.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = Settings(defaults: defaults)
        XCTAssertEqual(settings.pricing, .standard)
        settings.pricing.models["haiku"] = ModelPrice(input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25)

        let reopened = Settings(defaults: defaults)
        XCTAssertEqual(reopened.pricing.models["haiku"]?.input, 1)
    }

    // MARK: - Ordered keys used by the Settings UI

    func testOrderedModelKeysCoverEveryStandardModel() {
        XCTAssertEqual(Set(PricingTable.orderedModelKeys), Set(PricingTable.standard.models.keys))
    }
}
