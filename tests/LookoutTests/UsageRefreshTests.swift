import Combine
import XCTest
@testable import Lookout

final class UsageRefreshTests: XCTestCase {
    func testManualRefreshRetriesAfterDenialWhileAutomaticRefreshWaits() {
        let lock = NSLock()
        var reads = 0
        let client = UsageClient(readToken: {
            lock.lock()
            defer { lock.unlock() }
            reads += 1
            return reads == 1 ? .denied : .missing
        })
        let first = expectation(description: "Initial denial")
        let retried = expectation(description: "Manual retry")
        retried.assertForOverFulfill = true
        let subscription = client.$error.compactMap { $0 }.sink { error in
            if case .keychainDenied = error { first.fulfill() }
            if case .notSignedIn = error { retried.fulfill() }
        }
        defer { subscription.cancel() }

        client.refresh()
        wait(for: [first], timeout: 2)
        client.refresh()
        client.refreshByUser()
        wait(for: [retried], timeout: 2)
        lock.lock()
        let count = reads
        lock.unlock()
        XCTAssertEqual(count, 2, "Only the initial attempt and the explicit retry may read Keychain")
        XCTAssertEqual(client.error, .notSignedIn)
    }
}
