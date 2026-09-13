import Foundation

/// The checked-in fixtures live next to the sources, not in a bundle — the executable target has
/// no resources, so the tests reach for them by path.
enum Fixtures {
    /// Keep retention tests anchored to the dates in the checked-in history fixture.
    static let historyNow = Date(timeIntervalSince1970: 1_788_436_800) // 2026-09-03 12:00 UTC

    static var root: URL {
        URL(fileURLWithPath: #filePath)      // Tests/LookoutTests/Fixtures.swift
            .deletingLastPathComponent()     // Tests/LookoutTests
            .deletingLastPathComponent()     // Tests
            .deletingLastPathComponent()     // repository root
    }

    static var usageJSON: URL {
        root.appendingPathComponent("tests/fixtures/usage.json")
    }

    static var sessionsDirectory: URL {
        root.appendingPathComponent("tests/fixtures/sessions")
    }

    /// The open permission / question requests that go with the two `needs_you` sessions
    /// (SPEC §11.3).
    static var requestsDirectory: URL {
        root.appendingPathComponent("tests/fixtures/requests")
    }

    /// A hand-written Claude transcript tail (SPEC §13.2): six surviving turns, a 900-char
    /// assistant message, tool_use / tool_result / meta lines to drop, and a Danish last word.
    static var transcript: URL {
        root.appendingPathComponent("tests/fixtures/transcript.jsonl")
    }

    /// `LOOKOUT_HOME` for the fixture set: the parent of both directories.
    static var home: URL {
        root.appendingPathComponent("tests/fixtures")
    }

    /// SPEC §17.5: a handful of transitions across two days, for grouping/search and the
    /// headless History tab render.
    static var historyJSONL: URL {
        root.appendingPathComponent("tests/fixtures/history.jsonl")
    }

    /// SPEC §17.7: the common real-machine shape — `secondary` and `limit_name` both null.
    static var codexUsageJSON: URL {
        root.appendingPathComponent("tests/fixtures/codex-usage.json")
    }

    /// Bug fix 2026-09-04: a synthetic Codex rollout with one open, unanswered
    /// `request_user_input` call carrying two questions — one with options, one free-text.
    static var codexRolloutQuestion: URL {
        root.appendingPathComponent("tests/fixtures/codex-rollout-question.jsonl")
    }
}
