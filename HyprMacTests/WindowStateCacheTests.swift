import XCTest
@testable import HyprMac

// WindowStateCacheTests pin the atomic-forget contract and per-dict lifecycle
// invariants. the cache is pure state — no AX, no AppKit — so all tests run
// synchronously without any test fixtures beyond a synthetic HyprWindow.

final class WindowStateCacheTests: XCTestCase {

    // MARK: - empty-cache invariants

    func testEmptyCacheReturnsNoState() {
        let c = WindowStateCache()
        XCTAssertNil(c.cachedWindows[1])
        XCTAssertNil(c.tiledPositions[1])
        XCTAssertNil(c.originalFrames[1])
        XCTAssertNil(c.windowOwners[1])
        XCTAssertFalse(c.hiddenWindowIDs.contains(1))
        XCTAssertFalse(c.floatingWindowIDs.contains(1))
        XCTAssertFalse(c.knownWindowIDs.contains(1))
    }

    // MARK: - atomic forget

    func testForgetClearsAllSevenDicts() {
        let c = WindowStateCache()
        let w = makeWindow(id: 42, pid: 99)
        let frame = CGRect(x: 10, y: 20, width: 100, height: 200)

        c.cachedWindows[42] = w
        c.tiledPositions[42] = frame
        c.originalFrames[42] = frame
        c.windowOwners[42] = 99
        c.hiddenWindowIDs.insert(42)
        c.floatingWindowIDs.insert(42)
        c.knownWindowIDs.insert(42)

        c.forget(42)

        XCTAssertNil(c.cachedWindows[42])
        XCTAssertNil(c.tiledPositions[42])
        XCTAssertNil(c.originalFrames[42])
        XCTAssertNil(c.windowOwners[42])
        XCTAssertFalse(c.hiddenWindowIDs.contains(42))
        XCTAssertFalse(c.floatingWindowIDs.contains(42))
        XCTAssertFalse(c.knownWindowIDs.contains(42))
    }

    func testForgetUnknownIDIsNoOp() {
        let c = WindowStateCache()
        c.knownWindowIDs.insert(1)
        c.cachedWindows[1] = makeWindow(id: 1)
        c.forget(999)
        XCTAssertTrue(c.knownWindowIDs.contains(1))
        XCTAssertNotNil(c.cachedWindows[1])
    }

    func testForgetIsolatesByID() {
        let c = WindowStateCache()
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        c.cachedWindows[1] = w1
        c.cachedWindows[2] = w2
        c.knownWindowIDs.insert(1)
        c.knownWindowIDs.insert(2)
        c.tiledPositions[1] = .zero
        c.tiledPositions[2] = .init(x: 1, y: 1, width: 1, height: 1)
        c.windowOwners[1] = 100
        c.windowOwners[2] = 200

        c.forget(1)

        XCTAssertNil(c.cachedWindows[1])
        XCTAssertNotNil(c.cachedWindows[2])
        XCTAssertFalse(c.knownWindowIDs.contains(1))
        XCTAssertTrue(c.knownWindowIDs.contains(2))
        XCTAssertNil(c.tiledPositions[1])
        XCTAssertEqual(c.tiledPositions[2]?.origin.x, 1)
        XCTAssertNil(c.windowOwners[1])
        XCTAssertEqual(c.windowOwners[2], 200)
    }

    // MARK: - per-dict mutation

    func testEachDictReadsBackWhatWasWritten() {
        let c = WindowStateCache()
        let w = makeWindow(id: 7, pid: 33)
        let frame = CGRect(x: 100, y: 200, width: 300, height: 400)

        c.cachedWindows[7] = w
        c.tiledPositions[7] = frame
        c.originalFrames[7] = frame
        c.windowOwners[7] = 33
        c.hiddenWindowIDs.insert(7)
        c.floatingWindowIDs.insert(7)
        c.knownWindowIDs.insert(7)

        XCTAssertEqual(c.cachedWindows[7]?.windowID, 7)
        XCTAssertEqual(c.tiledPositions[7], frame)
        XCTAssertEqual(c.originalFrames[7], frame)
        XCTAssertEqual(c.windowOwners[7], 33)
        XCTAssertTrue(c.hiddenWindowIDs.contains(7))
        XCTAssertTrue(c.floatingWindowIDs.contains(7))
        XCTAssertTrue(c.knownWindowIDs.contains(7))
    }

    // MARK: - hidden vs known invariant

    // documents (does not enforce) the discovery-layer invariant that a hidden
    // window stays known so it isn't rediscovered as new on return. the cache
    // doesn't police this — pollWindowChanges does — but the test makes the
    // expectation visible.
    func testHiddenAndKnownCanCoexist() {
        let c = WindowStateCache()
        c.knownWindowIDs.insert(5)
        c.hiddenWindowIDs.insert(5)
        XCTAssertTrue(c.knownWindowIDs.contains(5))
        XCTAssertTrue(c.hiddenWindowIDs.contains(5))
    }

    // forget is what discovery calls when an app terminates; it must clear both.
    func testForgetClearsHiddenAndKnownTogether() {
        let c = WindowStateCache()
        c.knownWindowIDs.insert(5)
        c.hiddenWindowIDs.insert(5)
        c.forget(5)
        XCTAssertFalse(c.knownWindowIDs.contains(5))
        XCTAssertFalse(c.hiddenWindowIDs.contains(5))
    }
}
