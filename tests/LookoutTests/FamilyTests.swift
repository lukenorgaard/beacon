import SwiftUI
import XCTest
@testable import Lookout

/// SPEC §9.5: the family a row is tinted by, the short model name in its chip, and the two new
/// state-file fields both of those are computed from.
final class FamilyTests: XCTestCase {
    private let decoder = JSONDecoder()

    private func session(_ json: String) throws -> Session {
        try decoder.decode(Session.self, from: Data(json.utf8))
    }

    // MARK: - The fields (§9.5)

    func testModelAndProviderDecode() throws {
        let value = try session("""
        {"session_id":"s1","agent":"claude","model":"claude-fable-5-1","provider":"anthropic"}
        """)
        XCTAssertEqual(value.model, "claude-fable-5-1")
        XCTAssertEqual(value.provider, "anthropic")
        XCTAssertEqual(value.providerKey, "anthropic")
    }

    func testBothFieldsAreOptionalAndDegradeQuietly() throws {
        let bare = try session(#"{"session_id":"s1","agent":"claude"}"#)
        XCTAssertNil(bare.model)
        XCTAssertNil(bare.provider)
        XCTAssertNil(bare.providerKey)
        XCTAssertNil(bare.modelDisplayName)
        XCTAssertNil(bare.modelChip)
        XCTAssertNil(bare.modelTooltip)
        XCTAssertEqual(bare.family, .claude, "no provider means the agent decides")

        // Blank strings are the same as absent everywhere else in the model; here too.
        let blank = try session(#"{"session_id":"s2","agent":"claude","model":"  ","provider":" "}"#)
        XCTAssertNil(blank.providerKey)
        XCTAssertNil(blank.modelChip)
        XCTAssertEqual(blank.family, .claude)

        // A wrong type must not take the whole session down (SPEC §4's forgiving decode).
        let wrong = try session(#"{"session_id":"s3","agent":"claude","model":7,"provider":[1]}"#)
        XCTAssertNil(wrong.model)
        XCTAssertNil(wrong.provider)
    }

    func testTheNewFieldsSurviveARoundTrip() throws {
        let original = try session("""
        {"session_id":"s1","agent":"codex","model":"gpt-5.6-sol","provider":"openai"}
        """)
        let again = try decoder.decode(Session.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(original, again)
        XCTAssertEqual(again.model, "gpt-5.6-sol")
        XCTAssertEqual(again.provider, "openai")
    }

    // MARK: - Family rules, in §9.5's order

    func testProviderBeatsAgent() throws {
        XCTAssertEqual(
            try session(#"{"session_id":"1","agent":"claude","provider":"local"}"#).family, .local,
            "Claude Code pointed at a local model is a local row"
        )
        XCTAssertEqual(
            try session(#"{"session_id":"2","agent":"claude","provider":"openrouter"}"#).family,
            .api
        )
        XCTAssertEqual(
            try session(#"{"session_id":"3","agent":"claude","provider":"custom"}"#).family, .api
        )
        XCTAssertEqual(
            try session(#"{"session_id":"4","agent":"codex","provider":"local"}"#).family, .local
        )
    }

    func testTheAgentDecidesWhenTheProviderIsTheVendorsOwn() throws {
        XCTAssertEqual(
            try session(#"{"session_id":"1","agent":"claude","provider":"anthropic"}"#).family,
            .claude
        )
        XCTAssertEqual(
            try session(#"{"session_id":"2","agent":"codex","provider":"openai"}"#).family, .codex
        )
        XCTAssertEqual(try session(#"{"session_id":"3","agent":"codex"}"#).family, .codex)
        XCTAssertEqual(try session(#"{"session_id":"4","agent":"gemini"}"#).family, .other)
        XCTAssertEqual(try session(#"{"session_id":"5"}"#).family, .other, "unknown agent")
    }

    func testProviderCaseAndPaddingDoNotChangeTheFamily() throws {
        XCTAssertEqual(
            try session(#"{"session_id":"1","agent":"claude","provider":"  LOCAL "}"#).family,
            .local
        )
    }

    // MARK: - modelDisplayName (§9.5)

    func testTheDocumentedMapping() {
        XCTAssertEqual(Session.modelDisplayName("claude-fable-5-1"), "Fable")
        XCTAssertEqual(Session.modelDisplayName("claude-sonnet-5"), "Sonnet")
        XCTAssertEqual(Session.modelDisplayName("claude-opus-5"), "Opus")
        XCTAssertEqual(Session.modelDisplayName("claude-haiku-4-5-20251001"), "Haiku")
        XCTAssertEqual(Session.modelDisplayName("gpt-5.6-sol"), "GPT-5.6")
    }

    /// The same rule, applied to the shapes that are not in §9.5's list of examples.
    func testVersionNoiseIsStrippedWhateverTheVendor() {
        XCTAssertEqual(Session.modelDisplayName("llama-3.3-70b"), "Llama")
        XCTAssertEqual(Session.modelDisplayName("claude-3-5-sonnet-20241022"), "Sonnet")
        XCTAssertEqual(Session.modelDisplayName("claude-opus-5[1m]"), "Opus")
        XCTAssertEqual(Session.modelDisplayName("anthropic/claude-opus-5"), "Opus")
        XCTAssertEqual(Session.modelDisplayName("CLAUDE-FABLE-5-1"), "Fable", "case-insensitive")
        XCTAssertEqual(Session.modelDisplayName("  claude-opus-5  "), "Opus", "trimmed")
    }

    func testCodexKeepsItsVersionAndLosesItsEffortSuffix() {
        XCTAssertEqual(Session.modelDisplayName("gpt-5.6"), "GPT-5.6")
        XCTAssertEqual(Session.modelDisplayName("gpt-5.6-high"), "GPT-5.6")
        XCTAssertEqual(Session.modelDisplayName("gpt-5-minimal"), "GPT-5")
        XCTAssertEqual(Session.modelDisplayName("gpt-5-mini"), "GPT-5-mini", "a variant, not effort")
    }

    func testAnUnrecognisableNameComesBackVerbatimAndCapped() {
        XCTAssertEqual(Session.modelDisplayName("mistral-large-2411"), "mistral-large…")
        XCTAssertEqual(Session.modelDisplayName("o3"), "o3")
        XCTAssertNil(Session.modelDisplayName(nil))
        XCTAssertNil(Session.modelDisplayName("   "))

        for raw in [
            "some-extremely-long-internal-model-name", "qwen2.5-coder-32b-instruct",
            "mistral-large-2411", "gpt-5.6-sol", "claude-fable-5-1", "llama-3.3-70b",
        ] {
            let name = Session.modelDisplayName(raw)
            XCTAssertLessThanOrEqual(
                name?.count ?? 0, Session.modelDisplayLimit,
                "the chip never grows past \(Session.modelDisplayLimit) characters"
            )
        }
    }

    // MARK: - The chip (§9.5)

    func testTheDefaultProviderIsNeverSpelledOut() throws {
        XCTAssertEqual(
            try session("""
            {"session_id":"1","agent":"claude","model":"claude-fable-5-1","provider":"anthropic"}
            """).modelChip,
            "Fable"
        )
        XCTAssertEqual(
            try session("""
            {"session_id":"2","agent":"codex","model":"gpt-5.6-sol","provider":"openai"}
            """).modelChip,
            "GPT-5.6"
        )
        XCTAssertEqual(
            try session(#"{"session_id":"3","agent":"claude","model":"claude-sonnet-5"}"#).modelChip,
            "Sonnet", "no provider at all is the same as the default one"
        )
    }

    func testAnUnusualProviderIsSpelledOut() throws {
        XCTAssertEqual(
            try session("""
            {"session_id":"1","agent":"claude","model":"claude-fable-5-1","provider":"openrouter"}
            """).modelChip,
            "Fable · OpenRouter"
        )
        XCTAssertEqual(
            try session("""
            {"session_id":"2","agent":"claude","model":"llama-3.3-70b","provider":"local"}
            """).modelChip,
            "Llama · Local"
        )
        XCTAssertEqual(
            try session("""
            {"session_id":"3","agent":"claude","model":"claude-opus-5","provider":"custom"}
            """).modelChip,
            "Opus · Custom"
        )
        XCTAssertEqual(
            try session("""
            {"session_id":"4","agent":"codex","model":"gpt-5.6","provider":"openrouter"}
            """).modelChip,
            "GPT-5.6 · OpenRouter"
        )
        // An agent Lookout has never heard of has no "default" provider to hide.
        XCTAssertEqual(
            try session("""
            {"session_id":"5","agent":"gemini","model":"gemini-3","provider":"custom"}
            """).modelChip,
            "Gemini · Custom"
        )
    }

    func testTheTooltipKeepsTheRawModelName() throws {
        let value = try session("""
        {"session_id":"1","agent":"claude","model":"claude-haiku-4-5-20251001","provider":"local"}
        """)
        XCTAssertEqual(value.modelChip, "Haiku · Local")
        XCTAssertEqual(value.modelTooltip, "claude-haiku-4-5-20251001 · Local")
    }

    // MARK: - Colours (§9.5)

    func testTheFiveFamilyColoursAreTheOnesSpecified() {
        XCTAssertEqual(Theme.familyClaude.description, Color(hex: 0xF5A97F).description)
        XCTAssertEqual(Theme.familyCodex.description, Color(hex: 0x7CC4FA).description)
        XCTAssertEqual(Theme.familyLocal.description, Color(hex: 0x2DD4BF).description)
        XCTAssertEqual(Theme.familyAPI.description, Color(hex: 0xA78BFA).description)
        XCTAssertEqual(Theme.familyOther.description, Color(hex: 0xB4B8C8).description)

        let colours = SessionFamily.allCases.map { Theme.color(for: $0).description }
        XCTAssertEqual(Set(colours).count, SessionFamily.allCases.count, "five distinct tints")
    }

    func testTheRowTreatmentNumbersAreTheOnesSpecified() {
        XCTAssertEqual(Theme.familyStroke, 0.45)
        XCTAssertEqual(Theme.familyStrokeDiscovered, 0.25)
        XCTAssertEqual(Theme.familyFill, 0.05)
        XCTAssertEqual(Theme.familyChipFill, 0.18)
        XCTAssertEqual(Theme.familyStrokeWidth, 1)
        XCTAssertEqual(Theme.Metrics.standard.rowCorner, 10)
        // SPEC §14: the outline's radius scales with the text; its stroke never does.
        XCTAssertEqual(Theme.Metrics(Appearance(scale: 1.25)).rowCorner, 12.5)
        XCTAssertLessThan(
            Theme.familyStrokeDiscovered, Theme.familyStroke,
            "a discovered row has to read quieter than a reported one"
        )
    }

    func testTheLegendHasOneLabelPerFamilyInSpecOrder() {
        XCTAssertEqual(
            SessionFamily.allCases.map(\.label),
            ["Claude", "Codex", "Local model", "OpenRouter / API", "Other"]
        )
    }

    // MARK: - The fixtures

    func testTheFixturesCoverFourOfTheFiveFamilies() throws {
        func fixture(_ name: String) throws -> Session {
            try decoder.decode(
                Session.self,
                from: Data(contentsOf: Fixtures.sessionsDirectory.appendingPathComponent(name))
            )
        }

        let desktop = try fixture("claude-1d9e4b77-0c52-4a36-8f21-77a5c3b9d401.json")
        XCTAssertEqual(desktop.family, .claude)
        XCTAssertEqual(desktop.modelChip, "Fable")

        let cursor = try fixture("claude-ab813983-4f21-4c0e-9a17-2f5b6c8d1e00.json")
        XCTAssertEqual(cursor.family, .claude)
        XCTAssertEqual(cursor.modelChip, "Sonnet")

        let codex = try fixture("codex-7c1f0a52-9d34-4b88-b0a1-3e9d7c22aa10.json")
        XCTAssertEqual(codex.family, .codex)
        XCTAssertEqual(codex.modelChip, "GPT-5.6")

        let devin = try fixture("claude-3b6a2c19-88de-4d15-9c30-51e0f4a7b2c8.json")
        XCTAssertEqual(devin.family, .local)
        XCTAssertEqual(devin.modelChip, "Llama · Local")

        let iterm = try fixture("claude-5f2d8e60-71ba-42c7-a1d9-0c4b8e5a9f33.json")
        XCTAssertEqual(iterm.family, .api)
        XCTAssertEqual(iterm.modelChip, "Opus · OpenRouter")

        // One fixture keeps no model at all, so the agent-glyph path stays covered.
        let idle = try fixture("claude-9a0c5d34-2e17-4f9b-bd66-4c8a1f0e7d55.json")
        XCTAssertNil(idle.model)
        XCTAssertNil(idle.modelChip)
    }

    /// A discovered row knows nothing about its model, so it must still render (SPEC §8.2).
    func testADiscoveredRowHasNoModelAndAQuieterOutline() {
        var discovered = Session()
        discovered.sessionID = "discovered-1"
        discovered.agent = SessionAgent(raw: "claude")
        discovered.state = .running

        XCTAssertNil(discovered.modelChip)
        XCTAssertEqual(discovered.family, .claude)
    }
}
