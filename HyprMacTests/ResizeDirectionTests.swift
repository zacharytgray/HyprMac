import XCTest
import Cocoa
@testable import HyprMac

final class ResizeDirectionTests: XCTestCase {

    private var displayManager: DisplayManager!
    private var engine: TilingEngine!
    private var screen: NSScreen!

    override func setUpWithError() throws {
        displayManager = DisplayManager()
        engine = TilingEngine(displayManager: displayManager)
        guard let main = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("no NSScreen available — test requires a display")
        }
        screen = main
    }

    // MARK: - horizontal resize

    func testResizeRightIncreasesRatio() {
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        _ = engine.prepareTileLayout([a, b], onWorkspace: 1, screen: screen)

        let tree = engine.existingTree(forWorkspace: 1, screen: screen)!
        let ratioBefore = tree.root.splitRatio

        engine.resizeInDirection(a, direction: .right, onWorkspace: 1, screen: screen)

        XCTAssertGreaterThan(tree.root.splitRatio, ratioBefore)
        XCTAssertTrue(tree.root.userSetRatio)
    }

    func testResizeLeftDecreasesRatio() {
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        _ = engine.prepareTileLayout([a, b], onWorkspace: 1, screen: screen)

        let tree = engine.existingTree(forWorkspace: 1, screen: screen)!
        let ratioBefore = tree.root.splitRatio

        engine.resizeInDirection(a, direction: .left, onWorkspace: 1, screen: screen)

        XCTAssertLessThan(tree.root.splitRatio, ratioBefore)
        XCTAssertTrue(tree.root.userSetRatio)
    }

    func testResizeStepSize() {
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        _ = engine.prepareTileLayout([a, b], onWorkspace: 1, screen: screen)

        let tree = engine.existingTree(forWorkspace: 1, screen: screen)!

        engine.resizeInDirection(a, direction: .right, onWorkspace: 1, screen: screen)

        XCTAssertEqual(tree.root.splitRatio, 0.55, accuracy: 0.001,
                       "resize step should be 0.05")
    }

    // MARK: - right child resize

    func testRightChildResizeRightGrowsRightChild() {
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        _ = engine.prepareTileLayout([a, b], onWorkspace: 1, screen: screen)

        let tree = engine.existingTree(forWorkspace: 1, screen: screen)!
        let ratioBefore = tree.root.splitRatio

        engine.resizeInDirection(b, direction: .right, onWorkspace: 1, screen: screen)

        XCTAssertLessThan(tree.root.splitRatio, ratioBefore,
                          "right child pressing right should decrease ratio (grow right child)")
    }

    func testRightChildResizeLeftShrinksRightChild() {
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        _ = engine.prepareTileLayout([a, b], onWorkspace: 1, screen: screen)

        let tree = engine.existingTree(forWorkspace: 1, screen: screen)!
        let ratioBefore = tree.root.splitRatio

        engine.resizeInDirection(b, direction: .left, onWorkspace: 1, screen: screen)

        XCTAssertGreaterThan(tree.root.splitRatio, ratioBefore,
                             "right child pressing left should increase ratio (shrink right child)")
    }

    // MARK: - axis matching

    func testResizeWalksUpPastMismatchedAxis() {
        // three windows: c's parent split is forced vertical, the root
        // horizontal. a horizontal resize on c must skip the parent and
        // adjust the root instead.
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        let c = makeWindow(id: 3)
        _ = engine.prepareTileLayout([a, b, c], onWorkspace: 1, screen: screen)

        let tree = engine.existingTree(forWorkspace: 1, screen: screen)!
        guard let leaf = tree.root.find(c), let parent = leaf.parent, parent !== tree.root else {
            XCTFail("expected c under a non-root split"); return
        }
        tree.root.splitOverride = .horizontal
        parent.splitOverride = .vertical
        let parentRatioBefore = parent.splitRatio
        let rootRatioBefore = tree.root.splitRatio
        let cIsInLeftSubtree = tree.root.left === parent

        engine.resizeInDirection(c, direction: .right, onWorkspace: 1, screen: screen)

        XCTAssertEqual(parent.splitRatio, parentRatioBefore, accuracy: 0.001,
                       "mismatched-axis parent must be left alone")
        XCTAssertFalse(parent.userSetRatio)
        if cIsInLeftSubtree {
            XCTAssertGreaterThan(tree.root.splitRatio, rootRatioBefore)
        } else {
            XCTAssertLessThan(tree.root.splitRatio, rootRatioBefore)
        }
        XCTAssertTrue(tree.root.userSetRatio)
    }

    func testPerpendicularResizeWithNoMatchingAncestorIsNoop() {
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        _ = engine.prepareTileLayout([a, b], onWorkspace: 1, screen: screen)

        let tree = engine.existingTree(forWorkspace: 1, screen: screen)!
        tree.root.splitOverride = .horizontal
        let ratioBefore = tree.root.splitRatio

        engine.resizeInDirection(a, direction: .up, onWorkspace: 1, screen: screen)

        XCTAssertEqual(tree.root.splitRatio, ratioBefore, accuracy: 0.001)
        XCTAssertFalse(tree.root.userSetRatio)
    }

    // MARK: - clamping

    func testResizeRespectsClamping() {
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        _ = engine.prepareTileLayout([a, b], onWorkspace: 1, screen: screen)

        let tree = engine.existingTree(forWorkspace: 1, screen: screen)!

        // push ratio to the upper clamp
        for _ in 0..<20 {
            engine.resizeInDirection(a, direction: .right, onWorkspace: 1, screen: screen)
        }
        XCTAssertLessThanOrEqual(tree.root.splitRatio, 0.85,
                                 "ratio should be clamped at 0.85")

        // push ratio to the lower clamp
        for _ in 0..<30 {
            engine.resizeInDirection(a, direction: .left, onWorkspace: 1, screen: screen)
        }
        XCTAssertGreaterThanOrEqual(tree.root.splitRatio, 0.15,
                                    "ratio should be clamped at 0.15")
    }

    // MARK: - no-op on missing window

    func testResizeUnknownWindowIsNoop() {
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        _ = engine.prepareTileLayout([a, b], onWorkspace: 1, screen: screen)

        let tree = engine.existingTree(forWorkspace: 1, screen: screen)!
        let ratioBefore = tree.root.splitRatio

        let stranger = makeWindow(id: 99)
        engine.resizeInDirection(stranger, direction: .right, onWorkspace: 1, screen: screen)

        XCTAssertEqual(tree.root.splitRatio, ratioBefore, accuracy: 0.001)
    }

    // MARK: - vertical split

    func testVerticalSplitTopChildDownGrowsTopChild() {
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        _ = engine.prepareTileLayout([a, b], onWorkspace: 1, screen: screen)

        let tree = engine.existingTree(forWorkspace: 1, screen: screen)!
        tree.root.splitOverride = .vertical
        let ratioBefore = tree.root.splitRatio

        // a is the top child; down grows it, up shrinks it
        engine.resizeInDirection(a, direction: .down, onWorkspace: 1, screen: screen)
        XCTAssertGreaterThan(tree.root.splitRatio, ratioBefore)
        XCTAssertTrue(tree.root.userSetRatio)

        engine.resizeInDirection(a, direction: .up, onWorkspace: 1, screen: screen)
        XCTAssertEqual(tree.root.splitRatio, ratioBefore, accuracy: 0.001)
    }

    func testVerticalSplitBottomChildDownGrowsBottomChild() {
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        _ = engine.prepareTileLayout([a, b], onWorkspace: 1, screen: screen)

        let tree = engine.existingTree(forWorkspace: 1, screen: screen)!
        tree.root.splitOverride = .vertical
        let ratioBefore = tree.root.splitRatio

        // b is the bottom child; down grows it (ratio drops), up shrinks it
        engine.resizeInDirection(b, direction: .down, onWorkspace: 1, screen: screen)
        XCTAssertLessThan(tree.root.splitRatio, ratioBefore,
                          "bottom child pressing down should decrease ratio (grow bottom child)")

        engine.resizeInDirection(b, direction: .up, onWorkspace: 1, screen: screen)
        XCTAssertEqual(tree.root.splitRatio, ratioBefore, accuracy: 0.001)
    }

    func testHorizontalResizeOnVerticalSplitIsNoop() {
        let a = makeWindow(id: 1)
        let b = makeWindow(id: 2)
        _ = engine.prepareTileLayout([a, b], onWorkspace: 1, screen: screen)

        let tree = engine.existingTree(forWorkspace: 1, screen: screen)!
        tree.root.splitOverride = .vertical
        let ratioBefore = tree.root.splitRatio

        engine.resizeInDirection(a, direction: .right, onWorkspace: 1, screen: screen)
        XCTAssertEqual(tree.root.splitRatio, ratioBefore, accuracy: 0.001)
        XCTAssertFalse(tree.root.userSetRatio)
    }

    // MARK: - defaults coverage

    func testDefaultsContainAllResizeDirections() {
        var dirs: Set<Direction> = []
        for kb in Keybind.defaults {
            if case .resizeDirection(let d) = kb.action { dirs.insert(d) }
        }
        XCTAssertEqual(dirs, Set([.left, .right, .up, .down]))
    }

    func testResizeDirectionActionRoundTrips() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for dir in [Direction.left, .right, .up, .down] {
            let kb = Keybind(keyCode: 123, modifiers: .hypr, action: .resizeDirection(dir))
            let data = try encoder.encode(kb)
            let decoded = try decoder.decode(Keybind.self, from: data)
            XCTAssertEqual(decoded.action, kb.action)
        }
    }
}
