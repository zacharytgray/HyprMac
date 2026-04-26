import XCTest
import Cocoa
@testable import HyprMac

// pins the behavior of TilingEngine.forceInsertWindow at Tiling/TilingEngine.swift:751-775.
// of particular interest is the path-B fallback: when smartInsertFitting still fails after
// eviction, the evicted window is reinserted via plain BSPTree.insert (not smartInsertFitting),
// and the new window is dropped. plan §4.2 + §8.2.

final class ForceInsertWindowFallbackTests: XCTestCase {

    private var displayManager: DisplayManager!
    private var engine: TilingEngine!
    private var screen: NSScreen!

    override func setUpWithError() throws {
        displayManager = DisplayManager()
        engine = TilingEngine(displayManager: displayManager)
        // tests need a real NSScreen — skip if the test runner has none (headless CI).
        guard let main = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("no NSScreen available — test requires a display")
        }
        screen = main
    }

    private func tree() -> BSPTree? {
        engine.existingTree(forWorkspace: 1, screen: screen)
    }

    // MARK: - empty tree

    func testForceInsertOnEmptyTreeFillsRoot() {
        let w = makeWindow(id: 1)
        let evicted = engine.forceInsertWindow(w, toWorkspace: 1, on: screen)
        XCTAssertNil(evicted)
        XCTAssertEqual(tree()?.allWindows.map(\.windowID), [1])
        XCTAssertTrue(tree()?.root.isLeaf ?? false)
    }

    // MARK: - already in tree

    func testForceInsertAlreadyContainedReturnsNilAndDoesNothing() {
        let w = makeWindow(id: 1)
        engine.forceInsertWindow(w, toWorkspace: 1, on: screen)
        XCTAssertEqual(tree()?.allWindows.count, 1)

        let evicted = engine.forceInsertWindow(w, toWorkspace: 1, on: screen)
        XCTAssertNil(evicted)
        XCTAssertEqual(tree()?.allWindows.map(\.windowID), [1])
    }

    // MARK: - primary path: smartInsertFitting succeeds

    func testForceInsertSucceedsWithoutEvictionWhenSpaceAllows() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        engine.forceInsertWindow(w1, toWorkspace: 1, on: screen)

        let evicted = engine.forceInsertWindow(w2, toWorkspace: 1, on: screen)
        XCTAssertNil(evicted)
        XCTAssertEqual(Set(tree()?.allWindows.map(\.windowID) ?? []), [1, 2])
    }

    // MARK: - path A: smartInsertFitting succeeds after eviction

    func testForceInsertEvictsAndReinsertsWhenAtMaxDepth() {
        // shrink maxDepth to force the smartInsertFitting precondition (depth < maxDepth) to fail.
        // with maxDepth=1, tree fills at 2 leaves (depth 1 each); a 3rd insert via
        // smartInsertFitting fails the depth check, triggering eviction.
        engine.maxSplitsPerMonitor[screen.localizedName] = 1

        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        engine.forceInsertWindow(w1, toWorkspace: 1, on: screen)
        engine.forceInsertWindow(w2, toWorkspace: 1, on: screen)
        XCTAssertEqual(tree()?.allWindows.count, 2)

        // evict and reinsert path: w2 (deepest-right) is evicted, w3 takes its slot.
        let evicted = engine.forceInsertWindow(w3, toWorkspace: 1, on: screen)
        XCTAssertEqual(evicted?.windowID, 2)
        XCTAssertEqual(Set(tree()?.allWindows.map(\.windowID) ?? []), [1, 3])
    }

    // MARK: - path B: smartInsertFitting STILL fails after eviction

    func testForceInsertFallbackReinsertsEvictedViaPlainInsertWhenIncomingDoesNotFit() {
        // path B at TilingEngine.swift:772 — even after eviction, smartInsertFitting
        // can fail when the incoming window's min-size exceeds available rect.
        // current behavior: evicted is reinserted via plain BSPTree.insert (NOT
        // smartInsertFitting), and the new window is dropped (returns nil).
        // pinned because the plan flags this as a deliberate shape choice (§4.2).
        engine.maxSplitsPerMonitor[screen.localizedName] = 1

        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        engine.forceInsertWindow(w1, toWorkspace: 1, on: screen)
        engine.forceInsertWindow(w2, toWorkspace: 1, on: screen)
        XCTAssertEqual(tree()?.allWindows.count, 2)

        // make w3's min-size impossibly large so pairFits fails for every leaf.
        let w3 = makeWindow(id: 3)
        w3.observedMinSize = CGSize(width: 100_000, height: 100_000)

        let evicted = engine.forceInsertWindow(w3, toWorkspace: 1, on: screen)

        // path B: evicted reinserted, new window dropped.
        XCTAssertNil(evicted)
        XCTAssertEqual(Set(tree()?.allWindows.map(\.windowID) ?? []), [1, 2])
        XCTAssertFalse(tree()?.contains(w3) ?? true)
    }
}
