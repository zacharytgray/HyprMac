import XCTest
@testable import HyprMac

// FocusPollGateTests pin which focus changes still pay for a full
// discovery poll.

final class FocusPollGateTests: XCTestCase {

    private func needsPoll(_ id: CGWindowID?, known: Set<CGWindowID> = [1, 2, 3],
                           hidden: Set<CGWindowID> = [2], visible: Set<CGWindowID> = [1, 2],
                           scratchpadUp: Bool = false) -> Bool {
        FocusPollGate.needsPoll(focusedID: id, scratchpadUp: scratchpadUp, known: known, hidden: hidden,
                                onVisibleWorkspace: { visible.contains($0) })
    }

    func testKnownVisibleWindowSkipsThePoll() {
        XCTAssertFalse(needsPoll(1))
    }

    func testScratchpadUpAlwaysPolls() {
        XCTAssertTrue(needsPoll(1, scratchpadUp: true), "focus behind the scrim has to come back")
    }

    func testUnreadFocusPolls() {
        XCTAssertTrue(needsPoll(nil))
    }

    func testUnknownWindowPolls() {
        XCTAssertTrue(needsPoll(9), "a window that announces itself only through focus")
    }

    func testHiddenWindowPolls() {
        XCTAssertTrue(needsPoll(2))
    }

    func testWindowOnAHiddenWorkspacePolls() {
        XCTAssertTrue(needsPoll(3), "park repair must see it pulled on screen")
    }
}
