import XCTest
import Cocoa
@testable import HyprMac

// LayoutTreeSerializeTests pin TilingEngine.layoutTree — the read-only
// walk that turns a live BSP tree into the LayoutNode a snapshot stores.
// Node knobs (ratio, user-set flag, override) must come through
// verbatim, a computed direction must stay nil, and a window the ref
// closure declines must collapse its split like a close would.
// runs on a synthetic screen so it executes headless as well as on a real display.

final class LayoutTreeSerializeTests: XCTestCase {

    private var engine: TilingEngine!
    private var screen: NSScreen!

    override func setUp() {
        screen = SerializeTestScreen()
        let screens: [NSScreen] = [screen]
        engine = TilingEngine(displayManager: DisplayManager(screenSource: { screens }),
                              frameSizingIOFactory: acceptingFrameSizingIOFactory())
    }

    private func ref(_ window: HyprWindow) -> SavedWindowRef? {
        SavedWindowRef(bundleID: "app.\(window.windowID)", title: "")
    }

    private func leaf(_ id: CGWindowID) -> LayoutNode {
        .leaf(SavedWindowRef(bundleID: "app.\(id)", title: ""))
    }

    private func tile(_ ids: [CGWindowID]) {
        _ = engine.prepareTileLayout(ids.map { makeWindow(id: $0) }, onWorkspace: 1, screen: screen)
    }

    func testEmptyWorkspaceIsNil() {
        XCTAssertNil(engine.layoutTree(forWorkspace: 1, ref: ref))
    }

    func testSingleWindowIsALeaf() {
        tile([1])
        XCTAssertEqual(engine.layoutTree(forWorkspace: 1, ref: ref), leaf(1))
    }

    func testNodeKnobsComeThroughVerbatim() throws {
        tile([1, 2])
        let tree = try XCTUnwrap(engine.existingTree(forWorkspace: 1, screen: screen))
        tree.root.splitRatio = 0.7
        tree.root.userSetRatio = true
        tree.root.splitOverride = .vertical

        XCTAssertEqual(engine.layoutTree(forWorkspace: 1, ref: ref),
                       .split(override: .vertical, ratio: 0.7, userSet: true,
                              left: leaf(1), right: leaf(2)))
    }

    func testComputedDirectionSerialisesAsNilOverride() throws {
        tile([1, 2])
        guard case .split(let override, _, let userSet, _, _)? = engine.layoutTree(forWorkspace: 1, ref: ref) else {
            return XCTFail("expected a split at the root")
        }
        XCTAssertNil(override, "a dwindle-chosen axis must not be frozen into the snapshot")
        XCTAssertFalse(userSet)
    }

    func testLeavesFollowTreeOrder() {
        tile([1, 2, 3])
        XCTAssertEqual(engine.layoutTree(forWorkspace: 1, ref: ref)?.leaves.map(\.bundleID),
                       ["app.1", "app.2", "app.3"])
    }

    func testDeclinedWindowCollapsesItsSplit() {
        tile([1, 2, 3])
        let node = engine.layoutTree(forWorkspace: 1) { $0.windowID == 2 ? nil : self.ref($0) }
        guard case .split(_, _, _, let left, let right)? = node else {
            return XCTFail("expected a single split over the two surviving leaves, got \(String(describing: node))")
        }
        XCTAssertEqual(left, leaf(1))
        XCTAssertEqual(right, leaf(3))
    }

    func testAllWindowsDeclinedIsNil() {
        tile([1, 2])
        XCTAssertNil(engine.layoutTree(forWorkspace: 1) { _ in nil })
    }

    func testOtherWorkspaceIsUntouched() {
        tile([1, 2])
        XCTAssertNil(engine.layoutTree(forWorkspace: 2, ref: ref))
    }
}

private final class SerializeTestScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 2400, height: 1600) }
    override var visibleFrame: NSRect { frame }
}
