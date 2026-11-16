import XCTest
@testable import HyprMac

// a new window splits the focused tile (issue #79). the engine reads the
// focused tile through splitTargetSource; a tiled newcomer that macOS gave
// the keyboard takes the focus record, so the next one splits it.

final class SplitFocusedTileTests: XCTestCase {

    // MARK: - engine

    private func makeEngine(screens: [NSScreen]) -> TilingEngine {
        TilingEngine(displayManager: DisplayManager(screenSource: { screens }),
                     frameSizingIOFactory: acceptingFrameSizingIOFactory())
    }

    private func sibling(of id: CGWindowID, in engine: TilingEngine,
                         workspace: Int = 1, screen: NSScreen) -> CGWindowID? {
        guard let tree = engine.existingTree(forWorkspace: workspace, screen: screen),
              let node = tree.root.allLeavesRightToLeft().first(where: { $0.window?.windowID == id }),
              let parent = node.parent else { return nil }
        return (parent.left === node ? parent.right : parent.left)?.window?.windowID
    }

    /// the issue's shape: the left tile focused, three tiles, a newcomer
    func testANewWindowSplitsTheFocusedTile() {
        let screen = SplitTestScreen()
        let engine = makeEngine(screens: [screen])
        let left = makeWindow(id: 7901), top = makeWindow(id: 7902), bottom = makeWindow(id: 7903)
        XCTAssertTrue(engine.tileWindows([left, top, bottom], onWorkspace: 1, screen: screen).published)
        engine.splitTargetSource = { left.windowID }

        let newcomer = makeWindow(id: 7904)
        XCTAssertTrue(engine.tileWindows([left, top, bottom, newcomer], onWorkspace: 1, screen: screen).published)

        XCTAssertEqual(sibling(of: newcomer.windowID, in: engine, screen: screen), left.windowID)
        let rects = engine.intendedTileRects()
        XCTAssertEqual(rects[newcomer.windowID]?.minX, rects[left.windowID]?.minX, "beside the left tile")
    }

    func testWithoutATargetANewWindowSplitsTheDeepestRightTile() {
        let screen = SplitTestScreen()
        let engine = makeEngine(screens: [screen])
        let left = makeWindow(id: 7911), top = makeWindow(id: 7912), bottom = makeWindow(id: 7913)
        XCTAssertTrue(engine.tileWindows([left, top, bottom], onWorkspace: 1, screen: screen).published)

        let newcomer = makeWindow(id: 7914)
        XCTAssertTrue(engine.tileWindows([left, top, bottom, newcomer], onWorkspace: 1, screen: screen).published)

        XCTAssertEqual(sibling(of: newcomer.windowID, in: engine, screen: screen), bottom.windowID)
    }

    func testTwoNewcomersInOnePassSpiralOutFromTheFocusedTile() {
        let screen = SplitTestScreen()
        let engine = makeEngine(screens: [screen])
        let a = makeWindow(id: 7921), b = makeWindow(id: 7922)
        XCTAssertTrue(engine.tileWindows([a, b], onWorkspace: 1, screen: screen).published)
        engine.splitTargetSource = { a.windowID }

        let first = makeWindow(id: 7923), second = makeWindow(id: 7924)
        XCTAssertTrue(engine.tileWindows([a, b, first, second], onWorkspace: 1, screen: screen).published)

        // a's half holds a, then first split again for second; b's half is untouched
        XCTAssertEqual(sibling(of: second.windowID, in: engine, screen: screen), first.windowID)
        let tree = engine.existingTree(forWorkspace: 1, screen: screen)
        XCTAssertEqual(tree?.root.left?.left?.window?.windowID, a.windowID)
        XCTAssertEqual(tree?.root.right?.window?.windowID, b.windowID)
    }

    func testATargetOnAnotherWorkspaceAndScreenIsIgnored() {
        let screen = SplitTestScreen(), other = SplitTestSideScreen()
        let engine = makeEngine(screens: [screen, other])
        let a = makeWindow(id: 7931), b = makeWindow(id: 7932), c = makeWindow(id: 7933)
        let elsewhere = makeWindow(id: 7935)
        XCTAssertTrue(engine.tileWindows([a, b, c], onWorkspace: 1, screen: screen).published)
        XCTAssertTrue(engine.tileWindows([elsewhere], onWorkspace: 2, screen: other).published)
        engine.splitTargetSource = { elsewhere.windowID }

        let newcomer = makeWindow(id: 7934)
        XCTAssertTrue(engine.tileWindows([a, b, c, newcomer], onWorkspace: 1, screen: screen).published)

        XCTAssertEqual(sibling(of: newcomer.windowID, in: engine, screen: screen), c.windowID)
    }

    func testFillingAnEmptyTreeIgnoresATargetAmongTheNewcomers() {
        let screen = SplitTestScreen()
        let ids: [CGWindowID] = [7941, 7942, 7943, 7944]

        let plain = makeEngine(screens: [screen])
        XCTAssertTrue(plain.tileWindows(ids.map { makeWindow(id: $0) }, onWorkspace: 1, screen: screen).published)
        let expected = plain.existingTree(forWorkspace: 1, screen: screen)?.structuralFingerprint()

        let focused = makeEngine(screens: [screen])
        focused.splitTargetSource = { 7942 }
        XCTAssertTrue(focused.tileWindows(ids.map { makeWindow(id: $0) }, onWorkspace: 1, screen: screen).published)

        XCTAssertNotNil(expected)
        XCTAssertEqual(focused.existingTree(forWorkspace: 1, screen: screen)?.structuralFingerprint(), expected)
    }

    func testAReturningWindowGoesBackToItsSlotOverTheFocusedTile() {
        let screen = SplitTestScreen()
        let engine = makeEngine(screens: [screen])
        let a = makeWindow(id: 7951), b = makeWindow(id: 7952), c = makeWindow(id: 7953), d = makeWindow(id: 7954)
        XCTAssertTrue(engine.tileWindows([a, b, c, d], onWorkspace: 1, screen: screen).published)
        let before = engine.intendedTileRects()

        engine.removeWindowID(b.windowID)
        XCTAssertTrue(engine.tileWindows([a, c, d], onWorkspace: 1, screen: screen).published)
        engine.splitTargetSource = { a.windowID }
        XCTAssertTrue(engine.tileWindows([a, b, c, d], onWorkspace: 1, screen: screen).published)

        XCTAssertEqual(engine.intendedTileRects(), before)
    }

    /// a and b side by side, two levels deep at most. b cannot share its
    /// slot with the second newcomer. the walk puts the first newcomer
    /// beside b and the second beside a. splitting the focused a first
    /// leaves the second only b, so the pass refuses it, and the fit check
    /// has to say the same
    func testTheFitCheckAgreesWithThePassWhenATargetIsSet() {
        let screen = SplitTestScreen()
        func run(target: CGWindowID?) -> (fits: Bool, refused: Set<CGWindowID>) {
            let engine = makeEngine(screens: [screen])
            engine.maxSplitsPerMonitor = [screen.localizedName: 2]
            let a = makeWindow(id: 7961), b = makeWindow(id: 7962)
            let first = makeWindow(id: 7963), second = makeWindow(id: 7964)
            b.observedMinSize = CGSize(width: 500, height: 700)
            second.observedMinSize = CGSize(width: 300, height: 300)
            XCTAssertTrue(engine.tileWindows([a, b], onWorkspace: 1, screen: screen).published)
            engine.splitTargetSource = { target }
            let all = [a, b, first, second]
            let fits = engine.canFitWindows(all, onWorkspace: 1, screen: screen)
            let result = engine.tileWindows(all, onWorkspace: 1, screen: screen)
            return (fits, result.refusedIDs)
        }

        let walked = run(target: nil)
        XCTAssertTrue(walked.fits)
        XCTAssertEqual(walked.refused, [])

        let focused = run(target: 7961)
        XCTAssertFalse(focused.fits)
        XCTAssertEqual(focused.refused, [7964])
    }
}

private final class SplitTestScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 4000, y: 0, width: 1600, height: 1000) }
    override var visibleFrame: NSRect { frame }
}

private final class SplitTestSideScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 5600, y: 0, width: 1600, height: 1000) }
    override var visibleFrame: NSRect { frame }
}
