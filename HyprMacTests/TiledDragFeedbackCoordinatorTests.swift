import XCTest
@testable import HyprMac

final class TiledDragFeedbackCoordinatorTests: XCTestCase {
    private var generation: UInt64 = 1
    private var shown: [CGWindowID] = []
    private var cancelled: [Int] = []
    private var beeps = 0
    private var nextToken: Int? = 500

    private func coordinator() -> TiledDragFeedbackCoordinator {
        TiledDragFeedbackCoordinator(
            currentGeneration: { [unowned self] in self.generation },
            displayID: { _ in 0 },
            screens: { [] },
            windowIDsOnWorkspace: { _ in [] },
            workspaceFor: { _ in nil },
            isFloating: { _ in false },
            allWindows: { [] },
            isAwaitingRetry: { _ in false },
            hasActiveRetry: { _, _ in false },
            beep: { [unowned self] in self.beeps += 1 },
            showFailure: { [unowned self] completion in
                self.shown.append(completion.snapshot.draggedID)
                return self.nextToken
            },
            cancelFailure: { [unowned self] token in
                self.cancelled.append(token)
                return true
            })
    }

    private func completion(_ id: CGWindowID, workspace: Int = 1, members: Set<CGWindowID>? = nil,
                            outcome: TiledDragDropOutcome = .ignored) -> TiledDragCompletion {
        let tree = BSPTree()
        _ = tree.insert(makeWindow(id: id), maxDepth: 2)
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = TiledDragContext(
            workspace: workspace, physicalDisplayID: 77, usableFrame: frame,
            gap: 8, padding: 8, maxDepth: 2, memberIDs: members ?? [id], floatingIDs: [],
            fingerprint: tree.structuralFingerprint())
        return TiledDragCompletion(
            snapshot: TiledDragSnapshot(draggedID: id, sourceTree: tree, originalTree: tree.deepClone(),
                                        context: context, originalFrames: [id: frame], generation: 1),
            outcome: outcome)
    }

    private let verified = TiledDragDropOutcome.rejectedRestored(
        reason: .sizing(.geometryMismatch(2)), actualFrames: [:])

    /// A second failure from another source reports the first with the first's
    /// completion, and only then takes its place.
    func testReplacedFailureReportsWithItsOwnCompletion() {
        let c = coordinator()
        c.deferDegraded(completion(1, workspace: 1), crossTree: nil, affected: [1])
        XCTAssertTrue(shown.isEmpty, "held until a layout settles it")
        generation = 2
        c.deferDegraded(completion(2, workspace: 2), crossTree: nil, affected: [2])
        XCTAssertEqual(shown, [1])
        XCTAssertEqual(beeps, 1)
    }

    /// A verified drop on the same key settles the pending error with no show.
    func testVerifiedDropOnTheSameKeyCancels() {
        let c = coordinator()
        c.deferDegraded(completion(1), crossTree: nil, affected: [1])
        generation = 2
        let later = completion(1)
        c.noteDropFinished(verified, completion: later, crossTree: nil, affected: [1])
        XCTAssertTrue(shown.isEmpty)
        XCTAssertEqual(beeps, 0)
    }

    /// A verified drop elsewhere says nothing of the pending key, so the error
    /// shows then, with the completion that failed.
    func testVerifiedDropElsewhereShowsThePendingError() {
        let c = coordinator()
        c.deferDegraded(completion(1, workspace: 1), crossTree: nil, affected: [1])
        generation = 2
        c.noteDropFinished(verified, completion: completion(9, workspace: 3), crossTree: nil, affected: [9])
        XCTAssertEqual(shown, [1])
    }

    func testNothingPendingIsANoOp() {
        let c = coordinator()
        c.noteDropFinished(verified, completion: completion(1), crossTree: nil, affected: [1])
        c.reconcile(with: [], allWindows: [])
        XCTAssertTrue(shown.isEmpty)
    }

    /// A poll with no pass for the pending key shows the error once.
    func testPollWithoutEvidenceShowsOnce() {
        let c = coordinator()
        c.deferDegraded(completion(1), crossTree: nil, affected: [1])
        c.reconcile(with: [], allWindows: [])
        c.reconcile(with: [], allWindows: [])
        XCTAssertEqual(shown, [1])
    }

    /// Reset drops the completion, so a later poll has nothing to show.
    func testResetForgetsThePendingError() {
        let c = coordinator()
        c.deferDegraded(completion(1), crossTree: nil, affected: [1])
        c.reset()
        c.reconcile(with: [], allWindows: [])
        XCTAssertTrue(shown.isEmpty)
    }

    /// A verified layout after the error showed takes the error back down.
    func testVerifiedDropCancelsAShownError() {
        let c = coordinator()
        c.deferDegraded(completion(1), crossTree: nil, affected: [1])
        c.reconcile(with: [], allWindows: [])
        XCTAssertEqual(shown, [1])
        generation = 2
        c.noteDropFinished(verified, completion: completion(1), crossTree: nil, affected: [1])
        XCTAssertEqual(cancelled, [500])
    }

    /// Another error's end leaves this one pending.
    func testErrorFinishedIgnoresAnotherToken() {
        let c = coordinator()
        c.deferDegraded(completion(1), crossTree: nil, affected: [1])
        c.reconcile(with: [], allWindows: [])
        c.errorFinished(token: 999)
        generation = 2
        c.noteDropFinished(verified, completion: completion(1), crossTree: nil, affected: [1])
        XCTAssertEqual(cancelled, [500])
    }

    /// Its own end settles it, so a later verified drop has nothing to cancel.
    func testErrorFinishedSettlesItsOwnToken() {
        let c = coordinator()
        c.deferDegraded(completion(1), crossTree: nil, affected: [1])
        c.reconcile(with: [], allWindows: [])
        c.errorFinished(token: 500)
        generation = 2
        c.noteDropFinished(verified, completion: completion(1), crossTree: nil, affected: [1])
        XCTAssertEqual(cancelled, [])
    }
}
