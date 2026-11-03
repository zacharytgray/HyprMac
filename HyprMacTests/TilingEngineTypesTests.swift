import XCTest
@testable import HyprMac

final class LayoutTreeCodecTests: XCTestCase {
    private func ref(_ title: String) -> SavedWindowRef { SavedWindowRef(bundleID: "app", title: title) }

    private func pair(_ a: CGWindowID, _ b: CGWindowID) -> BSPNode {
        let root = BSPNode()
        let left = BSPNode(window: makeWindow(id: a)), right = BSPNode(window: makeWindow(id: b))
        root.left = left; root.right = right
        left.parent = root; right.parent = root
        return root
    }

    func testSerializedShapeBuildsBackWithItsRatioAndOverride() throws {
        let root = pair(1, 2)
        root.splitRatio = 0.3
        root.userSetRatio = true
        root.splitOverride = .vertical
        let saved = try XCTUnwrap(LayoutTreeCodec.serialize(root, keeping: []) { self.ref("\($0.windowID)") })

        let windows: [String: HyprWindow] = ["1": makeWindow(id: 1), "2": makeWindow(id: 2)]
        let built = try XCTUnwrap(LayoutTreeCodec.build(saved) { windows[$0.title] })
        XCTAssertFalse(built === root, "a fresh node")
        XCTAssertEqual(built.splitRatio, 0.3, accuracy: 0.001)
        XCTAssertTrue(built.userSetRatio)
        XCTAssertEqual(built.splitOverride, .vertical)
        XCTAssertEqual(built.left?.window?.windowID, 1)
        XCTAssertEqual(built.right?.window?.windowID, 2)
        XCTAssertTrue(built.left?.parent === built)
    }

    func testAWindowWithNoRefCollapsesItsSplit() {
        let root = pair(1, 2)
        let saved = LayoutTreeCodec.serialize(root, keeping: []) { $0.windowID == 1 ? nil : self.ref("2") }
        XCTAssertEqual(saved, .leaf(ref("2")))
        XCTAssertNil(LayoutTreeCodec.serialize(root, keeping: []) { _ in nil })
    }

    func testAMissingWindowCollapsesOnBuild() {
        let saved = LayoutNode.split(override: nil, ratio: 0.5, userSet: false, left: .leaf(ref("1")), right: .leaf(ref("2")))
        let window = makeWindow(id: 2)
        let built = LayoutTreeCodec.build(saved) { $0.title == "2" ? window : nil }
        XCTAssertEqual(built?.window?.windowID, 2)
        XCTAssertNil(LayoutTreeCodec.build(saved) { _ in nil })
    }

    func testAnAutomaticAxisIsLeftOutUnlessItIsAFallbackPin() throws {
        let root = pair(1, 2)
        root.splitOverride = .horizontal
        root.splitOverrideIsAutomatic = true
        func override(_ node: LayoutNode?) -> SplitDirection? {
            if case let .split(override, _, _, _, _) = node { return override }
            return nil
        }
        XCTAssertNil(override(LayoutTreeCodec.serialize(root, keeping: []) { self.ref("\($0.windowID)") }))
        XCTAssertEqual(override(LayoutTreeCodec.serialize(root, keeping: [ObjectIdentifier(root)]) { self.ref("\($0.windowID)") }),
                       .horizontal)
    }
}

final class PassBudgetTests: XCTestCase {
    private let budget = PassBudget(started: 100)

    func testTheCandidateNeverGetsLessThanTheFloor() {
        XCTAssertEqual(budget.forCandidate(at: 100), PassBudget.total)
        XCTAssertEqual(budget.forCandidate(at: 100 + PassBudget.total + 5), PassBudget.floor)
    }

    func testALaterPassGetsWhatIsLeftOrDoesNotStart() {
        XCTAssertEqual(budget.forLaterPass(at: 100.5), PassBudget.total - 0.5)
        XCTAssertEqual(budget.forLaterPass(at: 100 + PassBudget.total - PassBudget.floor), PassBudget.floor)
        XCTAssertNil(budget.forLaterPass(at: 100 + PassBudget.total - PassBudget.floor + 0.01))
    }
}

final class RollbackPlanTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let inside = CGRect(x: 10, y: 10, width: 100, height: 100)
    private let elsewhere = CGRect(x: 2000, y: 0, width: 100, height: 100)

    private func plan(_ frames: [CGWindowID: CGRect], newcomers: Set<CGWindowID> = []) -> RollbackPlan {
        .make(originalFrames: frames, newcomerIDs: newcomers, restorationFrame: rect, slack: 2)
    }

    func testEveryoneInsideGoesBack() {
        XCTAssertEqual(plan([1: inside, 2: inside]), .restore(leavingInPlace: []))
    }

    func testANewcomerFromElsewhereStaysAndTheIncumbentsGoBack() {
        XCTAssertEqual(plan([1: inside, 2: elsewhere], newcomers: [2]), .restore(leavingInPlace: [2]))
    }

    func testANewcomerWhoseOriginalIsOnTheRectGoesBack() {
        XCTAssertEqual(plan([2: inside], newcomers: [2]), .restore(leavingInPlace: []))
    }

    func testAnIncumbentOffTheRectRefusesTheLowestID() {
        XCTAssertEqual(plan([5: elsewhere, 3: elsewhere, 1: inside]), .refused(invalidOriginalID: 3))
    }

    func testAPointOverTheEdgeWithinTheSlackStillGoesBack() {
        let over = CGRect(x: 0, y: 701, width: 100, height: 100)
        XCTAssertEqual(plan([1: over]), .restore(leavingInPlace: []))
        let tooFar = CGRect(x: 0, y: 703, width: 100, height: 100)
        XCTAssertEqual(plan([1: tooFar]), .refused(invalidOriginalID: 1))
    }

    func testANewcomerNotCapturedIsNotLeftInPlace() {
        XCTAssertEqual(plan([1: inside], newcomers: [9]), .restore(leavingInPlace: []))
    }
}

final class CrossScreenWriteOrderDecisionTests: XCTestCase {
    private let source = CrossScreenWriteOrder.Source(
        name: "panel", fullFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        usableFrame: CGRect(x: 0, y: 38, width: 1512, height: 944))
    private let onScreen = CGRect(x: 100, y: 100, width: 800, height: 600)

    private func describe(_ original: CGRect, _ size: CGSize, source: CrossScreenWriteOrder.Source?) -> String {
        CrossScreenWriteOrder.decide(from: original, targetSize: size, source: source, sizeSlack: 2).description
    }

    func testATargetThatFitsTheSourceIsSizedThere() {
        XCTAssertEqual(describe(onScreen, CGSize(width: 1000, height: 900), source: source),
                       "size-first (fits source panel)")
    }

    func testATargetBiggerThanTheSourceMovesFirst() {
        XCTAssertEqual(describe(onScreen, CGSize(width: 1080, height: 1800), source: source),
                       "position-first (does not fit source panel)")
    }

    func testNoScreenOrASliverCountsAsParked() {
        XCTAssertEqual(describe(onScreen, CGSize(width: 100, height: 100), source: nil), "position-first (parked)")
        let sliver = CGRect(x: 1511, y: 900, width: 800, height: 600)
        XCTAssertEqual(describe(sliver, CGSize(width: 100, height: 100), source: source), "position-first (parked)")
    }
}

final class NewcomerRefusalTests: XCTestCase {
    private let incumbent = makeWindow(id: 1), small = makeWindow(id: 2), big = makeWindow(id: 3)
    private lazy var floors: [CGWindowID: CGSize] = [
        1: CGSize(width: 100, height: 100), 2: CGSize(width: 200, height: 200), 3: CGSize(width: 500, height: 500)]

    private func choose(_ judged: [HyprWindow], newcomers: Set<CGWindowID>, fits: ([HyprWindow]) -> Bool) -> Set<CGWindowID>? {
        NewcomerRefusal.choose(judged, newcomers: newcomers, minimumSize: { self.floors[$0.windowID] ?? .zero }, fits: fits)
    }

    func testEverythingFittingDropsNothing() {
        XCTAssertEqual(choose([incumbent, small], newcomers: [2]) { _ in true }, [])
    }

    func testDropsTheNewcomerWhoseRemovalMakesTheRestFit() {
        // leaving out the small one is what fits, though the big one has the bigger floor
        let fits: ([HyprWindow]) -> Bool = { !$0.contains { $0.windowID == 2 } }
        XCTAssertEqual(choose([incumbent, small, big], newcomers: [2, 3], fits: fits), [2])
    }

    func testElseDropsTheBiggestFloorFirstAndRepeats() {
        let fits: ([HyprWindow]) -> Bool = { $0.count <= 2 }
        let extra = makeWindow(id: 4)
        XCTAssertEqual(choose([incumbent, small, big, extra], newcomers: [2, 3, 4]) { fits($0) && !$0.contains { $0.windowID == 3 } }, [3, 2])
    }

    func testNilWhenNoNewcomerWouldBeLeft() {
        XCTAssertNil(choose([incumbent, small], newcomers: [2]) { $0.count == 1 })
        XCTAssertNil(choose([incumbent], newcomers: []) { _ in false }, "only incumbents, none to drop")
    }
}

final class GeometryLedgerTests: XCTestCase {
    private var ledger = GeometryLedger<String>()

    func testAMarkFoldsAndAFailedRollbackNeverRecovers() {
        ledger.mark("a", windowIDs: [1], insertedIDs: [], restored: true)
        ledger.mark("a", windowIDs: [2], insertedIDs: [2], restored: false)
        ledger.mark("a", windowIDs: [3], insertedIDs: [], restored: true)
        let record = ledger.unverifiedRecord(for: "a")
        XCTAssertEqual(record?.windowIDs, [1, 2, 3])
        XCTAssertEqual(record?.insertedIDs, [2])
        XCTAssertEqual(record?.restorationVerifiedThroughout, false)
    }

    func testClearIfRestoredKeepsAKeyAFailedRollbackMarked() {
        ledger.mark("bad", windowIDs: [1], insertedIDs: [], restored: false)
        ledger.mark("good", windowIDs: [1], insertedIDs: [], restored: true)
        XCTAssertFalse(ledger.clearUnverifiedIfRestored("bad"))
        XCTAssertTrue(ledger.isUnverified("bad"))
        XCTAssertTrue(ledger.clearUnverifiedIfRestored("good"))
        XCTAssertFalse(ledger.isUnverified("good"))
        XCTAssertTrue(ledger.clearUnverifiedIfRestored("none"), "no mark counts as cleared")
    }

    func testClearIfRestoredLeavesTheVacatedMark() {
        ledger.noteVacated("a")
        ledger.mark("a", windowIDs: [1], insertedIDs: [], restored: true)
        _ = ledger.clearUnverifiedIfRestored("a")
        XCTAssertTrue(ledger.isVacated("a"))
    }

    func testClearTakesBothMarks() {
        ledger.noteVacated("a")
        ledger.mark("a", windowIDs: [1], insertedIDs: [], restored: true)
        ledger.clear("a")
        XCTAssertFalse(ledger.isVacated("a"))
        XCTAssertFalse(ledger.isUnverified("a"))
    }

    func testMarksFollowTheTreeAndFoldIntoTheNewKey() {
        ledger.noteVacated("old")
        ledger.mark("old", windowIDs: [1], insertedIDs: [1], restored: true)
        ledger.mark("new", windowIDs: [2], insertedIDs: [], restored: false)
        ledger.carry(from: "old", to: "new")
        XCTAssertFalse(ledger.isUnverified("old"))
        XCTAssertFalse(ledger.isVacated("old"))
        XCTAssertTrue(ledger.isVacated("new"))
        XCTAssertEqual(ledger.unverifiedRecord(for: "new")?.windowIDs, [1, 2])
        XCTAssertEqual(ledger.unverifiedRecord(for: "new")?.restorationVerifiedThroughout, false)
    }

    func testCarryWithNoMarksLeavesTheNewKeyAlone() {
        ledger.carry(from: "old", to: "new")
        XCTAssertFalse(ledger.isUnverified("new"))
        XCTAssertFalse(ledger.isVacated("new"))
    }

    func testPruneKeepsOnlyLiveKeys() {
        ledger.noteVacated("a"); ledger.noteVacated("b")
        ledger.mark("a", windowIDs: [], insertedIDs: [], restored: true)
        ledger.mark("b", windowIDs: [], insertedIDs: [], restored: true)
        ledger.prune { $0 == "a" }
        XCTAssertEqual(ledger.unverifiedKeys, ["a"])
        XCTAssertFalse(ledger.isVacated("b"))
    }
}
