import XCTest
@testable import HyprMac

final class HyprWindowAXReadTests: XCTestCase {
    private final class ScriptedWindow: HyprWindow {
        var scriptedPosition: (AXError, CGPoint?) = (.success, nil)
        var scriptedSize: (AXError, CGSize?) = (.success, nil)

        override func readPosition() -> (AXError, CGPoint?) {
            scriptedPosition
        }

        override func readSize() -> (AXError, CGSize?) {
            scriptedSize
        }
    }

    func testPublicFrameDelegatesToTypedReadsAndFailsClosed() {
        let window = ScriptedWindow(
            element: AXUIElementCreateApplication(0), windowID: 50, ownerPID: 0
        )
        let expected = CGRect(x: 12, y: 34, width: 640, height: 480)
        window.scriptedPosition = (.success, expected.origin)
        window.scriptedSize = (.success, expected.size)
        XCTAssertEqual(window.position, expected.origin)
        XCTAssertEqual(window.size, expected.size)
        XCTAssertEqual(window.frame, expected)

        window.scriptedPosition = (.cannotComplete, nil)
        XCTAssertNil(window.position)
        XCTAssertNil(window.frame)
        window.scriptedPosition = (.success, expected.origin)
        window.scriptedSize = (.failure, nil)
        XCTAssertNil(window.size)
        XCTAssertNil(window.frame)
    }
}

/// Chrome and pointer follow the window list when AX goes stale. CARROT
/// Weather's window keeps a centered AX frame after every drag.
final class OnScreenFrameTests: XCTestCase {
    private final class StaleAXWindow: HyprWindow {
        var ax: CGRect?
        var server: CGRect?

        override func readPosition() -> (AXError, CGPoint?) { (.success, ax?.origin) }
        override func readSize() -> (AXError, CGSize?) { (.success, ax?.size) }
        override var windowServerFrame: CGRect? { server }
    }

    private let staleAX = CGRect(x: 1208, y: 42, width: 1024, height: 1264)
    private let drawn = CGRect(x: 779, y: 133, width: 1024, height: 1264)

    private func window(_ id: CGWindowID, ax: CGRect?, server: CGRect?) -> StaleAXWindow {
        let w = StaleAXWindow(element: AXUIElementCreateApplication(0), windowID: id, ownerPID: 0)
        w.ax = ax
        w.server = server
        return w
    }

    func testPrefersTheWindowListAndFallsBackToAX() {
        XCTAssertEqual(HyprWindow.onScreenFrame(server: drawn, ax: staleAX), drawn)
        XCTAssertEqual(HyprWindow.onScreenFrame(server: nil, ax: staleAX), staleAX)
        // an empty list entry is no frame
        XCTAssertEqual(HyprWindow.onScreenFrame(server: .zero, ax: staleAX), staleAX)
        XCTAssertNil(HyprWindow.onScreenFrame(server: nil, ax: nil))
    }

    func testOnScreenFrameReadsTheListBeforeAskingTheServer() {
        let w = window(33621, ax: staleAX, server: nil)
        XCTAssertEqual(w.onScreenFrame(listed: [33621: drawn]), drawn)
        // a list without the window falls back to AX, not to a server query
        w.server = CGRect(x: 1, y: 2, width: 300, height: 300)
        XCTAssertEqual(w.onScreenFrame(listed: [:]), staleAX)
        // no list: asks the server about this one window
        w.server = drawn
        XCTAssertEqual(w.onScreenFrame(), drawn)
        // writes and readback keep reading AX
        XCTAssertEqual(w.frame, staleAX)
    }

    func testWarpCenterUsesTheDrawnFrame() {
        let w = window(33621, ax: staleAX, server: drawn)
        XCTAssertEqual(w.onScreenCenter, CGPoint(x: drawn.midX, y: drawn.midY))
        XCTAssertEqual(w.center, CGPoint(x: staleAX.midX, y: staleAX.midY))
        w.server = nil
        XCTAssertEqual(w.onScreenCenter, CGPoint(x: staleAX.midX, y: staleAX.midY))
    }

    func testFloaterOutlineUsesTheDrawnFrame() {
        let carrot = window(33621, ax: staleAX, server: nil)
        let calculator = window(40, ax: CGRect(x: 100, y: 100, width: 230, height: 400), server: nil)
        let tile = window(50, ax: CGRect(x: 0, y: 0, width: 800, height: 800), server: nil)
        let hidden = window(60, ax: CGRect(x: 0, y: 0, width: 300, height: 300), server: nil)
        let listed = WindowManager.listedFrames([
            StackedWindow(windowID: 33621, ownerPID: 1, bounds: drawn),
            StackedWindow(windowID: 50, ownerPID: 2, bounds: CGRect(x: 0, y: 0, width: 800, height: 800)),
        ])
        let frames = WindowManager.floatingFrames(
            from: [carrot, calculator, tile, hidden], floatingIDs: [33621, 40, 60],
            isVisible: { $0 != 60 }, listed: listed, expandedBy: 2)
        XCTAssertEqual(frames[33621], drawn.insetBy(dx: -2, dy: -2))
        // a floater the list lacks keeps its AX frame
        XCTAssertEqual(frames[40], CGRect(x: 98, y: 98, width: 234, height: 404))
        XCTAssertNil(frames[50])
        XCTAssertNil(frames[60])
    }

    // calculator on top of carrot, both over a tile
    private func overlappingFloaters() -> [StackedWindow] {
        [
            StackedWindow(windowID: 40, ownerPID: 3, bounds: CGRect(x: 900, y: 200, width: 230, height: 400)),
            StackedWindow(windowID: 33621, ownerPID: 1, bounds: drawn),
            StackedWindow(windowID: 50, ownerPID: 2, bounds: CGRect(x: 0, y: 0, width: 3440, height: 1440)),
        ]
    }

    func testPressOnAFloaterOverAnotherFloaterPicksTheFrontOne() {
        let windows = overlappingFloaters()
        let pressed = WindowStacking.pressedFloater(
            at: CGPoint(x: 1000, y: 210), in: windows, floaterIDs: [40, 33621],
            frontmostPID: 1, ownPID: 99)
        XCTAssertEqual(pressed?.id, 40)
        XCTAssertEqual(pressed?.frame, CGRect(x: 900, y: 200, width: 230, height: 400))
        // carrot alone under the press
        let carrot = WindowStacking.pressedFloater(
            at: CGPoint(x: 800, y: 140), in: windows, floaterIDs: [40, 33621],
            frontmostPID: 1, ownPID: 99)
        XCTAssertEqual(carrot?.id, 33621)
        XCTAssertEqual(carrot?.frame, drawn)
        // the tile is no floater
        XCTAssertNil(WindowStacking.pressedFloater(
            at: CGPoint(x: 3000, y: 1300), in: windows, floaterIDs: [40, 33621],
            frontmostPID: 1, ownPID: 99))
        // a floater under a tile is not pressed
        let buried = [windows[2], windows[0], windows[1]]
        XCTAssertNil(WindowStacking.pressedFloater(
            at: CGPoint(x: 1000, y: 210), in: buried, floaterIDs: [40, 33621],
            frontmostPID: 1, ownPID: 99))
    }

    func testDragOfAStaleAXWindowFollowsTheDrawnFrame() {
        // the press reads carrot from the window list. its AX frame never enters
        let press = CGPoint(x: 1200, y: 145)
        let pressed = WindowStacking.pressedFloater(
            at: press, in: overlappingFloaters(), floaterIDs: [40, 33621],
            frontmostPID: 1, ownPID: 99)
        XCTAssertEqual(pressed?.frame, drawn)
        var listed = drawn
        var live: CGRect?
        let tracker = FloatingDimDragTracker(setCarve: { _, _ in },
                                             setLiveFrame: { _, frame in live = frame },
                                             clearCarve: {})
        tracker.arm(id: 33621, readFrame: { listed }, startFrame: pressed!.frame, downPointCG: press)
        listed = drawn.offsetBy(dx: -300, dy: 20)
        tracker.update(cursorCG: CGPoint(x: press.x - 300, y: press.y + 20))
        XCTAssertEqual(live, drawn.offsetBy(dx: -300, dy: 20))
        XCTAssertNotEqual(live?.origin, staleAX.offsetBy(dx: -300, dy: 20).origin)
    }

    func testDisagreementNeedsMoreThanAFewPoints() {
        let base = CGRect(x: 100, y: 100, width: 500, height: 400)
        XCTAssertFalse(HyprWindow.framesDisagree(base, base.offsetBy(dx: 3, dy: -4)))
        XCTAssertTrue(HyprWindow.framesDisagree(base, base.offsetBy(dx: 5, dy: 0)))
        XCTAssertTrue(HyprWindow.framesDisagree(staleAX, drawn))
    }
}
