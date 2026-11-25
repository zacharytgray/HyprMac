import XCTest
import Cocoa
@testable import HyprMac

// pins the tree shape after membership, swap and toggle changes on TilingEngine.

final class EngineTreeMutationTests: XCTestCase {

    private var displayManager: DisplayManager!
    private var engine: TilingEngine!
    private var screen: NSScreen!

    override func setUpWithError() throws {
        displayManager = DisplayManager()
        engine = TilingEngine(displayManager: displayManager,
                              frameSizingIOFactory: acceptingFrameSizingIOFactory())
        guard let main = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("no NSScreen available — test requires a display")
        }
        screen = main
    }

    private func tree() -> BSPTree? {
        engine.existingTree(forWorkspace: 1, screen: screen)
    }

    // MARK: - seedTree

    func testSeedTreeAddsMissingWindows() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)

        let layout = engine.seedTree([w1, w2], onWorkspace: 1, screen: screen)
        XCTAssertEqual(layout.count, 2)
        XCTAssertEqual(Set(tree()?.allWindows.map(\.windowID) ?? []), [1, 2])
    }

    func testSeedTreeRemovesGoneWindows() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        engine.seedTree([w1, w2], onWorkspace: 1, screen: screen)
        XCTAssertEqual(tree()?.allWindows.count, 2)

        // call again with only w1 — w2 should be evicted
        engine.seedTree([w1], onWorkspace: 1, screen: screen)
        XCTAssertEqual(tree()?.allWindows.map(\.windowID), [1])
    }

    func testSeedTreeKeepsRatiosUntilTheMembershipChanges() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        engine.seedTree([w1, w2], onWorkspace: 1, screen: screen)
        // mutate the parent ratio
        tree()?.root.splitRatio = 0.3
        XCTAssertEqual(tree()?.root.splitRatio, 0.3)

        // a fresh prepare over the same members keeps the ratio: the last
        // accepted pass found it, and resetting it here probed every known
        // minimum again on every retile
        tree()?.root.userSetRatio = false
        engine.seedTree([w1, w2], onWorkspace: 1, screen: screen)
        XCTAssertEqual(tree()?.root.splitRatio, 0.3)

        // a membership change resets what the user did not set
        engine.seedTree([w1, w2, makeWindow(id: 3)], onWorkspace: 1, screen: screen)
        XCTAssertEqual(tree()?.root.splitRatio, TilingConfig.defaultRatio)
    }

    func testSeedTreeLeavesRefusedWindowUntouched() {
        // shrink the depth ceiling so a 3rd window fails smartInsertFitting
        engine.maxSplitsPerMonitor[screen.localizedName] = 1

        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)

        engine.seedTree([w1, w2, w3], onWorkspace: 1, screen: screen)

        // preparation has no recovery side effects.
        XCTAssertEqual(Set(tree()?.allWindows.map(\.windowID) ?? []), [1, 2])
        XCTAssertFalse(w3.isFloating)
    }

    func testSeedTreeSkipsFloatingWindows() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        w2.isFloating = true

        let layout = engine.seedTree([w1, w2], onWorkspace: 1, screen: screen)
        XCTAssertEqual(layout.count, 1)
        XCTAssertEqual(tree()?.allWindows.map(\.windowID), [1])
    }

    // MARK: - swapWindows

    func testSwapWindowsSwapsLeafWindows() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        engine.seedTree([w1, w2], onWorkspace: 1, screen: screen)
        XCTAssertEqual(tree()?.root.left?.window?.windowID, 1)
        XCTAssertEqual(tree()?.root.right?.window?.windowID, 2)

        XCTAssertTrue(engine.swapWindows(w1, w2, onWorkspace: 1, screen: screen))
        XCTAssertEqual(tree()?.root.left?.window?.windowID, 2)
        XCTAssertEqual(tree()?.root.right?.window?.windowID, 1)
    }

    func testSwapWindowsRefusesAWindowNotInTheTree() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let stranger = makeWindow(id: 99)
        engine.seedTree([w1, w2], onWorkspace: 1, screen: screen)
        let before = tree()?.allWindows.map(\.windowID) ?? []

        XCTAssertFalse(engine.swapWindows(w1, stranger, onWorkspace: 1, screen: screen))
        XCTAssertEqual(tree()?.allWindows.map(\.windowID) ?? [], before)
    }

    // MARK: - toggleSplit

    func testToggleSplitFlipsParentDirection() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        engine.seedTree([w1, w2], onWorkspace: 1, screen: screen)
        // the split is pinned to the axis smart insert chose
        let pinned = tree()?.root.splitOverride
        XCTAssertNotNil(pinned)
        XCTAssertEqual(tree()?.root.splitOverrideIsAutomatic, true)

        engine.toggleSplit(w2, onWorkspace: 1, screen: screen)
        XCTAssertNotNil(tree()?.root.splitOverride)
        XCTAssertNotEqual(tree()?.root.splitOverride, pinned)
        XCTAssertEqual(tree()?.root.splitOverrideIsAutomatic, false, "togglesplit is the user's")
    }

    func testToggleSplitTwiceRevertsDirection() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        engine.seedTree([w1, w2], onWorkspace: 1, screen: screen)
        let original = tree()?.root.splitOverride

        engine.toggleSplit(w2, onWorkspace: 1, screen: screen)
        let toggled = tree()?.root.splitOverride
        engine.toggleSplit(w2, onWorkspace: 1, screen: screen)

        XCTAssertNotEqual(toggled, original)
        XCTAssertEqual(tree()?.root.splitOverride, original)
    }

    func testToggleSplitIgnoresAWindowNotInTheTree() {
        let w1 = makeWindow(id: 1)
        let stranger = makeWindow(id: 99)
        engine.seedTree([w1], onWorkspace: 1, screen: screen)
        let beforeOverride = tree()?.root.splitOverride

        engine.toggleSplit(stranger, onWorkspace: 1, screen: screen)
        XCTAssertEqual(tree()?.root.splitOverride, beforeOverride)
    }
}

// a keyboard swap past a monitor edge: each window takes the other's leaf in
// the other screen's tree.
final class EngineCrossScreenSwapTests: XCTestCase {

    private let left = CrossSwapLeftScreen()
    private let right = CrossSwapRightScreen()

    private func makeEngine(
        io: @escaping ([CGWindowID: HyprWindow], @escaping () -> UInt64) -> FrameSizingIO
            = acceptingFrameSizingIOFactory()
    ) -> TilingEngine {
        TilingEngine(displayManager: DisplayManager(screenSource: { [left, right] in [left, right] }),
                     frameSizingIOFactory: io)
    }

    private func ids(_ engine: TilingEngine, _ workspace: Int, _ screen: NSScreen) -> [CGWindowID] {
        engine.existingTree(forWorkspace: workspace, screen: screen)?.allWindows.map(\.windowID) ?? []
    }

    func testSwapAcrossScreensExchangesLeavesAndKeepsBothShapes() {
        let engine = makeEngine()
        let (w1, w2, w3, w4) = (makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3), makeWindow(id: 4))
        engine.seedTree([w1, w2], onWorkspace: 1, screen: left)
        engine.seedTree([w3, w4], onWorkspace: 2, screen: right)

        // w3 is the right screen's leftmost tile, w2 the left screen's rightmost
        XCTAssertTrue(engine.canSwapWindows(w3, onWorkspace: 2, screen: right,
                                            with: w2, onWorkspace: 1, screen: left))
        XCTAssertTrue(engine.swapWindows(w3, onWorkspace: 2, screen: right,
                                         with: w2, onWorkspace: 1, screen: left))

        XCTAssertEqual(ids(engine, 1, left), [1, 3])
        XCTAssertEqual(ids(engine, 2, right), [2, 4])
        XCTAssertEqual(engine.existingTree(forWorkspace: 1, screen: left)?.root.right?.window?.windowID, 3)
        XCTAssertEqual(engine.existingTree(forWorkspace: 2, screen: right)?.root.left?.window?.windowID, 2)
    }

    func testSwapAcrossScreensWithASoleWindowOnEachSide() {
        let engine = makeEngine()
        let (w1, w2) = (makeWindow(id: 1), makeWindow(id: 2))
        engine.seedTree([w1], onWorkspace: 1, screen: left)
        engine.seedTree([w2], onWorkspace: 2, screen: right)

        XCTAssertTrue(engine.swapWindows(w2, onWorkspace: 2, screen: right,
                                         with: w1, onWorkspace: 1, screen: left))
        XCTAssertEqual(ids(engine, 1, left), [2])
        XCTAssertEqual(ids(engine, 2, right), [1])
    }

    func testSwapAcrossScreensRefusesAWindowNotInItsTree() {
        let engine = makeEngine()
        let (w1, w2, stranger) = (makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 99))
        engine.seedTree([w1], onWorkspace: 1, screen: left)
        engine.seedTree([w2], onWorkspace: 2, screen: right)

        XCTAssertFalse(engine.swapWindows(w2, onWorkspace: 2, screen: right,
                                          with: stranger, onWorkspace: 1, screen: left))
        XCTAssertEqual(ids(engine, 1, left), [1])
        XCTAssertEqual(ids(engine, 2, right), [2])
    }

    func testSwapAcrossScreensRefusesAMinimumTheOtherScreenCannotHold() {
        let engine = makeEngine()
        let (w1, w2, w3) = (makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3))
        engine.seedTree([w1], onWorkspace: 1, screen: left)
        engine.seedTree([w2, w3], onWorkspace: 2, screen: right)
        // wider than the whole right screen
        w1.observedMinSize = CGSize(width: 1000, height: 0)
        w1.minSizeProvenance = .seeded

        XCTAssertFalse(engine.canSwapWindows(w1, onWorkspace: 1, screen: left,
                                             with: w2, onWorkspace: 2, screen: right))
        XCTAssertFalse(engine.swapWindows(w1, onWorkspace: 1, screen: left,
                                          with: w2, onWorkspace: 2, screen: right))
        XCTAssertEqual(ids(engine, 1, left), [1])
        XCTAssertEqual(ids(engine, 2, right), [2, 3])
    }

    /// the right screen's pass, laid out first, cannot read w1 back.
    func testSwapAcrossScreensRestoresBothTreesWhenTheFirstScreenRefuses() {
        assertRefusedSwapRestoresBothTrees(unreadable: 1)
    }

    /// the right screen's pass takes w1 and is accepted; the left screen's
    /// then cannot read w2 back. both trees go back as they were.
    func testSwapAcrossScreensRestoresBothTreesWhenTheSecondScreenRefuses() {
        assertRefusedSwapRestoresBothTrees(unreadable: 2)
    }

    private func assertRefusedSwapRestoresBothTrees(unreadable: CGWindowID,
                                                    line: UInt = #line) {
        var positions: [CGWindowID: CGPoint] = [:]
        var sizes: [CGWindowID: CGSize] = [:]
        var now: TimeInterval = 0
        let engine = makeEngine(io: { _, generation in
            FrameSizingIO(
                setMessagingTimeout: { _, _ in .success },
                writeSize: { id, size, _ in sizes[id] = size; return .success },
                writePosition: { id, position, _ in positions[id] = position; return .success },
                readPosition: { id, _ in
                    id == unreadable && positions[id] != nil ? (.cannotComplete, nil)
                        : (.success, positions[id] ?? .zero)
                },
                readSize: { id, _ in (.success, sizes[id] ?? CGSize(width: 100, height: 100)) },
                now: { now }, sleep: { now += $0 }, currentGeneration: generation)
        })
        let (w1, w2) = (makeWindow(id: 1), makeWindow(id: 2))
        engine.seedTree([w1], onWorkspace: 1, screen: left)
        engine.seedTree([w2], onWorkspace: 2, screen: right)

        XCTAssertFalse(engine.swapWindows(w2, onWorkspace: 2, screen: right,
                                          with: w1, onWorkspace: 1, screen: left), line: line)
        XCTAssertEqual(ids(engine, 1, left), [1], line: line)
        XCTAssertEqual(ids(engine, 2, right), [2], line: line)
    }
}

private final class CrossSwapLeftScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 1920, height: 1080) }
    override var visibleFrame: NSRect { frame }
}

private final class CrossSwapRightScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 1920, y: 0, width: 800, height: 600) }
    override var visibleFrame: NSRect { frame }
}
