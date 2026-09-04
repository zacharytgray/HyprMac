import Cocoa
import XCTest
@testable import HyprMac

final class LaunchLayoutReservationTests: XCTestCase {
    private let layout = LayoutEngine(gapSize: 8, outerPadding: 8, minSlotDimension: 500)
    private let rect = CGRect(x: 100, y: 50, width: 1920, height: 1080)

    private func plan(_ tree: BSPTree, maxDepth: Int = 3,
                      incoming: CGSize = .zero,
                      minimumSize: (HyprWindow?) -> CGSize = { _ in .zero }) -> LaunchLayoutPlan? {
        layout.planLaunchReservation(in: tree, maxDepth: maxDepth, rect: rect,
                                     incomingMinimumSize: incoming, minimumSize: minimumSize)
    }

    func testEmptyTreeReservesPaddedRectWithoutPlaceholder() throws {
        let tree = BSPTree()
        let root = tree.root
        let result = try XCTUnwrap(plan(tree))
        XCTAssertEqual(result.reservedFrame, rect.insetBy(dx: 8, dy: 8))
        XCTAssertTrue(result.siblingLayouts.isEmpty)
        XCTAssertTrue(tree.root === root)
        XCTAssertTrue(tree.root.isEmpty)
        XCTAssertTrue(tree.allWindows.isEmpty)
    }

    func testOneWindowReservesRightHalfAndMovesOnlyExistingTenant() throws {
        let tree = BSPTree()
        let window = makeWindow(id: 1)
        tree.insert(window)
        let result = try XCTUnwrap(plan(tree))
        let padded = rect.insetBy(dx: 8, dy: 8)
        let (left, right) = layout.splitRects(padded, dir: .horizontal)
        XCTAssertEqual(result.siblingLayouts.count, 1)
        XCTAssertTrue(result.siblingLayouts[0].0 === window)
        XCTAssertEqual(result.siblingLayouts[0].1, left)
        XCTAssertEqual(result.reservedFrame, right)
        XCTAssertEqual(right.minX - left.maxX, 8)
        XCTAssertTrue(tree.root.window === window)
        XCTAssertNil(tree.root.left)
        XCTAssertNil(tree.root.right)
    }

    func testProposalMatchesOrdinaryInsertionWithKnownZeroMinima() throws {
        let tree = BSPTree()
        for id in 1...3 { tree.insert(makeWindow(id: CGWindowID(id))) }
        tree.root.splitRatio = 0.7
        tree.root.userSetRatio = true
        let result = try XCTUnwrap(plan(tree, maxDepth: 4))
        let incoming = makeWindow(id: 4)
        tree.root.clearUserSetRatios()
        tree.root.resetSplitRatios()
        XCTAssertTrue(layout.smartInsertFitting(incoming, into: tree, maxDepth: 4,
                                                rect: rect, minimumSize: { _ in .zero }))
        let actual = tree.layout(in: rect, gap: 8, padding: 8)
        XCTAssertEqual(actual.count, result.siblingLayouts.count + 1)
        XCTAssertEqual(actual.first(where: { $0.0 === incoming })?.1, result.reservedFrame)
        for (window, frame) in result.siblingLayouts {
            XCTAssertEqual(actual.first(where: { $0.0 === window })?.1, frame)
        }
    }

    func testPlanningRestoresRatiosFlagsOverridesAndTopology() throws {
        let tree = BSPTree()
        for id in 1...3 { tree.insert(makeWindow(id: CGWindowID(id))) }
        let root = tree.root
        let left = try XCTUnwrap(root.left)
        let right = try XCTUnwrap(root.right)
        root.splitRatio = 0.72
        root.userSetRatio = true
        root.splitOverride = .horizontal
        right.splitRatio = 0.3
        right.userSetRatio = true
        right.splitOverride = .vertical
        left.splitOverride = .vertical
        let before = tree.layout(in: rect, gap: 8, padding: 8).map { $0.1 }
        _ = try XCTUnwrap(plan(tree, maxDepth: 4))
        XCTAssertTrue(tree.root === root)
        XCTAssertTrue(root.left === left)
        XCTAssertTrue(root.right === right)
        XCTAssertEqual(root.splitRatio, 0.72)
        XCTAssertTrue(root.userSetRatio)
        XCTAssertEqual(root.splitOverride, .horizontal)
        XCTAssertEqual(right.splitRatio, 0.3)
        XCTAssertTrue(right.userSetRatio)
        XCTAssertEqual(right.splitOverride, .vertical)
        XCTAssertEqual(left.splitOverride, .vertical)
        XCTAssertEqual(tree.allWindows.map(\.windowID), [1, 2, 3])
        XCTAssertEqual(tree.layout(in: rect, gap: 8, padding: 8).map { $0.1 }, before)
    }

    func testLeafOverrideIsNotInheritedByTheProposedSplit() throws {
        let tree = BSPTree()
        tree.insert(makeWindow(id: 1))
        tree.root.splitOverride = .vertical
        let result = try XCTUnwrap(plan(tree))
        let (_, right) = layout.splitRects(rect.insetBy(dx: 8, dy: 8), dir: .horizontal)
        XCTAssertEqual(result.reservedFrame, right)
        XCTAssertEqual(tree.root.splitOverride, .vertical)
    }

    func testDepthLimitFailsWithoutChangingTree() {
        let tree = BSPTree()
        tree.insert(makeWindow(id: 1))
        tree.insert(makeWindow(id: 2))
        tree.root.splitRatio = 0.7
        tree.root.userSetRatio = true
        XCTAssertNil(plan(tree, maxDepth: 1))
        XCTAssertEqual(tree.root.splitRatio, 0.7)
        XCTAssertTrue(tree.root.userSetRatio)
        XCTAssertEqual(tree.allWindows.map(\.windowID), [1, 2])
    }

    func testIncomingMinimumMustFitActualMidpointSlot() {
        let tree = BSPTree()
        tree.insert(makeWindow(id: 1))
        // 1000px could fit with an unequal ratio, not in this 948px slot.
        XCTAssertNil(plan(tree, incoming: CGSize(width: 1000, height: 200)))
        XCTAssertEqual(tree.allWindows.map(\.windowID), [1])
        XCTAssertTrue(tree.root.isLeaf)
    }

    func testExistingTenantMinimumMustFitActualMidpointSlot() {
        let tree = BSPTree()
        tree.insert(makeWindow(id: 1))
        XCTAssertNil(plan(tree, minimumSize: { _ in CGSize(width: 1000, height: 200) }))
        XCTAssertTrue(tree.root.isLeaf)
    }

    func testEverySiblingIsValidatedAfterRatioNormalization() {
        let tree = BSPTree()
        tree.insert(makeWindow(id: 1))
        tree.insert(makeWindow(id: 2))
        tree.root.splitRatio = 0.7
        tree.root.userSetRatio = true
        // The new leaf would be in the right branch, but resetting root's
        // 70/30 ratio also shrinks the unrelated left sibling below its min.
        XCTAssertNil(plan(tree, minimumSize: { window in
            window?.windowID == 1 ? CGSize(width: 1200, height: 200) : .zero
        }))
        XCTAssertEqual(tree.root.splitRatio, 0.7)
        XCTAssertTrue(tree.root.userSetRatio)
    }

    func testEmptyTreeRejectsOversizedOrInvalidIncomingMinimum() {
        let tree = BSPTree()
        XCTAssertNil(plan(tree, incoming: CGSize(width: 2000, height: 100)))
        XCTAssertNil(plan(tree, incoming: CGSize(width: CGFloat.infinity, height: 100)))
        XCTAssertNil(plan(tree, incoming: CGSize(width: CGFloat.nan, height: 100)))
        XCTAssertNil(plan(tree, incoming: CGSize(width: -1, height: 100)))
        XCTAssertTrue(tree.root.isEmpty)
    }

    func testPaddingAndGapsCannotProduceNonpositiveSlots() {
        let tree = BSPTree()
        tree.insert(makeWindow(id: 1))
        let tiny = CGRect(x: 0, y: 0, width: 20, height: 20)
        XCTAssertNil(layout.planLaunchReservation(in: tree, maxDepth: 3, rect: tiny,
                                                  incomingMinimumSize: .zero,
                                                  minimumSize: { _ in .zero }))
        XCTAssertTrue(tree.root.isLeaf)
    }
}
