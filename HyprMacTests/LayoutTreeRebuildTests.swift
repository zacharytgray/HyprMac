import XCTest
import Cocoa
@testable import HyprMac

// LayoutTreeRebuildTests pin TilingEngine.rebuildTree — the only path that
// turns a saved LayoutNode back into a live BSP tree. A rebuilt tree must
// serialise back to exactly what went in (shape, overrides, ratios,
// user-set flags), a leaf without a window must collapse its split the way
// a close would, windows the snapshot never named must insert around the
// restored shape, and a refused verification must leave the live tree alone.

final class LayoutTreeRebuildTests: XCTestCase {

    private var engine: TilingEngine!
    private var screen: NSScreen!
    private var windows: [CGWindowID: HyprWindow] = [:]

    override func setUpWithError() throws {
        guard let main = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("no NSScreen available — test requires a display")
        }
        screen = main
        engine = makeEngine(acceptingFrameSizingIOFactory())
        windows = Dictionary(uniqueKeysWithValues: (1...6).map { ($0, makeWindow(id: $0)) })
    }

    private func makeEngine(_ io: @escaping ([CGWindowID: HyprWindow], @escaping () -> UInt64) -> FrameSizingIO) -> TilingEngine {
        TilingEngine(displayManager: DisplayManager(), frameSizingIOFactory: io)
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

        XCTAssertEqual(outcome, .rebuilt(inserted: 0))
        XCTAssertEqual(engine.layoutTree(forWorkspace: 1, ref: refOf), grid)
    }

    func testDwindleChainFromLiveEngineRoundTrips() {
        // shape produced by the real insert path on one engine, restored on another
        _ = engine.prepareTileLayout(ids([1, 2, 3]), onWorkspace: 1, screen: screen)
        let saved = engine.layoutTree(forWorkspace: 1, ref: refOf)!

        let other = makeEngine(acceptingFrameSizingIOFactory())
        let outcome = other.rebuildTree(forWorkspace: 1, screen: screen, from: saved,
                                        windows: ids([1, 2, 3]), applyFrames: true, resolve: byID)

        XCTAssertEqual(outcome, .rebuilt(inserted: 0))
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

        XCTAssertEqual(outcome, .rebuilt(inserted: 0))
        XCTAssertEqual(engine.layoutTree(forWorkspace: 1, ref: refOf),
                       .split(override: nil, ratio: 0.6, userSet: true, left: leaf(1), right: leaf(3)))
    }

    func testAllWindowsMissingLeavesEmptyPublishedTree() {
        let saved = LayoutNode.split(override: nil, ratio: 0.5, userSet: false, left: leaf(1), right: leaf(2))
        let outcome = engine.rebuildTree(forWorkspace: 1, screen: screen, from: saved,
                                         windows: [], applyFrames: true, resolve: byID)
        XCTAssertEqual(outcome, .rebuilt(inserted: 0))
        XCTAssertNil(engine.layoutTree(forWorkspace: 1, ref: refOf))
    }

    func testUnnamedWindowInsertsAroundRestoredShape() {
        let saved = LayoutNode.split(override: nil, ratio: 0.7, userSet: true, left: leaf(1), right: leaf(2))

        let outcome = engine.rebuildTree(forWorkspace: 1, screen: screen, from: saved,
                                         windows: ids([1, 2, 3]), applyFrames: true, resolve: byID)

        XCTAssertEqual(outcome, .rebuilt(inserted: 1))
        let root = live()!.root
        XCTAssertEqual(root.splitRatio, 0.7, "restored ratio survives the insert")
        XCTAssertTrue(root.userSetRatio)
        XCTAssertEqual(live()!.allWindows.map(\.windowID), [1, 2, 3])
    }

    func testDuplicateRefsResolveInLeafOrder() {
        let dup = SavedWindowRef(bundleID: "app.dup", title: "zsh")
        let saved = LayoutNode.split(override: nil, ratio: 0.5, userSet: false, left: .leaf(dup), right: .leaf(dup))
        var queue = ids([5, 3])

        let outcome = engine.rebuildTree(forWorkspace: 1, screen: screen, from: saved,
                                         windows: ids([3, 5]), applyFrames: true) { _ in
            queue.isEmpty ? nil : queue.removeFirst()
        }

        XCTAssertEqual(outcome, .rebuilt(inserted: 0))
        XCTAssertEqual(live()!.allWindows.map(\.windowID), [5, 3], "first leaf takes the first window handed out")
    }

    func testWindowResolvedTwiceIsPlacedOnce() {
        let saved = LayoutNode.split(override: nil, ratio: 0.5, userSet: false, left: leaf(1), right: leaf(2))
        let outcome = engine.rebuildTree(forWorkspace: 1, screen: screen, from: saved,
                                         windows: ids([1]), applyFrames: true) { _ in self.windows[1] }
        XCTAssertEqual(outcome, .rebuilt(inserted: 0))
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

        XCTAssertEqual(outcome, .rebuilt(inserted: 0))
        XCTAssertEqual(refusing.layoutTree(forWorkspace: 1, ref: refOf), saved)
    }

    func testEmptyTreeOnOtherScreenForSameWorkspaceIsPruned() {
        _ = engine.prepareTileLayout(ids([1, 2]), onWorkspace: 1, screen: screen)
        let saved = LayoutNode.split(override: nil, ratio: 0.5, userSet: false, left: leaf(1), right: leaf(2))
        _ = engine.rebuildTree(forWorkspace: 1, screen: screen, from: saved,
                               windows: ids([1, 2]), applyFrames: true, resolve: byID)
        XCTAssertNotNil(live())
        XCTAssertEqual(engine.layoutTree(forWorkspace: 1, ref: refOf), saved)
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
