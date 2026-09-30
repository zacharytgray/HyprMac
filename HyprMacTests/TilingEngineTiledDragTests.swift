import Cocoa
import XCTest
@testable import HyprMac

final class TilingEngineTiledDragTests: XCTestCase {
    func testEmptyWorkspacePublishesCompleteOccluderFramesWithoutCreatingTree() throws {
        let fixture = try makeEmptyFixture()
        let occluders = [makeWindow(id: 40), makeWindow(id: 41)]
        fixture.trace.frames = [
            40: CGRect(x: 20, y: 30, width: 300, height: 200),
            41: CGRect(x: 400, y: 50, width: 250, height: 180)
        ]
        var published: [CGWindowID: CGRect]?

        let result = fixture.engine.captureTiledDrag(
            pointer: CGPoint(x: 30, y: 40), occludingWindows: occluders,
            currentLocation: { (1, fixture.screen, Set([40, 41])) },
            onCapturedFrames: { published = $0 })

        XCTAssertEqual(published, fixture.trace.frames)
        guard case .ineligible(.noTarget) = result else {
            return XCTFail("empty workspace must have no tiled target")
        }
        XCTAssertNil(fixture.engine.existingTree(forWorkspace: 1, screen: fixture.screen))
    }

    func testEmptyWorkspaceRejectsDuplicateOccludersBeforeReads() throws {
        let fixture = try makeEmptyFixture()
        let duplicate = makeWindow(id: 40)
        let result = fixture.engine.captureTiledDrag(
            pointer: .zero, occludingWindows: [duplicate, duplicate],
            currentLocation: { (1, fixture.screen, [40]) })

        XCTAssertEqual(fixture.trace.readCalls, 0)
        guard case .unknown(.duplicateWindowID(40)) = result else {
            return XCTFail("duplicate occluders must fail closed")
        }
    }

    func testEmptyWorkspaceReadFailureDoesNotPublishFrames() throws {
        let fixture = try makeEmptyFixture()
        let occluder = makeWindow(id: 40)
        fixture.trace.frames[40] = CGRect(x: 20, y: 30, width: 300, height: 200)
        fixture.trace.nextReadError = .cannotComplete
        var published = false

        let result = fixture.engine.captureTiledDrag(
            pointer: .zero, occludingWindows: [occluder],
            currentLocation: { (1, fixture.screen, [40]) },
            onCapturedFrames: { _ in published = true })

        XCTAssertFalse(published)
        guard case .unknown(.readFailed(40, .cannotComplete)) = result else {
            return XCTFail("occluder read failure must be unknown")
        }
    }

    func testEmptyWorkspaceContextChangeDuringReadDoesNotPublishFrames() throws {
        let fixture = try makeEmptyFixture()
        let occluder = makeWindow(id: 40)
        fixture.trace.frames[40] = CGRect(x: 20, y: 30, width: 300, height: 200)
        var floatingIDs: Set<CGWindowID> = [40]
        fixture.trace.onNextRead = { floatingIDs = [] }
        var published = false

        let result = fixture.engine.captureTiledDrag(
            pointer: .zero, occludingWindows: [occluder],
            currentLocation: { (1, fixture.screen, floatingIDs) },
            onCapturedFrames: { _ in published = true })

        XCTAssertGreaterThan(fixture.trace.readCalls, 0)
        XCTAssertFalse(published)
        guard case .unknown(.superseded) = result else {
            return XCTFail("stale occluder capture must be unknown")
        }
        XCTAssertNil(fixture.engine.existingTree(forWorkspace: 1, screen: fixture.screen))
    }

    func testUnchangedReleaseIsIgnoredWithoutWritesOrTreeReplacement() throws {
        let fixture = try makeFixture()
        let snapshot = try capture(fixture)
        let mapped = try XCTUnwrap(fixture.engine.existingTree(forWorkspace: 1,
                                                              screen: fixture.screen))
        fixture.trace.writes.removeAll()

        let outcome = fixture.engine.dropTiledDrag(
            snapshot, mode: .insert(targetID: 2, edge: .left),
            currentLocation: { (1, fixture.screen, []) })

        XCTAssertTrue(fixture.trace.writes.isEmpty)
        guard case .ignored = outcome else { return XCTFail("unchanged release must be ignored") }
        XCTAssertTrue(fixture.engine.existingTree(forWorkspace: 1,
                                                  screen: fixture.screen) === mapped)
    }

    func testReleaseWithoutTargetCommitsDetectedResize() throws {
        let fixture = try makeFixture()
        let snapshot = try capture(fixture)
        fixture.trace.frames[1]?.size.width += 30

        let outcome = fixture.engine.dropTiledDrag(
            snapshot, mode: nil, currentLocation: { (1, fixture.screen, []) })

        guard case let .committed(candidate, _, _) = outcome else {
            return XCTFail("detected resize must commit")
        }
        XCTAssertTrue(fixture.engine.existingTree(forWorkspace: 1,
                                                  screen: fixture.screen) === candidate)
    }

    func testOffMonitorReleaseRestoresWithoutReplacingSourceTree() throws {
        let fixture = try makeFixture()
        let snapshot = try capture(fixture)
        let sourceTree = try XCTUnwrap(fixture.engine.existingTree(forWorkspace: 1,
                                                                  screen: fixture.screen))
        fixture.trace.frames[1] = CGRect(
            x: snapshot.context.usableFrame.maxX + 100,
            y: snapshot.context.usableFrame.minY,
            width: 800,
            height: 500
        )

        let outcome = fixture.engine.dropTiledDrag(
            snapshot, mode: nil, currentLocation: { (1, fixture.screen, []) })

        guard case .rejectedRestored(reason: .preflight(.noTarget), _) = outcome else {
            return XCTFail("off-monitor release must restore")
        }
        XCTAssertEqual(fixture.trace.frames, snapshot.originalFrames)
        XCTAssertTrue(fixture.engine.existingTree(forWorkspace: 1,
                                                  screen: fixture.screen) === sourceTree)
    }

    func testResizeClassificationReadFailureRestoresOriginalFrameMap() throws {
        let fixture = try makeFixture()
        let snapshot = try capture(fixture)
        fixture.trace.frames[1]?.size.width += 30
        fixture.trace.nextReadError = .cannotComplete

        let outcome = fixture.engine.dropTiledDrag(
            snapshot, mode: nil, currentLocation: { (1, fixture.screen, []) })

        guard case .rejectedRestored(
            reason: .sizing(.readFailed(1, .cannotComplete)), _
        ) = outcome else {
            return XCTFail("classification error must report verified restoration")
        }
        XCTAssertEqual(fixture.trace.frames, snapshot.originalFrames)
    }

    func testPointerCapturePublishesExactCombinedFrames() throws {
        let fixture = try makeFixture()
        var published: [CGWindowID: CGRect]?
        let result = fixture.engine.captureTiledDrag(
            pointer: center(of: fixture.trace.frames[1]), occludingWindows: [],
            currentLocation: { (1, fixture.screen, []) },
            onCapturedFrames: { published = $0 })
        XCTAssertEqual(published, fixture.trace.frames)
        guard case .captured = result else { return XCTFail("expected pointer capture") }
    }

    func testPointerCaptureRechecksFloatingStateDuringReads() throws {
        let fixture = try makeFixture()
        var location: (workspace: Int, screen: NSScreen, floatingIDs: Set<CGWindowID>)?
            = (1, fixture.screen, [])
        fixture.trace.onNextRead = { location = (1, fixture.screen, [1]) }
        let result = fixture.engine.captureTiledDrag(
            pointer: center(of: fixture.trace.frames[1]), occludingWindows: [],
            currentLocation: { location })
        XCTAssertGreaterThan(fixture.trace.readCalls, 0)
        guard case .unknown(.superseded) = result else {
            return XCTFail("floating change must supersede capture")
        }
    }

    func testPointerCaptureRechecksRemovedLocationDuringReads() throws {
        let removed = try makeFixture()
        var current: (workspace: Int, screen: NSScreen, floatingIDs: Set<CGWindowID>)?
            = (1, removed.screen, [])
        removed.trace.onNextRead = { current = nil }
        let result = removed.engine.captureTiledDrag(
            pointer: center(of: removed.trace.frames[1]), occludingWindows: [],
            currentLocation: { current })
        XCTAssertGreaterThan(removed.trace.readCalls, 0)
        guard case .unknown(.superseded) = result else {
            return XCTFail("removed location must supersede capture")
        }
    }

    func testPointerCaptureRechecksPhysicalDisplayIdentityDuringReads() throws {
        var displayID: CGDirectDisplayID = 10
        let fixture = try makeFixture(selectedDisplayID: { displayID })
        fixture.trace.onNextRead = { displayID = 11 }
        let result = fixture.engine.captureTiledDrag(
            pointer: center(of: fixture.trace.frames[1]), occludingWindows: [],
            currentLocation: { (1, fixture.screen, []) })
        XCTAssertGreaterThan(fixture.trace.readCalls, 0)
        guard case .unknown(.superseded) = result else {
            return XCTFail("display replacement must supersede capture")
        }
    }

    func testPointerCaptureRechecksLayoutConfigurationDuringReads() throws {
        for change in 0..<3 {
            let fixture = try makeFixture()
            fixture.trace.onNextRead = {
                if change == 0 { fixture.engine.gapSize += 1 }
                if change == 1 { fixture.engine.outerPadding += 1 }
                if change == 2 { fixture.engine.maxSplitsPerMonitor[fixture.screen.localizedName] = 1 }
            }
            let result = fixture.engine.captureTiledDrag(
                pointer: center(of: fixture.trace.frames[1]), occludingWindows: [],
                currentLocation: { (1, fixture.screen, []) })
            XCTAssertGreaterThan(fixture.trace.readCalls, 0)
            if case .unknown(.superseded) = result {
                continue
            }
            XCTFail("configuration change \(change) must supersede capture")
        }
    }

    func testAcceptedDropReplacesMappedTreeOnlyAfterVerifiedFrames() throws {
        let fixture = try makeFixture()
        let oldTree = try XCTUnwrap(fixture.engine.existingTree(forWorkspace: 1,
                                                               screen: fixture.screen))
        let snapshot = try capture(fixture)
        fixture.trace.frames[1]?.origin.x += 2

        let outcome = fixture.engine.dropTiledDrag(
            snapshot, mode: .insert(targetID: 2, edge: .left),
            currentLocation: { (1, fixture.screen, []) })

        guard case let .committed(candidate, actualFrames, _) = outcome else {
            return XCTFail("expected committed drop")
        }
        let mapped = try XCTUnwrap(fixture.engine.existingTree(forWorkspace: 1,
                                                               screen: fixture.screen))
        XCTAssertFalse(mapped === oldTree)
        XCTAssertTrue(mapped === candidate)
        XCTAssertEqual(Set(actualFrames.keys), Set([1, 2, 3]))
    }

    func testChangedWorkspaceSupersedesWithoutReplacingTree() throws {
        let fixture = try makeFixture()
        let oldTree = try XCTUnwrap(fixture.engine.existingTree(forWorkspace: 1,
                                                               screen: fixture.screen))
        let snapshot = try capture(fixture)

        let outcome = fixture.engine.dropTiledDrag(
            snapshot, mode: .insert(targetID: 2, edge: .right),
            currentLocation: { (2, fixture.screen, []) })

        guard case .superseded = outcome else { return XCTFail("expected superseded") }
        XCTAssertTrue(fixture.engine.existingTree(forWorkspace: 1,
                                                  screen: fixture.screen) === oldTree)
        XCTAssertTrue(fixture.trace.writes.isEmpty)
    }

    func testGenerationChangeDuringAXSupersedesWithoutCommit() throws {
        let fixture = try makeFixture()
        let snapshot = try capture(fixture)
        let oldTree = try XCTUnwrap(fixture.engine.existingTree(forWorkspace: 1,
                                                               screen: fixture.screen))
        fixture.trace.frames[1]?.origin.x += 2
        fixture.trace.onNextWrite = { fixture.engine.beginLayoutGeneration() }

        let outcome = fixture.engine.dropTiledDrag(
            snapshot, mode: .insert(targetID: 2, edge: .left),
            currentLocation: { (1, fixture.screen, []) })

        guard case .superseded = outcome else { return XCTFail("expected superseded") }
        XCTAssertTrue(fixture.engine.existingTree(forWorkspace: 1,
                                                  screen: fixture.screen) === oldTree)
    }

    func testFloatingMembershipChangeSupersedesBeforeWrites() throws {
        let fixture = try makeFixture()
        let snapshot = try capture(fixture)
        fixture.trace.writes.removeAll()

        let outcome = fixture.engine.dropTiledDrag(
            snapshot, mode: .insert(targetID: 2, edge: .left),
            currentLocation: { (1, fixture.screen, [2]) })

        guard case .superseded = outcome else { return XCTFail("expected superseded") }
        XCTAssertTrue(fixture.trace.writes.isEmpty)
    }

    func testRejectedRestoredKeepsOriginalTree() throws {
        let fixture = try makeFixture()
        let snapshot = try capture(fixture)
        let oldTree = try XCTUnwrap(fixture.engine.existingTree(forWorkspace: 1,
                                                               screen: fixture.screen))
        fixture.trace.frames[1]?.origin.x += 2
        fixture.trace.remainingWriteFailures = 1

        let outcome = fixture.engine.dropTiledDrag(
            snapshot, mode: .insert(targetID: 2, edge: .left),
            currentLocation: { (1, fixture.screen, []) })

        guard case .rejectedRestored = outcome else {
            return XCTFail("expected verified restoration")
        }
        XCTAssertTrue(fixture.engine.existingTree(forWorkspace: 1,
                                                  screen: fixture.screen) === oldTree)
    }

    func testDegradedDropKeepsOriginalTree() throws {
        let fixture = try makeFixture()
        let snapshot = try capture(fixture)
        let oldTree = try XCTUnwrap(fixture.engine.existingTree(forWorkspace: 1,
                                                               screen: fixture.screen))
        fixture.trace.frames[1]?.origin.x += 2
        fixture.trace.remainingWriteFailures = 2

        let outcome = fixture.engine.dropTiledDrag(
            snapshot, mode: .insert(targetID: 2, edge: .left),
            currentLocation: { (1, fixture.screen, []) })

        guard case .degraded = outcome else { return XCTFail("expected degraded drop") }
        XCTAssertTrue(fixture.engine.existingTree(forWorkspace: 1,
                                                  screen: fixture.screen) === oldTree)
    }

    func testDegradedReleaseThenVerifiedSuccessorLayoutProducesNoErrorFeedback() throws {
        for bundleID in ["com.apple.Safari", "com.apple.TextEdit"] {
            let fixture = try makeFixture(screen: DragTestScreen())
            let snapshot = try capture(fixture)
            fixture.trace.frames[1]?.origin.x += 2
            fixture.trace.nextReadError = .cannotComplete
            fixture.trace.remainingWriteFailures = 1

            let release = fixture.engine.dropTiledDrag(
                snapshot, mode: .insert(targetID: 2, edge: .left),
                currentLocation: { (1, fixture.screen, []) })
            guard case let .degraded(candidate, restoration, _, _) = release else {
                return XCTFail("expected degraded release")
            }
            XCTAssertEqual(candidate, .sizing(.readFailed(1, .cannotComplete)))
            XCTAssertEqual(restoration, .writeFailed(1, .cannotComplete))

            var reconciler = TiledDragFeedbackReconciler()
            let key = TiledDragFeedbackKey(workspace: 1,
                                           displayID: snapshot.context.physicalDisplayID)
            var feedback: [TiledDragDeferredFeedbackAction] = []
            feedback += reconciler.beginDegraded(
                key: key, generation: fixture.engine.currentLayoutGeneration,
                affectedIDs: snapshot.context.memberIDs)
            let successor = makeWindow(id: 4)
            successor.bundleID = bundleID
            fixture.trace.frames[4] = fixture.engine.displayManager.cgRect(for: fixture.screen)
            let recovered = fixture.engine.tileWindows(
                [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3), successor],
                onWorkspace: 1, screen: fixture.screen)

            XCTAssertTrue(recovered.published, bundleID)
            XCTAssertEqual(recovered.publishedIDs, [1, 2, 3, 4], bundleID)
            feedback += reconciler.reconcile(.accepted(
                key: key, generation: recovered.generation,
                publishedIDs: recovered.publishedIDs, expectedIDs: [1, 2, 3, 4]))
            XCTAssertEqual(feedback, [.cancelDegraded(key: key)], bundleID)
        }
    }

    func testGenerationChangeDuringRestorationMapsEngineOutcomeToSuperseded() throws {
        let fixture = try makeFixture()
        let snapshot = try capture(fixture)
        fixture.trace.frames[1]?.origin.x += 2
        fixture.trace.remainingWriteFailures = 1
        fixture.trace.onWrite = { call in
            if call == 2 { fixture.engine.beginLayoutGeneration() }
        }
        let outcome = fixture.engine.dropTiledDrag(
            snapshot, mode: .insert(targetID: 2, edge: .left),
            currentLocation: { (1, fixture.screen, []) })
        guard case .superseded = outcome else {
            return XCTFail("stale restoration outcome must map to superseded")
        }
        XCTAssertEqual(fixture.trace.writeCalls, 2)
    }

    func testCleanupWrappedSupersessionMapsEngineOutcomeToSuperseded() throws {
        let fixture = try makeFixture()
        let snapshot = try capture(fixture)
        fixture.trace.frames[1]?.origin.x += 2
        fixture.trace.cleanupError = .cannotComplete
        fixture.trace.onNextWrite = { fixture.engine.beginLayoutGeneration() }
        let outcome = fixture.engine.dropTiledDrag(
            snapshot, mode: .insert(targetID: 2, edge: .left),
            currentLocation: { (1, fixture.screen, []) })
        guard case .superseded = outcome else {
            return XCTFail("cleanup-wrapped stale outcome must map to superseded")
        }
    }

    // MARK: - across monitors

    func testCrossMonitorInsertCommitsBothTreesAndMovesOnlyTheDraggedWindow() throws {
        let fixture = makeCrossFixture()
        let sourceTree = try XCTUnwrap(fixture.engine.existingTree(forWorkspace: 1,
                                                                  screen: fixture.tall))
        let targetTree = try XCTUnwrap(fixture.engine.existingTree(forWorkspace: 2,
                                                                  screen: fixture.wide))
        // a floater over the wide screen does not block the release
        let snapshot = try captureCross(fixture, floatingIDs: [40])
        let slot = try XCTUnwrap(fixture.trace.frames[10])
        fixture.trace.frames[1]?.origin = CGPoint(x: 300, y: 200)

        let outcome = dropCross(fixture, snapshot,
                                at: CGPoint(x: slot.minX + 5, y: slot.midY), swap: false,
                                floatingIDs: [40])

        guard case let .acrossTrees(.committed(sourceCandidate, frames, progress), cross) = outcome else {
            return XCTFail("expected a committed drop across monitors, got \(outcome)")
        }
        XCTAssertTrue(progress.candidateVerified)
        XCTAssertEqual(cross.moves, [1: 2])
        XCTAssertEqual(fixture.engine.windowIDs(inTreeForWorkspace: 1, screen: fixture.tall), [2, 3])
        XCTAssertEqual(fixture.engine.windowIDs(inTreeForWorkspace: 2, screen: fixture.wide),
                       [1, 10, 11])
        let publishedSource = fixture.engine.existingTree(forWorkspace: 1, screen: fixture.tall)
        let publishedTarget = fixture.engine.existingTree(forWorkspace: 2, screen: fixture.wide)
        XCTAssertTrue(publishedSource === sourceCandidate)
        XCTAssertTrue(publishedTarget === cross.targetCandidate)
        XCTAssertFalse(publishedSource === sourceTree)
        XCTAssertFalse(publishedTarget === targetTree)
        // every window on both screens sits on its published slot, as read back
        for id: CGWindowID in [1, 2, 3, 10, 11] {
            let onSource = [2, 3].contains(id)
            let slot = fixture.engine.intendedRect(for: id, onWorkspace: onSource ? 1 : 2,
                                                   screen: onSource ? fixture.tall : fixture.wide)
            XCTAssertEqual(fixture.trace.frames[id], slot, "window \(id)")
            XCTAssertEqual(frames[id], fixture.trace.frames[id], "window \(id)")
        }
        XCTAssertTrue(fixture.engine.unverifiedLayouts.isEmpty)
    }

    func testCrossMonitorSwapTradesTreesAndWorkspaces() throws {
        let fixture = makeCrossFixture()
        let snapshot = try captureCross(fixture)
        let draggedSlot = try XCTUnwrap(fixture.trace.frames[1])
        let targetSlot = try XCTUnwrap(fixture.trace.frames[10])
        fixture.trace.frames[1]?.origin = CGPoint(x: 300, y: 200)

        let outcome = dropCross(fixture, snapshot, at: center(of: targetSlot), swap: true)

        guard case let .acrossTrees(.committed, cross) = outcome else {
            return XCTFail("expected a committed swap across monitors, got \(outcome)")
        }
        XCTAssertEqual(cross.moves, [1: 2, 10: 1])
        XCTAssertEqual(fixture.engine.windowIDs(inTreeForWorkspace: 1, screen: fixture.tall),
                       [10, 2, 3])
        XCTAssertEqual(fixture.engine.windowIDs(inTreeForWorkspace: 2, screen: fixture.wide), [1, 11])
        XCTAssertEqual(fixture.trace.frames[10], draggedSlot)
        XCTAssertEqual(fixture.trace.frames[1], targetSlot)
    }

    func testCrossMonitorDropOnAWorkspaceWithoutTilesMakesTheDraggedWindowItsRoot() throws {
        for swap in [false, true] {
            let fixture = makeCrossFixture(targetIDs: [])
            XCTAssertNil(fixture.engine.existingTree(forWorkspace: 2, screen: fixture.wide))
            let snapshot = try captureCross(fixture)
            fixture.trace.frames[1]?.origin = CGPoint(x: 300, y: 200)

            let outcome = dropCross(fixture, snapshot, at: CGPoint(x: 1000, y: 500), swap: swap)

            guard case let .acrossTrees(.committed, cross) = outcome else {
                return XCTFail("expected the empty workspace to take the window, swap=\(swap)")
            }
            XCTAssertEqual(cross.moves, [1: 2])
            XCTAssertEqual(fixture.engine.windowIDs(inTreeForWorkspace: 2, screen: fixture.wide), [1])
            XCTAssertEqual(fixture.engine.windowIDs(inTreeForWorkspace: 1, screen: fixture.tall), [2, 3])
            let usable = fixture.engine.displayManager.cgRect(for: fixture.wide)
            let padding = fixture.engine.outerPadding
            XCTAssertEqual(fixture.trace.frames[1], usable.insetBy(dx: padding, dy: padding))
        }
    }

    func testCrossMonitorDropOfTheSoleSourceWindowRemovesTheSourceTree() throws {
        let fixture = makeCrossFixture(sourceIDs: [1])
        let snapshot = try captureCross(fixture)
        let slot = try XCTUnwrap(fixture.trace.frames[11])
        fixture.trace.frames[1]?.origin = CGPoint(x: 300, y: 200)

        let outcome = dropCross(fixture, snapshot,
                                at: CGPoint(x: slot.maxX - 5, y: slot.midY), swap: false)

        guard case .acrossTrees(.committed, _) = outcome else {
            return XCTFail("expected a committed drop, got \(outcome)")
        }
        XCTAssertNil(fixture.engine.existingTree(forWorkspace: 1, screen: fixture.tall))
        XCTAssertEqual(fixture.engine.windowIDs(inTreeForWorkspace: 2, screen: fixture.wide),
                       [10, 11, 1])
    }

    func testCrossMonitorDropPastTheTargetMaxSplitsRestoresOnlyTheSource() throws {
        let fixture = makeCrossFixture { engine, wide in
            engine.maxSplitsPerMonitor[wide.localizedName] = 1
        }
        let sourceTree = fixture.engine.existingTree(forWorkspace: 1, screen: fixture.tall)
        let targetTree = fixture.engine.existingTree(forWorkspace: 2, screen: fixture.wide)
        let originals = fixture.trace.frames
        let snapshot = try captureCross(fixture)
        let slot = try XCTUnwrap(originals[10])
        fixture.trace.frames[1]?.origin = CGPoint(x: 300, y: 200)
        fixture.trace.writes.removeAll()

        let outcome = dropCross(fixture, snapshot,
                                at: CGPoint(x: slot.minX + 5, y: slot.midY), swap: false)

        guard case let .rejectedRestored(reason, frames) = outcome else {
            return XCTFail("expected an ordinary verified restore, got \(outcome)")
        }
        XCTAssertEqual(reason, .preflight(.maxDepthExceeded))
        XCTAssertEqual(fixture.trace.frames, originals)
        XCTAssertEqual(Set(frames.keys), [1, 2, 3])
        // refused before any write, so the release screen was never touched
        XCTAssertEqual(Set(fixture.trace.writes), [1, 2, 3])
        XCTAssertTrue(fixture.engine.existingTree(forWorkspace: 1, screen: fixture.tall) === sourceTree)
        XCTAssertTrue(fixture.engine.existingTree(forWorkspace: 2, screen: fixture.wide) === targetTree)
        // nothing was written before the refusal and the verified rollback
        // put the source back on its slots: both keys still speak for their
        // geometry, and the drift monitor keeps watching the source
        XCTAssertTrue(fixture.engine.unverifiedLayouts.isEmpty)
    }

    func testCrossMonitorRollsBackBothTreesWhenATargetFrameIsRefused() throws {
        let fixture = makeCrossFixture()
        let sourceTree = fixture.engine.existingTree(forWorkspace: 1, screen: fixture.tall)
        let targetTree = fixture.engine.existingTree(forWorkspace: 2, screen: fixture.wide)
        let originals = fixture.trace.frames
        let snapshot = try captureCross(fixture)
        let slot = try XCTUnwrap(originals[10])
        fixture.trace.frames[1]?.origin = CGPoint(x: 300, y: 200)
        // 10 will not give up any of its width to make room
        fixture.trace.sizeFloors[10] = slot.size
        fixture.trace.advancesClock = true

        let outcome = dropCross(fixture, snapshot,
                                at: CGPoint(x: slot.minX + 5, y: slot.midY), swap: false)

        guard case let .acrossTrees(.rejectedRestored(reason, _), cross) = outcome else {
            return XCTFail("expected a verified rollback of both trees, got \(outcome)")
        }
        XCTAssertEqual(reason, .sizing(.geometryMismatch(10)))
        XCTAssertTrue(cross.moves.isEmpty)
        XCTAssertEqual(fixture.trace.frames, originals)
        XCTAssertTrue(fixture.engine.existingTree(forWorkspace: 1, screen: fixture.tall) === sourceTree)
        XCTAssertTrue(fixture.engine.existingTree(forWorkspace: 2, screen: fixture.wide) === targetTree)
        XCTAssertEqual(fixture.engine.windowIDs(inTreeForWorkspace: 1, screen: fixture.tall), [1, 2, 3])
        XCTAssertEqual(fixture.engine.windowIDs(inTreeForWorkspace: 2, screen: fixture.wide), [10, 11])
    }

    func testCrossMonitorReleaseOnAScreenThatCannotTakeTheWindowRestoresAsBefore() throws {
        let fixture = makeCrossFixture()
        let sourceTree = fixture.engine.existingTree(forWorkspace: 1, screen: fixture.tall)
        let targetTree = fixture.engine.existingTree(forWorkspace: 2, screen: fixture.wide)
        let originals = fixture.trace.frames
        let snapshot = try captureCross(fixture)
        fixture.trace.frames[1]?.origin = CGPoint(x: 300, y: 200)
        fixture.trace.writes.removeAll()

        // a disabled monitor or the scratchpad layer gives no location
        let outcome = fixture.engine.dropTiledDrag(
            snapshot, mode: .crossMonitor(pointer: CGPoint(x: 400, y: 300), swapRequested: false),
            currentLocation: { (1, fixture.tall, []) }, releaseLocation: { nil })

        guard case .rejectedRestored(reason: .preflight(.noTarget), _) = outcome else {
            return XCTFail("expected the ordinary no-target restore, got \(outcome)")
        }
        XCTAssertEqual(fixture.trace.frames, originals)
        XCTAssertTrue(Set(fixture.trace.writes).isDisjoint(with: [10, 11]))
        XCTAssertTrue(fixture.engine.existingTree(forWorkspace: 1, screen: fixture.tall) === sourceTree)
        XCTAssertTrue(fixture.engine.existingTree(forWorkspace: 2, screen: fixture.wide) === targetTree)
    }

    func testCrossMonitorResizeCandidateKeepsTheSameTreeRules() throws {
        let fixture = makeCrossFixture()
        let targetTree = fixture.engine.existingTree(forWorkspace: 2, screen: fixture.wide)
        let originals = fixture.trace.frames
        let snapshot = try captureCross(fixture)
        // resized well past the threshold and standing on the other screen
        fixture.trace.frames[1] = CGRect(x: 300, y: 200, width: 600, height: 500)

        let outcome = dropCross(fixture, snapshot, at: CGPoint(x: 500, y: 400), swap: false)

        guard case .rejectedRestored(reason: .preflight(.noTarget), _) = outcome else {
            return XCTFail("expected the resize candidate to restore, got \(outcome)")
        }
        XCTAssertEqual(fixture.trace.frames, originals)
        XCTAssertTrue(fixture.engine.existingTree(forWorkspace: 2, screen: fixture.wide) === targetTree)
    }

    func testCrossMonitorDropOfASlowAppLandsOnItsLongerTry() throws {
        let fixture = makeCrossFixture()
        let snapshot = try captureCross(fixture)
        let slot = try XCTUnwrap(fixture.trace.frames[10])
        fixture.trace.frames[1]?.origin = CGPoint(x: 300, y: 200)
        // Messages, live: 101 ms to refuse the position write
        fixture.trace.positionWriteAnswer[1] = 0.15

        let outcome = dropCross(fixture, snapshot,
                                at: CGPoint(x: slot.minX + 5, y: slot.midY), swap: false)

        guard case let .acrossTrees(.committed, cross) = outcome else {
            return XCTFail("expected the longer try to commit, got \(outcome)")
        }
        XCTAssertEqual(cross.moves, [1: 2])
        XCTAssertEqual(fixture.engine.windowIDs(inTreeForWorkspace: 2, screen: fixture.wide),
                       [1, 10, 11])
        XCTAssertEqual(fixture.trace.frames[1],
                       fixture.engine.intendedRect(for: 1, onWorkspace: 2, screen: fixture.wide))
    }

    func testTitleBarDragTheAppShrinksCrossesMonitorsInsteadOfResizingTheSource() throws {
        let fixture = makeCrossFixture()
        let sourceRatio = try XCTUnwrap(fixture.engine.existingTree(forWorkspace: 1,
                                                                   screen: fixture.tall)).root.splitRatio
        let original = try XCTUnwrap(fixture.trace.frames[1])
        let result = fixture.engine.captureTiledDrag(
            pointer: CGPoint(x: original.midX, y: original.minY + 20), occludingWindows: [],
            currentLocation: { (1, fixture.tall, []) })
        guard case let .captured(snapshot) = result else { throw TestFailure.capture }
        // the 14:50:09 shape: the pointer is over the wide screen's first
        // tile, the window still mostly on the tall one, and the app took
        // 178 points off its own height on the way
        var released = original.offsetBy(dx: 250, dy: -130)
        released.size.height -= 178
        fixture.trace.frames[1] = released
        let slot = try XCTUnwrap(fixture.trace.frames[10])

        let outcome = dropCross(fixture, snapshot,
                                at: CGPoint(x: slot.minX + 90, y: slot.midY), swap: false)

        guard case .acrossTrees(.committed, _) = outcome else {
            return XCTFail("a title-bar drag must stay a move, got \(outcome)")
        }
        XCTAssertEqual(fixture.engine.windowIDs(inTreeForWorkspace: 1, screen: fixture.tall), [2, 3])
        XCTAssertEqual(fixture.engine.windowIDs(inTreeForWorkspace: 2, screen: fixture.wide),
                       [1, 10, 11])
        XCTAssertEqual(fixture.engine.existingTree(forWorkspace: 1, screen: fixture.tall)?
            .root.userSetRatio, false)
        XCTAssertEqual(sourceRatio, TilingConfig.defaultRatio)
    }

    // MARK: - live drop preview

    func testPreviewShowsExactlyWhereEachDropAcrossMonitorsLands() throws {
        // points relative to the wide screen's two tiles, 10 left and 11 right
        let cases: [(name: String, swap: Bool, point: (CGRect, CGRect) -> CGPoint)] = [
            ("left of 10", false, { a, _ in CGPoint(x: a.minX + 5, y: a.midY) }),
            ("bottom of 11", false, { _, b in CGPoint(x: b.midX, y: b.maxY - 3) }),
            ("in the gap", false, { a, _ in CGPoint(x: a.maxX + 3, y: a.midY) }),
            ("in the top padding", false, { _, b in CGPoint(x: b.midX, y: 2) }),
            ("swap with 11", true, { _, b in CGPoint(x: b.midX, y: b.midY) })
        ]
        for testCase in cases {
            let fixture = makeCrossFixture()
            let snapshot = try captureCross(fixture)
            let point = testCase.point(try XCTUnwrap(fixture.trace.frames[10]),
                                       try XCTUnwrap(fixture.trace.frames[11]))
            let preview = previewFrame(fixture, snapshot, at: point, swap: testCase.swap)
            XCTAssertNotNil(preview, testCase.name)
            fixture.trace.frames[1]?.origin = CGPoint(x: 300, y: 200)

            let outcome = dropCross(fixture, snapshot, at: point, swap: testCase.swap)

            guard case .acrossTrees(.committed, _) = outcome else {
                XCTFail("\(testCase.name): expected a commit, got \(outcome)")
                continue
            }
            XCTAssertEqual(preview, fixture.trace.frames[1], testCase.name)
        }
    }

    func testPreviewOfAnEmptyWorkspaceIsItsWholeTilingRect() throws {
        let fixture = makeCrossFixture(targetIDs: [])
        let snapshot = try captureCross(fixture)
        let point = CGPoint(x: 1000, y: 500)
        let preview = previewFrame(fixture, snapshot, at: point, swap: false)
        fixture.trace.frames[1]?.origin = CGPoint(x: 300, y: 200)

        guard case .acrossTrees(.committed, _) = dropCross(fixture, snapshot, at: point,
                                                           swap: false) else {
            return XCTFail("expected the empty workspace to take the window")
        }
        let usable = fixture.engine.displayManager.cgRect(for: fixture.wide)
        let padding = fixture.engine.outerPadding
        XCTAssertEqual(preview, usable.insetBy(dx: padding, dy: padding))
        XCTAssertEqual(preview, fixture.trace.frames[1])
    }

    func testPreviewOfASameTreeDropIsWhereThatDropLands() throws {
        let fixture = makeCrossFixture()
        let snapshot = try captureCross(fixture)
        let slot = try XCTUnwrap(fixture.trace.frames[3])
        let point = CGPoint(x: slot.midX, y: slot.maxY - 3)
        let plan = TiledDropPlanner.plan(pointer: point, draggedID: 1,
                                         sourceTiles: snapshot.context.usableFrame,
                                         sourceSlots: snapshot.originalFrames, release: .source)
        guard case let .sameTree(target) = plan else { return XCTFail("expected tile 3, got \(plan)") }
        let preview = fixture.engine.tiledDragPreviewFrame(snapshot, plan: plan, swap: false,
                                                           target: nil)
        fixture.trace.frames[1]?.origin.x += 40

        guard case .committed = fixture.engine.dropTiledDrag(
            snapshot, mode: .insert(targetID: target.windowID, edge: target.edge),
            currentLocation: { (1, fixture.tall, []) }) else {
            return XCTFail("expected a same-tree commit")
        }
        XCTAssertNotNil(preview)
        XCTAssertEqual(preview, fixture.trace.frames[1])
    }

    func testNoPreviewWhereTheDropWouldRestore() throws {
        let fixture = makeCrossFixture { engine, wide in
            engine.maxSplitsPerMonitor[wide.localizedName] = 1
        }
        let snapshot = try captureCross(fixture)
        let slot = try XCTUnwrap(fixture.trace.frames[10])
        let point = CGPoint(x: slot.minX + 5, y: slot.midY)

        XCTAssertNil(previewFrame(fixture, snapshot, at: point, swap: false), "past max splits")
        let gap = CGPoint(x: -500, y: fixture.trace.frames[1]!.maxY + 4)
        XCTAssertNil(fixture.engine.tiledDragPreviewFrame(
            snapshot, plan: TiledDropPlanner.plan(pointer: gap, draggedID: 1,
                                                  sourceTiles: snapshot.context.usableFrame,
                                                  sourceSlots: snapshot.originalFrames,
                                                  release: .source),
            swap: false, target: nil), "a gap on the source")
        fixture.trace.frames[1]?.origin = CGPoint(x: 300, y: 200)
        guard case .rejectedRestored(reason: .preflight(.maxDepthExceeded), _) = dropCross(
            fixture, snapshot, at: point, swap: false) else {
            return XCTFail("the drop past max splits must restore")
        }
    }

    func testPreviewTargetGoesStaleWithAnyLayoutSinceThePress() throws {
        let fixture = makeCrossFixture()
        let snapshot = try captureCross(fixture)
        let target = try XCTUnwrap(fixture.engine.tiledDragPreviewTarget(
            for: snapshot, location: (2, fixture.wide, [])))
        XCTAssertEqual(target.currentContext(), target.context)

        fixture.engine.beginLayoutGeneration()

        XCTAssertNil(target.currentContext(), "a cached target is dropped")
        XCTAssertNil(fixture.engine.tiledDragPreviewTarget(for: snapshot,
                                                           location: (2, fixture.wide, [])),
                     "and nothing replaces it: the drop is superseded")
    }

    func testPreviewTargetIsDeclinedWhereTheDropWouldBe() throws {
        let fixture = makeCrossFixture()
        let snapshot = try captureCross(fixture)
        XCTAssertNotNil(fixture.engine.tiledDragPreviewTarget(for: snapshot,
                                                              location: (2, fixture.wide, [])))
        XCTAssertNil(fixture.engine.tiledDragPreviewTarget(for: snapshot,
                                                           location: (1, fixture.wide, [])),
                     "the source's own workspace")
        XCTAssertNil(fixture.engine.tiledDragPreviewTarget(
            for: snapshot, location: (TilingEngine.scratchpadWorkspace, fixture.wide, [])))
        XCTAssertNil(fixture.engine.tiledDragPreviewTarget(for: snapshot,
                                                           location: (2, fixture.wide, [10])),
                     "a floater in the release tree")
    }

    func testSameMonitorDropIgnoresTheReleaseLocation() throws {
        let fixture = makeCrossFixture()
        let targetTree = fixture.engine.existingTree(forWorkspace: 2, screen: fixture.wide)
        let snapshot = try captureCross(fixture)
        fixture.trace.frames[1]?.origin.x += 2
        fixture.trace.writes.removeAll()

        let outcome = fixture.engine.dropTiledDrag(
            snapshot, mode: .insert(targetID: 3, edge: .left),
            currentLocation: { (1, fixture.tall, []) },
            releaseLocation: { (2, fixture.wide, []) })

        guard case let .committed(candidate, _, _) = outcome else {
            return XCTFail("expected an ordinary same-tree commit, got \(outcome)")
        }
        XCTAssertTrue(fixture.engine.existingTree(forWorkspace: 1, screen: fixture.tall) === candidate)
        XCTAssertEqual(Set(candidate.allWindows.map(\.windowID)), [1, 2, 3])
        XCTAssertTrue(fixture.engine.existingTree(forWorkspace: 2, screen: fixture.wide) === targetTree)
        XCTAssertTrue(Set(fixture.trace.writes).isDisjoint(with: [10, 11]))
    }

    private struct Fixture {
        let engine: TilingEngine
        let screen: NSScreen
        let trace: DragSizingTrace
    }

    private func makeFixture(
        selectedDisplayID: (() -> CGDirectDisplayID)? = nil,
        screen suppliedScreen: NSScreen? = nil
    ) throws -> Fixture {
        let screen = suppliedScreen ?? NSScreen.main ?? NSScreen.screens.first ?? DragTestScreen()
        let trace = DragSizingTrace()
        let fixtureDisplayID = (screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber)?.uint32Value ?? 0
        let displayID: (NSScreen) -> CGDirectDisplayID = { candidate in
            let actualID = (candidate.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber)?.uint32Value ?? 0
            if actualID == fixtureDisplayID, let selectedDisplayID { return selectedDisplayID() }
            return actualID
        }
        let engine = TilingEngine(displayManager: DisplayManager(screenSource: { [screen] }),
                                  frameSizingIOFactory: trace.factory,
                                  tiledDragDisplayID: displayID)
        let windows = [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)]
        let layouts = engine.prepareTileLayout(windows, onWorkspace: 1, screen: screen)
        trace.frames = Dictionary(uniqueKeysWithValues: layouts.map { ($0.0.windowID, $0.1) })
        return Fixture(engine: engine, screen: screen, trace: trace)
    }

    private func makeEmptyFixture() throws -> Fixture {
        let screen = NSScreen.main ?? NSScreen.screens.first ?? DragTestScreen()
        let trace = DragSizingTrace()
        let engine = TilingEngine(displayManager: DisplayManager(screenSource: { [screen] }),
                                  frameSizingIOFactory: trace.factory)
        return Fixture(engine: engine, screen: screen, trace: trace)
    }

    private func capture(_ fixture: Fixture) throws -> TiledDragSnapshot {
        let result = fixture.engine.captureTiledDrag(draggedID: 1, workspace: 1,
                                                     screen: fixture.screen, floatingIDs: [])
        guard case let .captured(snapshot) = result else {
            throw TestFailure.capture
        }
        return snapshot
    }

    private struct CrossFixture {
        let engine: TilingEngine
        /// primary, workspace 2
        let wide: NSScreen
        /// to its left, workspace 1, where the drags start
        let tall: NSScreen
        let trace: DragSizingTrace
    }

    private func makeCrossFixture(
        sourceIDs: [CGWindowID] = [1, 2, 3],
        targetIDs: [CGWindowID] = [10, 11],
        configure: (TilingEngine, NSScreen) -> Void = { _, _ in }
    ) -> CrossFixture {
        let wide = CrossDragScreen(frame: NSRect(x: 0, y: 0, width: 2000, height: 1000),
                                   name: "Cross drag wide", number: 81)
        let tall = CrossDragScreen(frame: NSRect(x: -1000, y: 0, width: 1000, height: 1600),
                                   name: "Cross drag tall", number: 82)
        let trace = DragSizingTrace()
        let engine = TilingEngine(displayManager: DisplayManager(screenSource: { [wide, tall] }),
                                  frameSizingIOFactory: trace.factory)
        configure(engine, wide)
        var frames: [CGWindowID: CGRect] = [:]
        let source = engine.prepareTileLayout(sourceIDs.map { makeWindow(id: $0) },
                                              onWorkspace: 1, screen: tall)
        for (window, frame) in source { frames[window.windowID] = frame }
        if !targetIDs.isEmpty {
            let target = engine.prepareTileLayout(targetIDs.map { makeWindow(id: $0) },
                                                  onWorkspace: 2, screen: wide)
            for (window, frame) in target { frames[window.windowID] = frame }
        }
        trace.frames = frames
        return CrossFixture(engine: engine, wide: wide, tall: tall, trace: trace)
    }

    private func captureCross(_ fixture: CrossFixture,
                              floatingIDs: Set<CGWindowID> = []) throws -> TiledDragSnapshot {
        let result = fixture.engine.captureTiledDrag(draggedID: 1, workspace: 1,
                                                     screen: fixture.tall, floatingIDs: floatingIDs)
        guard case let .captured(snapshot) = result else { throw TestFailure.capture }
        return snapshot
    }

    private func dropCross(_ fixture: CrossFixture, _ snapshot: TiledDragSnapshot,
                           at pointer: CGPoint, swap: Bool,
                           floatingIDs: Set<CGWindowID> = []) -> TiledDragDropOutcome {
        fixture.engine.dropTiledDrag(
            snapshot, mode: .crossMonitor(pointer: pointer, swapRequested: swap),
            currentLocation: { (1, fixture.tall, floatingIDs) },
            releaseLocation: { (2, fixture.wide, floatingIDs) })
    }

    /// what the live preview shows for a release at `point` on the wide screen
    private func previewFrame(_ fixture: CrossFixture, _ snapshot: TiledDragSnapshot,
                              at point: CGPoint, swap: Bool) -> CGRect? {
        let target = fixture.engine.tiledDragPreviewTarget(for: snapshot,
                                                           location: (2, fixture.wide, []))
        let slots = target.map {
            TiledDropPlanner.slots(of: $0.tree, in: $0.context.usableFrame,
                                   gap: $0.context.gap, padding: $0.context.padding)
        }
        let plan = TiledDropPlanner.plan(pointer: point, draggedID: snapshot.draggedID,
                                         sourceTiles: snapshot.context.usableFrame,
                                         sourceSlots: snapshot.originalFrames,
                                         release: .otherMonitor(slots: slots))
        return fixture.engine.tiledDragPreviewFrame(snapshot, plan: plan, swap: swap, target: target)
    }

    private enum TestFailure: Error { case capture }

    private func center(of frame: CGRect?) -> CGPoint {
        guard let frame else { return .zero }
        return CGPoint(x: frame.midX, y: frame.midY)
    }
}

private final class DragTestScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 1200, height: 800) }
    override var visibleFrame: NSRect { frame }
    override var localizedName: String { "Tiled drag test display" }
    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): NSNumber(value: 77)]
    }
}

/// One of two side-by-side displays for drops across monitors. Usable
/// frame is the whole frame, and the display number is fixed.
private final class CrossDragScreen: SyntheticScreen {
    private let bounds: NSRect
    private let name: String
    private let number: UInt32

    init(frame: NSRect, name: String, number: UInt32) {
        bounds = frame
        self.name = name
        self.number = number
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var frame: NSRect { bounds }
    override var visibleFrame: NSRect { bounds }
    override var localizedName: String { name }
    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): NSNumber(value: number)]
    }
}

private final class DragSizingTrace {
    var frames: [CGWindowID: CGRect] = [:]
    var writes: [CGWindowID] = []
    var onNextWrite: (() -> Void)?
    var onWrite: ((Int) -> Void)?
    var onNextRead: (() -> Void)?
    var remainingWriteFailures = 0
    var writeCalls = 0
    var cleanupError: AXError?
    var readCalls = 0
    var nextReadError: AXError?
    /// a window never takes a size below its floor, like an app refusing
    /// to shrink. the answer still returns success
    var sizeFloors: [CGWindowID: CGSize] = [:]
    /// off by default: the clock stands still and only the sample limit
    /// ends a settle loop
    var advancesClock = false
    /// seconds a window takes to answer a position write. a shorter call
    /// timeout is used up whole and gets `cannotComplete`
    var positionWriteAnswer: [CGWindowID: TimeInterval] = [:]
    private var time: TimeInterval = 0

    func factory(_ windows: [CGWindowID: HyprWindow],
                 _ generation: @escaping () -> UInt64) -> FrameSizingIO {
        FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { [unowned self] id, size, _ in
                writeCalls += 1
                onWrite?(writeCalls)
                onNextWrite?()
                onNextWrite = nil
                if remainingWriteFailures > 0 {
                    remainingWriteFailures -= 1
                    return .cannotComplete
                }
                let floor = sizeFloors[id] ?? .zero
                frames[id]?.size = CGSize(width: max(size.width, floor.width),
                                          height: max(size.height, floor.height))
                writes.append(id)
                return .success
            },
            writePosition: { [unowned self] id, point, timeout in
                writeCalls += 1
                onWrite?(writeCalls)
                if let answer = positionWriteAnswer[id] {
                    time += min(answer, timeout)
                    if answer > timeout { return .cannotComplete }
                }
                frames[id]?.origin = point
                writes.append(id)
                return .success
            },
            readPosition: { [unowned self] id, _ in
                readCalls += 1
                onNextRead?()
                onNextRead = nil
                if let error = nextReadError {
                    nextReadError = nil
                    return (error, nil)
                }
                return (.success, frames[id]?.origin)
            },
            readSize: { [unowned self] id, _ in (.success, frames[id]?.size) },
            now: { [unowned self] in time },
            sleep: { [unowned self] interval in if advancesClock { time += interval } },
            currentGeneration: generation,
            endFrameWrite: { [unowned self] _, _, _ in
                cleanupError.map { .failed($0) } ?? .restored
            }
        )
    }
}
