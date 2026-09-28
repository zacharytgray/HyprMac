import XCTest
import Cocoa
@testable import HyprMac

// LayoutTreeRebuildTests pin TilingEngine.rebuildTree — the only path that
// turns a saved LayoutNode back into a live BSP tree. A rebuilt tree must
// serialise back to exactly what went in (shape, overrides, ratios,
// user-set flags), a leaf without a window must collapse its split the way
// a close would, windows the snapshot never named must insert around the
// restored shape, and a refused verification must leave the live tree alone.
// A rebuild must never drop an admitted window: an incumbent that finds no
// slot rejects the whole rebuild, a refused newcomer is handed back.
//
// runs on a synthetic screen so it executes headless as well as on a real display.

final class LayoutTreeRebuildTests: XCTestCase {

    private var engine: TilingEngine!
    private var screen: NSScreen!
    private var windows: [CGWindowID: HyprWindow] = [:]

    private var displayManager: DisplayManager!

    override func setUp() {
        screen = RebuildTestScreen()
        let screens: [NSScreen] = [screen]
        displayManager = DisplayManager(screenSource: { screens })
        engine = makeEngine(acceptingFrameSizingIOFactory())
        windows = Dictionary(uniqueKeysWithValues: (1...6).map { ($0, makeWindow(id: $0)) })
    }

    private func makeEngine(_ io: @escaping ([CGWindowID: HyprWindow], @escaping () -> UInt64) -> FrameSizingIO) -> TilingEngine {
        TilingEngine(displayManager: displayManager, frameSizingIOFactory: io)
    }

    // refs are keyed on window id so a snapshot can be written by hand
    private func ref(_ id: CGWindowID) -> SavedWindowRef {
        SavedWindowRef(bundleID: "app.\(id)", title: "")
    }

    private func leaf(_ id: CGWindowID) -> LayoutNode { .leaf(ref(id)) }

    private func refOf(_ window: HyprWindow) -> SavedWindowRef? { ref(window.windowID) }

    /// Resolver that maps "app.N" back to window N.
    private func byID(_ ref: SavedWindowRef) -> HyprWindow? {
        CGWindowID(ref.bundleID.dropFirst(4)).flatMap { windows[$0] }
    }

    private func ids(_ list: [CGWindowID]) -> [HyprWindow] { list.compactMap { windows[$0] } }

    private func live() -> BSPTree? { engine.existingTree(forWorkspace: 1, screen: screen) }

    // MARK: - exact round trips

    func testTwoByTwoGridRoundTripsExactly() {
        // shape frames can't express: root horizontal, each side split vertical
        let grid = LayoutNode.split(
            override: .horizontal, ratio: 0.5, userSet: false,
            left: .split(override: .vertical, ratio: 0.5, userSet: false, left: leaf(1), right: leaf(2)),
            right: .split(override: .vertical, ratio: 0.5, userSet: false, left: leaf(3), right: leaf(4)))

        let outcome = engine.rebuildTree(forWorkspace: 1, screen: screen, from: grid,
                                         windows: ids([1, 2, 3, 4]), applyFrames: true, resolve: byID)

        XCTAssertEqual(outcome, .rebuilt(inserted: 0, refusedNewcomers: []))
        XCTAssertEqual(engine.layoutTree(forWorkspace: 1, ref: refOf), grid)
    }

    func testDwindleChainFromLiveEngineRoundTrips() {
        // shape produced by the real insert path on one engine, restored on another
        _ = engine.prepareTileLayout(ids([1, 2, 3]), onWorkspace: 1, screen: screen)
        let saved = engine.layoutTree(forWorkspace: 1, ref: refOf)!

        let other = makeEngine(acceptingFrameSizingIOFactory())
        let outcome = other.rebuildTree(forWorkspace: 1, screen: screen, from: saved,
                                        windows: ids([1, 2, 3]), applyFrames: true, resolve: byID)

        XCTAssertEqual(outcome, .rebuilt(inserted: 0, refusedNewcomers: []))
        XCTAssertEqual(other.layoutTree(forWorkspace: 1, ref: refOf), saved)
    }

    func testUserSetRatioAndOverrideSurvive() {
        let saved = LayoutNode.split(override: .vertical, ratio: 0.7, userSet: true,
                                     left: leaf(1), right: leaf(2))

        _ = engine.rebuildTree(forWorkspace: 1, screen: screen, from: saved,
                               windows: ids([1, 2]), applyFrames: true, resolve: byID)

        let root = live()!.root
        XCTAssertEqual(root.splitRatio, 0.7)
        XCTAssertTrue(root.userSetRatio)
        XCTAssertEqual(root.splitOverride, .vertical)
        XCTAssertEqual(engine.layoutTree(forWorkspace: 1, ref: refOf), saved)
    }

    func testNilOverrideStaysNil() {
        let saved = LayoutNode.split(override: nil, ratio: 0.5, userSet: false, left: leaf(1), right: leaf(2))
        _ = engine.rebuildTree(forWorkspace: 1, screen: screen, from: saved,
                               windows: ids([1, 2]), applyFrames: true, resolve: byID)
        XCTAssertNil(live()!.root.splitOverride, "a computed axis must not become a forced one")
    }

    func testRebuiltNodesHaveParents() {
        let saved = LayoutNode.split(override: nil, ratio: 0.5, userSet: false,
                                     left: leaf(1),
                                     right: .split(override: nil, ratio: 0.5, userSet: false, left: leaf(2), right: leaf(3)))
        _ = engine.rebuildTree(forWorkspace: 1, screen: screen, from: saved,
                               windows: ids([1, 2, 3]), applyFrames: true, resolve: byID)
        let root = live()!.root
        XCTAssertTrue(root.left?.parent === root)
        XCTAssertTrue(root.right?.parent === root)
        XCTAssertTrue(root.right?.left?.parent === root.right)
        XCTAssertEqual(root.right?.right?.depth, 2)
    }

    // MARK: - missing and extra windows

    func testMissingWindowCollapsesItsSplit() {
        let saved = LayoutNode.split(
            override: nil, ratio: 0.6, userSet: true,
            left: leaf(1),
            right: .split(override: .vertical, ratio: 0.5, userSet: false, left: leaf(2), right: leaf(3)))

        // window 2 is gone: its split collapses, the outer split keeps its knobs
        let outcome = engine.rebuildTree(forWorkspace: 1, screen: screen, from: saved,
                                         windows: ids([1, 3]), applyFrames: true, resolve: byID)

        XCTAssertEqual(outcome, .rebuilt(inserted: 0, refusedNewcomers: []))
        XCTAssertEqual(engine.layoutTree(forWorkspace: 1, ref: refOf),
                       .split(override: nil, ratio: 0.6, userSet: true, left: leaf(1), right: leaf(3)))
    }

    func testAllWindowsMissingLeavesEmptyPublishedTree() {
        let saved = LayoutNode.split(override: nil, ratio: 0.5, userSet: false, left: leaf(1), right: leaf(2))
        let outcome = engine.rebuildTree(forWorkspace: 1, screen: screen, from: saved,
                                         windows: [], applyFrames: true, resolve: byID)
        XCTAssertEqual(outcome, .rebuilt(inserted: 0, refusedNewcomers: []))
        XCTAssertNil(engine.layoutTree(forWorkspace: 1, ref: refOf))
    }

    func testUnnamedWindowInsertsAroundRestoredShape() {
        let saved = LayoutNode.split(override: nil, ratio: 0.7, userSet: true, left: leaf(1), right: leaf(2))

        let outcome = engine.rebuildTree(forWorkspace: 1, screen: screen, from: saved,
                                         windows: ids([1, 2, 3]), applyFrames: true, resolve: byID)

        XCTAssertEqual(outcome, .rebuilt(inserted: 1, refusedNewcomers: []))
        let root = live()!.root
        XCTAssertEqual(root.splitRatio, 0.7, "restored ratio survives the insert")
        XCTAssertTrue(root.userSetRatio)
        // which side takes window 3 is smart insert's call and depends on the
        // slot sizes; the restored split must still separate 1 from 2.
        XCTAssertEqual(Set(live()!.allWindows.map(\.windowID)), [1, 2, 3])
        XCTAssertTrue(root.left?.allWindows().contains { $0.windowID == 1 } ?? false)
        XCTAssertTrue(root.right?.allWindows().contains { $0.windowID == 2 } ?? false)
    }

    func testDuplicateRefsResolveInLeafOrder() {
        let dup = SavedWindowRef(bundleID: "app.dup", title: "zsh")
        let saved = LayoutNode.split(override: nil, ratio: 0.5, userSet: false, left: .leaf(dup), right: .leaf(dup))
        var queue = ids([5, 3])

        let outcome = engine.rebuildTree(forWorkspace: 1, screen: screen, from: saved,
                                         windows: ids([3, 5]), applyFrames: true) { _ in
            queue.isEmpty ? nil : queue.removeFirst()
        }

        XCTAssertEqual(outcome, .rebuilt(inserted: 0, refusedNewcomers: []))
        XCTAssertEqual(live()!.allWindows.map(\.windowID), [5, 3], "first leaf takes the first window handed out")
    }

    func testWindowResolvedTwiceIsPlacedOnce() {
        let saved = LayoutNode.split(override: nil, ratio: 0.5, userSet: false, left: leaf(1), right: leaf(2))
        let outcome = engine.rebuildTree(forWorkspace: 1, screen: screen, from: saved,
                                         windows: ids([1]), applyFrames: true) { _ in self.windows[1] }
        XCTAssertEqual(outcome, .rebuilt(inserted: 0, refusedNewcomers: []))
        XCTAssertEqual(live()!.allWindows.map(\.windowID), [1])
        XCTAssertTrue(live()!.root.isLeaf)
    }

    func testFloatingWindowIsNeverPlaced() {
        windows[2]!.isFloating = true
        let saved = LayoutNode.split(override: nil, ratio: 0.5, userSet: false, left: leaf(1), right: leaf(2))
        _ = engine.rebuildTree(forWorkspace: 1, screen: screen, from: saved,
                               windows: ids([1, 2]), applyFrames: true, resolve: byID)
        XCTAssertEqual(live()!.allWindows.map(\.windowID), [1])
    }

    // MARK: - guards

    func testSavedDepthBeyondMaxKeepsLiveTree() {
        _ = engine.prepareTileLayout(ids([1, 2]), onWorkspace: 1, screen: screen)
        let before = live()!.structuralFingerprint()
        engine.maxSplitsPerMonitor[screen.localizedName] = 2

        // chain of five leaves → deepest leaf at depth 4
        let deep = LayoutNode.split(override: nil, ratio: 0.5, userSet: false, left: leaf(1),
                  right: .split(override: nil, ratio: 0.5, userSet: false, left: leaf(2),
                  right: .split(override: nil, ratio: 0.5, userSet: false, left: leaf(3),
                  right: .split(override: nil, ratio: 0.5, userSet: false, left: leaf(4), right: leaf(5)))))

        let outcome = engine.rebuildTree(forWorkspace: 1, screen: screen, from: deep,
                                         windows: ids([1, 2, 3, 4, 5]), applyFrames: true, resolve: byID)

        XCTAssertEqual(outcome, .exceedsMaxDepth(4))
        XCTAssertEqual(live()!.structuralFingerprint(), before)
    }

    func testRefusedVerificationKeepsLiveTree() {
        _ = engine.prepareTileLayout(ids([1, 2]), onWorkspace: 1, screen: screen)
        let before = live()!.structuralFingerprint()

        let refusing = makeEngine(refusingWritesFrameSizingIOFactory())
        _ = refusing.prepareTileLayout(ids([1, 2]), onWorkspace: 1, screen: screen)
        let refusingBefore = refusing.existingTree(forWorkspace: 1, screen: screen)!.structuralFingerprint()

        let saved = LayoutNode.split(override: .vertical, ratio: 0.7, userSet: true, left: leaf(1), right: leaf(2))
        let outcome = refusing.rebuildTree(forWorkspace: 1, screen: screen, from: saved,
                                           windows: ids([1, 2]), applyFrames: true, resolve: byID)

        guard case .rejected(let reason) = outcome else { return XCTFail("expected .rejected, got \(outcome)") }
        XCTAssertNotNil(reason)
        XCTAssertEqual(refusing.existingTree(forWorkspace: 1, screen: screen)!.structuralFingerprint(), refusingBefore)
        XCTAssertEqual(live()!.structuralFingerprint(), before, "the accepting engine is untouched")
    }

    func testDeferredFramesPublishWithoutVerification() {
        let refusing = makeEngine(refusingWritesFrameSizingIOFactory())
        let saved = LayoutNode.split(override: .vertical, ratio: 0.7, userSet: true, left: leaf(1), right: leaf(2))

        let outcome = refusing.rebuildTree(forWorkspace: 1, screen: screen, from: saved,
                                           windows: ids([1, 2]), applyFrames: false, resolve: byID)

        XCTAssertEqual(outcome, .rebuilt(inserted: 0, refusedNewcomers: []))
        XCTAssertEqual(refusing.layoutTree(forWorkspace: 1, ref: refOf), saved)
    }

    func testHiddenRebuildMarksGeometryUnverifiedUntilShown() {
        let saved = LayoutNode.split(override: .vertical, ratio: 0.7, userSet: true, left: leaf(1), right: leaf(2))

        let outcome = engine.rebuildTree(forWorkspace: 1, screen: screen, from: saved,
                                         windows: ids([1, 2]), applyFrames: false, resolve: byID)

        XCTAssertEqual(outcome, .rebuilt(inserted: 0, refusedNewcomers: []))
        XCTAssertEqual(engine.unverifiedLayouts.map(\.workspace), [1])
        XCTAssertEqual(engine.unverifiedGeometryWindowIDs, [1, 2])
        XCTAssertNil(engine.intendedTileRects()[1], "parked frames are not the tree's frames")

        // the ordinary show path: an accepted tile clears the mark and keeps the shape
        let shown = engine.tileWindows(ids([1, 2]), onWorkspace: 1, screen: screen)

        XCTAssertNil(shown.failure)
        XCTAssertTrue(engine.unverifiedLayouts.isEmpty)
        XCTAssertNotNil(engine.intendedTileRects()[1])
        XCTAssertEqual(engine.layoutTree(forWorkspace: 1, ref: refOf), saved)
    }

    func testVisibleRebuildLeavesNoUnverifiedMark() {
        let saved = LayoutNode.split(override: nil, ratio: 0.5, userSet: false, left: leaf(1), right: leaf(2))
        _ = engine.rebuildTree(forWorkspace: 1, screen: screen, from: saved,
                               windows: ids([1, 2]), applyFrames: true, resolve: byID)
        XCTAssertTrue(engine.unverifiedLayouts.isEmpty)
    }

    func testEmptyTreeOnOtherScreenForSameWorkspaceIsPruned() {
        let other = RebuildOtherScreen()
        let screens: [NSScreen] = [screen, other]
        displayManager = DisplayManager(screenSource: { screens })
        engine = makeEngine(acceptingFrameSizingIOFactory())

        // ws1 used to live on the other screen; its last window left, the tree stayed
        _ = engine.prepareTileLayout(ids([3]), onWorkspace: 1, screen: other)
        _ = engine.prepareTileLayout([], onWorkspace: 1, screen: other)
        engine.markUnverifiedGeometry(forWorkspace: 1, screen: other, reason: "test")
        XCTAssertEqual(engine.existingTree(forWorkspace: 1, screen: other)?.allWindows.count, 0,
                       "precondition: an empty ws1 tree on the other screen")
        XCTAssertEqual(engine.unverifiedLayouts.count, 1)

        let saved = LayoutNode.split(override: nil, ratio: 0.5, userSet: false, left: leaf(1), right: leaf(2))
        let outcome = engine.rebuildTree(forWorkspace: 1, screen: screen, from: saved,
                                         windows: ids([1, 2]), applyFrames: true, resolve: byID)

        XCTAssertEqual(outcome, .rebuilt(inserted: 0, refusedNewcomers: []))
        XCTAssertNil(engine.existingTree(forWorkspace: 1, screen: other))
        XCTAssertTrue(engine.unverifiedLayouts.isEmpty, "the pruned key takes its mark with it")
        XCTAssertEqual(engine.layoutTree(forWorkspace: 1, ref: refOf), saved)
    }

    func testNonEmptyTreeOnOtherScreenIsKept() {
        let other = RebuildOtherScreen()
        let screens: [NSScreen] = [screen, other]
        displayManager = DisplayManager(screenSource: { screens })
        engine = makeEngine(acceptingFrameSizingIOFactory())
        _ = engine.prepareTileLayout(ids([3]), onWorkspace: 1, screen: other)

        let saved = LayoutNode.split(override: nil, ratio: 0.5, userSet: false, left: leaf(1), right: leaf(2))
        _ = engine.rebuildTree(forWorkspace: 1, screen: screen, from: saved,
                               windows: ids([1, 2]), applyFrames: true, resolve: byID)

        XCTAssertEqual(engine.windowIDs(inTreeForWorkspace: 1, screen: other), [3])
    }

    // MARK: - admitted windows

    /// 2x2 grid at depth 2 naming windows 1–4.
    private var grid: LayoutNode {
        .split(override: .horizontal, ratio: 0.5, userSet: false,
               left: .split(override: .vertical, ratio: 0.5, userSet: false, left: leaf(1), right: leaf(2)),
               right: .split(override: .vertical, ratio: 0.5, userSet: false, left: leaf(3), right: leaf(4)))
    }

    func testRefusedIncumbentRejectsRebuildAndKeepsLiveTree() {
        engine.maxSplitsPerMonitor[screen.localizedName] = 3
        let admitted = engine.tileWindows(ids([1, 2, 3, 4, 5]), onWorkspace: 1, screen: screen)
        XCTAssertEqual(admitted.publishedIDs, [1, 2, 3, 4, 5], "precondition: all five admitted")
        let before = live()!.structuralFingerprint()
        engine.maxSplitsPerMonitor[screen.localizedName] = 2

        // valid at depth 2, but window 5 has nowhere to go
        let outcome = engine.rebuildTree(forWorkspace: 1, screen: screen, from: grid,
                                         windows: ids([1, 2, 3, 4, 5]), applyFrames: true, resolve: byID)

        XCTAssertEqual(outcome, .refusedIncumbents([5]))
        XCTAssertEqual(live()!.structuralFingerprint(), before)
        XCTAssertEqual(Set(live()!.allWindows.map(\.windowID)), [1, 2, 3, 4, 5])
    }

    func testRefusedIncumbentRejectsHiddenRebuildToo() {
        engine.maxSplitsPerMonitor[screen.localizedName] = 3
        _ = engine.tileWindows(ids([1, 2, 3, 4, 5]), onWorkspace: 1, screen: screen)
        let before = live()!.structuralFingerprint()
        engine.maxSplitsPerMonitor[screen.localizedName] = 2

        let outcome = engine.rebuildTree(forWorkspace: 1, screen: screen, from: grid,
                                         windows: ids([1, 2, 3, 4, 5]), applyFrames: false, resolve: byID)

        XCTAssertEqual(outcome, .refusedIncumbents([5]))
        XCTAssertEqual(live()!.structuralFingerprint(), before)
        XCTAssertTrue(engine.unverifiedLayouts.isEmpty, "nothing was published, nothing to verify")
    }

    func testRefusedNewcomerIsReturnedAndTreePublishes() {
        engine.maxSplitsPerMonitor[screen.localizedName] = 2
        _ = engine.tileWindows(ids([1, 2, 3, 4]), onWorkspace: 1, screen: screen)

        let outcome = engine.rebuildTree(forWorkspace: 1, screen: screen, from: grid,
                                         windows: ids([1, 2, 3, 4, 5]), applyFrames: true, resolve: byID)

        XCTAssertEqual(outcome, .rebuilt(inserted: 0, refusedNewcomers: [5]))
        XCTAssertEqual(engine.layoutTree(forWorkspace: 1, ref: refOf), grid)
    }

    func testIncumbentTakesTheFreeSlotBeforeANewcomer() {
        engine.maxSplitsPerMonitor[screen.localizedName] = 2
        _ = engine.tileWindows(ids([1, 2, 3, 4]), onWorkspace: 1, screen: screen)
        // one free slot: leaf 3 at depth 1 can still split
        let saved = LayoutNode.split(
            override: .horizontal, ratio: 0.5, userSet: false,
            left: .split(override: .vertical, ratio: 0.5, userSet: false, left: leaf(1), right: leaf(2)),
            right: leaf(3))

        // newcomer 6 listed first; incumbent 4 must still win the slot
        let outcome = engine.rebuildTree(forWorkspace: 1, screen: screen, from: saved,
                                         windows: ids([6, 1, 2, 3, 4]), applyFrames: true, resolve: byID)

        XCTAssertEqual(outcome, .rebuilt(inserted: 1, refusedNewcomers: [6]))
        XCTAssertEqual(Set(live()!.allWindows.map(\.windowID)), [1, 2, 3, 4])
    }

    func testIncumbentLeftOutOfWindowsIsNotARefusal() {
        // the caller's window list is authoritative, as in tileWindows: a
        // window no longer on the workspace leaves the tree, it is not refused
        _ = engine.tileWindows(ids([1, 2, 3]), onWorkspace: 1, screen: screen)
        let saved = LayoutNode.split(override: nil, ratio: 0.5, userSet: false, left: leaf(1), right: leaf(2))

        let outcome = engine.rebuildTree(forWorkspace: 1, screen: screen, from: saved,
                                         windows: ids([1, 2]), applyFrames: true, resolve: byID)

        XCTAssertEqual(outcome, .rebuilt(inserted: 0, refusedNewcomers: []))
        XCTAssertEqual(live()!.allWindows.map(\.windowID), [1, 2])
    }
}

/// Every write fails, so any verified layout is rejected before readback.
private func refusingWritesFrameSizingIOFactory()
    -> ([CGWindowID: HyprWindow], @escaping () -> UInt64) -> FrameSizingIO {
    { _, generation in
        FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, _, _ in .failure },
            writePosition: { _, _, _ in .failure },
            readPosition: { _, _ in (.success, .zero) },
            readSize: { _, _ in (.success, CGSize(width: 100, height: 100)) },
            now: { 0 }, sleep: { _ in }, currentGeneration: generation
        )
    }
}

private final class RebuildTestScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 2400, height: 1600) }
    override var visibleFrame: NSRect { frame }
}

private final class RebuildOtherScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 2400, y: 0, width: 1920, height: 1080) }
    override var visibleFrame: NSRect { frame }
}
