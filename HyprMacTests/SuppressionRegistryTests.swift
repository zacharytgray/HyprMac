import XCTest
@testable import HyprMac

// SuppressionRegistryTests pin date-gated suppression semantics.
// the registry is pure state (no AX, no AppKit) so all tests run synchronously.

final class SuppressionRegistryTests: XCTestCase {

    // MARK: - basic suppress / isSuppressed / clear

    func testNewKeyIsNotSuppressed() {
        let r = SuppressionRegistry()
        XCTAssertFalse(r.isSuppressed("anything"))
    }

    func testSuppressedKeyReadsTrue() {
        let r = SuppressionRegistry()
        r.suppress("k", for: 1.0)
        XCTAssertTrue(r.isSuppressed("k"))
    }

    func testClearedKeyReadsFalse() {
        let r = SuppressionRegistry()
        r.suppress("k", for: 1.0)
        r.clear("k")
        XCTAssertFalse(r.isSuppressed("k"))
    }

    func testClearAllRemovesEveryKey() {
        let r = SuppressionRegistry()
        r.suppress("a", for: 1.0)
        r.suppress("b", for: 1.0)
        r.clearAll()
        XCTAssertFalse(r.isSuppressed("a"))
        XCTAssertFalse(r.isSuppressed("b"))
    }

    // MARK: - expiry

    func testExpiredKeyReadsFalse() {
        let r = SuppressionRegistry()
        // negative duration produces an expiry already in the past
        r.suppress("k", for: -1.0)
        XCTAssertFalse(r.isSuppressed("k"))
    }

    func testZeroDurationExpiresImmediately() {
        let r = SuppressionRegistry()
        r.suppress("k", for: 0)
        // is...Suppressed compares with >=, so an expiry equal to now is expired
        XCTAssertFalse(r.isSuppressed("k"))
    }

    // MARK: - extend semantics (later expiry wins, never shortens)

    func testExtendingWithLaterExpiryPersists() {
        let r = SuppressionRegistry()
        r.suppress("k", for: 0.05)
        r.suppress("k", for: 5.0)
        // first short window has long since elapsed by now in real time, but
        // the second long suppression should still be active.
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(r.isSuppressed("k"))
    }

    func testShorterDurationDoesNotShortenExistingSuppression() {
        let r = SuppressionRegistry()
        r.suppress("k", for: 5.0)
        r.suppress("k", for: 0.001)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertTrue(r.isSuppressed("k"))
    }

    // MARK: - keys are independent

    func testKeysAreIndependent() {
        let r = SuppressionRegistry()
        r.suppress("a", for: 5.0)
        XCTAssertTrue(r.isSuppressed("a"))
        XCTAssertFalse(r.isSuppressed("b"))
        r.clear("a")
        r.suppress("b", for: 5.0)
        XCTAssertFalse(r.isSuppressed("a"))
        XCTAssertTrue(r.isSuppressed("b"))
    }

    // MARK: - reason logging path doesn't crash

    func testReasonOverloadDoesNotCrash() {
        let r = SuppressionRegistry()
        r.suppress("k", for: 0.1, reason: "test reason")
        XCTAssertTrue(r.isSuppressed("k"))
    }
}
