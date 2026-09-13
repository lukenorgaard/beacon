import Foundation
import XCTest
@testable import Lookout

/// Switching Claude accounts rewrites the `Claude Code-credentials` item, and a rebuilt app with
/// a new signature loses its place on the item's access list; either way the next read raises
/// the "Beacon wants to access…" prompt again. That prompt is unavoidable — no app may add
/// itself to another's keychain ACL without the user saying so. What *was* avoidable is what
/// happened next: a denied prompt looked identical to "not signed in", so the 60 s tick walked
/// straight back into it, once a minute, forever.
final class KeychainOutcomeTests: XCTestCase {

    private let credentials = Data(#"{"claudeAiOauth":{"accessToken":"tok-abc"}}"#.utf8)

    func testAGoodReadYieldsTheToken() {
        XCTAssertEqual(
            Keychain.outcome(for: errSecSuccess, data: credentials),
            .token("tok-abc")
        )
    }

    func testADeniedOrDismissedPromptIsItsOwnOutcome() {
        for status in [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed,
                       errSecInteractionRequired, errSecNotAvailable] {
            XCTAssertEqual(
                Keychain.outcome(for: status, data: nil), .denied,
                "OSStatus \(status) is the user declining, not a missing credential"
            )
        }
    }

    func testNoItemIsMissingRatherThanDenied() {
        XCTAssertEqual(Keychain.outcome(for: errSecItemNotFound, data: nil), .missing)
    }

    /// A successful read of something that is not the credentials JSON is not a denial either —
    /// re-prompting would not help.
    func testUnreadableDataIsMissing() {
        XCTAssertEqual(Keychain.outcome(for: errSecSuccess, data: Data("nonsense".utf8)), .missing)
        XCTAssertEqual(Keychain.outcome(for: errSecSuccess, data: nil), .missing)
    }

    /// The two failures have to read differently, or the panel cannot tell the user what to do.
    func testTheTwoFailuresSayDifferentThings() {
        XCTAssertNotEqual(UsageError.keychainDenied.message, UsageError.notSignedIn.message)
        XCTAssertTrue(UsageError.keychainDenied.message.lowercased().contains("refresh"),
                      "the message has to name the way out")
    }

    /// The endpoint once answered `Retry-After: 0` and the client believed it, logging
    /// "next attempt in 0s" — no backoff at all. Non-positive hints must not disable it.
    func testBackoffDelayIsNeverZero() {
        XCTAssertEqual(UsageClient.backoffDelay(retryAfter: "0", strikes: 1), 30)
        XCTAssertEqual(UsageClient.backoffDelay(retryAfter: "-5", strikes: 1), 30)
        XCTAssertEqual(UsageClient.backoffDelay(retryAfter: "nonsense", strikes: 1), 30)
        XCTAssertEqual(UsageClient.backoffDelay(retryAfter: nil, strikes: 1), 30)
        XCTAssertEqual(UsageClient.backoffDelay(retryAfter: nil, strikes: 3), 120)
        XCTAssertEqual(UsageClient.backoffDelay(retryAfter: "120", strikes: 1), 120,
                       "a real Retry-After is honoured")
        XCTAssertEqual(UsageClient.backoffDelay(retryAfter: "99999", strikes: 1), 15 * 60, "capped")
    }
}
