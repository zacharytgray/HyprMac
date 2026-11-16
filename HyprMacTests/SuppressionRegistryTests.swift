import XCTest
@testable import HyprMac

// SuppressionRegistryTests pin date-gated suppression semantics.
// the registry is pure state (no AX, no AppKit) so all tests run synchronously.

final class SuppressionRegistryTests: XCTestCase {

    // MARK: - basic suppress / isSuppressed / clear

    func testNewKeyIsNotSuppressed() {
        let r = SuppressionRegistry()
        XCTAssertFalse(r.isSuppressed(.mouseFocus))
    }

    func testSuppressedKeyReadsTrue() {
        let r = SuppressionRegistry()
        r.suppress(.mouseFocus, for: 1.0)
        XCTAssertTrue(r.isSuppressed(.mouseFocus))
    }

    func testClearedKeyReadsFalse() {
        let r = SuppressionRegistry()
        r.suppress(.mouseFocus, for: 1.0)
        r.clear(.mouseFocus)
        XCTAssertFalse(r.isSuppressed(.mouseFocus))
    }

    func testClearAllRemovesEveryKey() {
        let r = SuppressionRegistry()
        r.suppress(.activationSwitch, for: 1.0)
        r.suppress(.workspaceTransition, for: 1.0)
        r.clearAll()
        XCTAssertFalse(r.isSuppressed(.activationSwitch))
        XCTAssertFalse(r.isSuppressed(.workspaceTransition))
    }

    // MARK: - who holds a key

    func testASwitchAloneHoldsTheTransitionAsASwitch() {
        let r = SuppressionRegistry()
        XCTAssertFalse(r.isHeldOnlyByWorkspaceSwitch(.workspaceTransition), "not held at all")
        r.suppress(.workspaceTransition, for: 1.0, source: .workspaceSwitch)
        XCTAssertTrue(r.isHeldOnlyByWorkspaceSwitch(.workspaceTransition))
    }

    func testAnyOtherHolderMakesItNotTheSwitchsAlone() {
        let r = SuppressionRegistry()
        r.suppress(.workspaceTransition, for: 1.0)
        r.suppress(.workspaceTransition, for: 1.0, source: .workspaceSwitch)
        XCTAssertFalse(r.isHeldOnlyByWorkspaceSwitch(.workspaceTransition))
    }

    func testAShorterOtherHoldUnderALongerSwitchHoldStillCounts() {
        // the expiry is never shortened, but the other hold is not lost
        let r = SuppressionRegistry()
        r.suppress(.workspaceTransition, for: 1.0, source: .workspaceSwitch)
        r.suppress(.workspaceTransition, for: 0.05)
        XCTAssertFalse(r.isHeldOnlyByWorkspaceSwitch(.workspaceTransition))
        Thread.sleep(forTimeInterval: 0.08)
        XCTAssertTrue(r.isHeldOnlyByWorkspaceSwitch(.workspaceTransition), "the other hold ran out")
    }

    func testClearDropsTheOtherHolderToo() {
        let r = SuppressionRegistry()
        r.suppress(.workspaceTransition, for: 1.0)
        r.clear(.workspaceTransition)
        r.suppress(.workspaceTransition, for: 1.0, source: .workspaceSwitch)
        XCTAssertTrue(r.isHeldOnlyByWorkspaceSwitch(.workspaceTransition))
    }

    // MARK: - expiry

    func testExpiredKeyReadsFalse() {
        let r = SuppressionRegistry()
        // negative duration produces an expiry already in the past
        r.suppress(.mouseFocus, for: -1.0)
        XCTAssertFalse(r.isSuppressed(.mouseFocus))
    }

    func testZeroDurationExpiresImmediately() {
        let r = SuppressionRegistry()
        r.suppress(.mouseFocus, for: 0)
        // is...Suppressed compares with >=, so an expiry equal to now is expired
        XCTAssertFalse(r.isSuppressed(.mouseFocus))
    }

    // MARK: - extend semantics (later expiry wins, never shortens)

    func testExtendingWithLaterExpiryPersists() {
        let r = SuppressionRegistry()
        r.suppress(.mouseFocus, for: 0.05)
        r.suppress(.mouseFocus, for: 5.0)
        // first short window has long since elapsed by now in real time, but
        // the second long suppression should still be active.
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(r.isSuppressed(.mouseFocus))
    }

    func testShorterDurationDoesNotShortenExistingSuppression() {
        let r = SuppressionRegistry()
        r.suppress(.mouseFocus, for: 5.0)
        r.suppress(.mouseFocus, for: 0.001)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertTrue(r.isSuppressed(.mouseFocus))
    }

    // MARK: - keys are independent

    func testKeysAreIndependent() {
        let r = SuppressionRegistry()
        r.suppress(.activationSwitch, for: 5.0)
        XCTAssertTrue(r.isSuppressed(.activationSwitch))
        XCTAssertFalse(r.isSuppressed(.workspaceTransition))
        r.clear(.activationSwitch)
        r.suppress(.workspaceTransition, for: 5.0)
        XCTAssertFalse(r.isSuppressed(.activationSwitch))
        XCTAssertTrue(r.isSuppressed(.workspaceTransition))
    }

    // MARK: - reason logging path doesn't crash

    func testReasonOverloadDoesNotCrash() {
        let r = SuppressionRegistry()
        r.suppress(.mouseFocus, for: 0.1, reason: "test reason")
        XCTAssertTrue(r.isSuppressed(.mouseFocus))
    }
}

final class ExpectedActivationTests: XCTestCase {
    /// a focus or raise HyprMac asked for is noted by pid and spent by the
    /// activation that follows, however late that notification arrives
    func testANotedActivationIsConsumedOnce() {
        let r = SuppressionRegistry()
        r.expectActivation(of: 4242)
        XCTAssertTrue(r.consumeExpectedActivation(of: 4242))
        XCTAssertFalse(r.consumeExpectedActivation(of: 4242), "spent")
        XCTAssertFalse(r.consumeExpectedActivation(of: 4243), "another app's activation is the user's")
    }

    /// a focus of a window of the app already in front activates nothing,
    /// so nothing consumes a note for it; the user's own Dock click on that
    /// app moments later must be theirs
    func testNoNoteIsKeptForTheAppAlreadyInFront() {
        let r = SuppressionRegistry()
        r.frontmostPID = { 4242 }
        r.expectActivation(of: 4242)
        XCTAssertFalse(r.consumeExpectedActivation(of: 4242))
        r.expectActivation(of: 4243)
        XCTAssertTrue(r.consumeExpectedActivation(of: 4243), "another app's focus is noted")
    }

    func testAnExpiredNoteIsNotHyprMacs() {
        let r = SuppressionRegistry()
        r.expectActivation(of: 4242, ttl: -1)
        XCTAssertFalse(r.consumeExpectedActivation(of: 4242))
    }

    func testClearAllDropsTheNotes() {
        let r = SuppressionRegistry()
        r.expectActivation(of: 4242)
        r.clearAll()
        XCTAssertFalse(r.consumeExpectedActivation(of: 4242))
    }

    func testRemainingReportsTheTimeLeftOnlyWhileActive() {
        let r = SuppressionRegistry()
        XCTAssertNil(r.remaining(.workspaceTransition))
        r.suppress(.workspaceTransition, for: 1.5)
        let left = r.remaining(.workspaceTransition)
        XCTAssertNotNil(left)
        XCTAssertLessThanOrEqual(left ?? 0, 1.5)
        XCTAssertGreaterThan(left ?? 0, 1.0)
        r.suppress(.workspaceTransition, for: -1)
        r.clear(.workspaceTransition)
        XCTAssertNil(r.remaining(.workspaceTransition))
    }
}
