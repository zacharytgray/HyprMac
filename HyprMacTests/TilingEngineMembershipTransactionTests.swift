import XCTest
@testable import HyprMac

final class TilingEngineMembershipTransactionTests: XCTestCase {
    func testReturnedIncumbentIsNotRecoveredAsANewAdmission() throws {
        let screen = MembershipTestScreen()
        let trace = MembershipTrace()
        let engine = TilingEngine(displayManager: DisplayManager(),
                                  frameSizingIOFactory: { _, generation in trace.io(generation) })
        let incumbent = makeWindow(id: 801)
        let newcomer = makeWindow(id: 802)
        let rect = engine.displayManager.cgRect(for: screen)
        for w in [incumbent, newcomer] {
            trace.frames[w.windowID] = rect.insetBy(dx: 100, dy: 100)
        }
        XCTAssertTrue(engine.tileWindows([incumbent], onWorkspace: 1, screen: screen).published)
        engine.removeWindowID(incumbent.windowID)
        trace.forgetWrites()
        trace.rejectNextRead = true

        let result = engine.tileWindows([incumbent, newcomer], onWorkspace: 1, screen: screen)

        XCTAssertFalse(result.published)
        XCTAssertEqual(result.strandedIDs, [newcomer.windowID])
        XCTAssertTrue(engine.unverifiedLayouts.contains { $0.windowIDs.contains(incumbent.windowID) })
    }

    func testARecycledWindowIDIsJudgedAsANewcomerNotAnIncumbent() {
        let screen = MembershipTestScreen()
        let trace = MembershipTrace()
        let engine = TilingEngine(displayManager: DisplayManager(),
                                  frameSizingIOFactory: { _, generation in trace.io(generation) })
        let incumbent = makeWindow(id: 841)
        let doomed = makeWindow(id: 842)
        let rect = engine.displayManager.cgRect(for: screen)
        for w in [incumbent, doomed] { trace.frames[w.windowID] = rect.insetBy(dx: 100, dy: 100) }
        XCTAssertTrue(engine.tileWindows([incumbent, doomed],
                                         onWorkspace: 1, screen: screen).published)
        // 842 closes. discovery prunes its node but never fully forgets the
        // id, so the verified-admission identity would outlive the window.
        engine.removeWindowID(842)

        // the id comes back on a different window that cannot fit
        engine.forgetAdmittedIdentity(windowID: 842)
        let recycled = makeWindow(id: 842)
        recycled.observedMinSize = rect.size
        trace.frames[842] = rect.insetBy(dx: 100, dy: 100)

        let result = engine.tileWindows([incumbent, recycled], onWorkspace: 1, screen: screen)

        XCTAssertEqual(result.refusedIDs, [842], "a recycled id is a newcomer")
        XCTAssertTrue(result.strandedIDs.contains(842), "so recovery can still see it")
    }

    func testKnownImpossibleAdmissionReturnsRefusalWithoutRoutingOrWritingNewcomer() {
        let screen = MembershipTestScreen()
        let trace = MembershipTrace()
        let engine = TilingEngine(displayManager: DisplayManager(),
                                  frameSizingIOFactory: { _, generation in trace.io(generation) })
        let incumbent = makeWindow(id: 811)
        let newcomer = makeWindow(id: 812)
        let rect = engine.displayManager.cgRect(for: screen)
        trace.frames[811] = rect.insetBy(dx: 100, dy: 100)
        trace.frames[812] = rect.insetBy(dx: 100, dy: 100)
        XCTAssertTrue(engine.tileWindows([incumbent], onWorkspace: 1, screen: screen).published)
        newcomer.observedMinSize = rect.size
        trace.written = []

        let result = engine.tileWindows([incumbent, newcomer], onWorkspace: 1, screen: screen)

        XCTAssertEqual(result.refusedIDs, [812])
        XCTAssertFalse(trace.written.contains(812))
        XCTAssertEqual(result.publishedIDs, [811])
    }

    func testImpossibleAdjustmentSkipsItsVisibleWritePass() {
        let screen = MembershipTestScreen()
        let trace = MembershipTrace()
        let engine = TilingEngine(displayManager: DisplayManager(),
                                  frameSizingIOFactory: { _, generation in trace.io(generation) })
        let windows = [makeWindow(id: 821), makeWindow(id: 822)]
        let rect = engine.displayManager.cgRect(for: screen)
        for w in windows { trace.frames[w.windowID] = rect.insetBy(dx: 100, dy: 100) }
        XCTAssertTrue(engine.tileWindows(windows, onWorkspace: 1, screen: screen).published)
        trace.minSize[822] = CGSize(width: rect.width * 0.95, height: 0)
        var writes = 0
        trace.onWrite = { writes += 1 }

        let result = engine.tileWindows(windows, onWorkspace: 1, screen: screen)

        XCTAssertFalse(result.published)
        XCTAssertLessThanOrEqual(writes, 12, "two windows: candidate and restoration only")
    }

    func testReturnedIncumbentGetsItsSlotBeforeALowerIDNewcomer() {
        let screen = MembershipTestScreen()
        let trace = MembershipTrace()
        let engine = TilingEngine(displayManager: DisplayManager(screenSource: { [screen] }),
                                  frameSizingIOFactory: { _, generation in trace.io(generation) })
        let incumbent = makeWindow(id: 832)
        let newcomer = makeWindow(id: 831)
        let rect = engine.displayManager.cgRect(for: screen)
        for w in [incumbent, newcomer] { trace.frames[w.windowID] = rect.insetBy(dx: 100, dy: 100) }
        XCTAssertTrue(engine.tileWindows([incumbent], onWorkspace: 1, screen: screen).published)
        engine.removeWindowID(832)
        incumbent.observedMinSize = rect.size

        let result = engine.tileWindows([newcomer, incumbent], onWorkspace: 1, screen: screen)

        XCTAssertEqual(result.publishedIDs, [832])
        XCTAssertEqual(result.refusedIDs, [831])
    }

    func testSameHomeDisplayChangeSupersedesAnActiveCandidate() throws {
        let f = try fixture()
        let prior = f.tree.structuralFingerprint()
        var changed = false
        f.trace.onWrite = {
            guard !changed else { return }
            changed = true
            f.engine.handleDisplayChange(currentScreens: [f.screen], homeScreenForWorkspace: { _ in f.screen })
        }

        let result = f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertEqual(result.failure, .superseded)
        XCTAssertFalse(result.restorationVerified)
        XCTAssertEqual(f.tree.structuralFingerprint(), prior)
    }

    func testAnImpossibleReturnedIncumbentKeepsTheWholeKeyUnverifiedWithoutWrites() {
        let screen = MembershipTestScreen()
        let trace = MembershipTrace()
        let engine = TilingEngine(displayManager: DisplayManager(screenSource: { [screen] }),
                                  frameSizingIOFactory: { _, generation in trace.io(generation) })
        let windows = [makeWindow(id: 841), makeWindow(id: 842)]
        let rect = engine.displayManager.cgRect(for: screen)
        for w in windows { trace.frames[w.windowID] = rect.insetBy(dx: 100, dy: 100) }
        XCTAssertTrue(engine.tileWindows(windows, onWorkspace: 1, screen: screen).published)
        for w in windows {
            engine.removeWindowID(w.windowID)
            w.observedMinSize = rect.size
        }
        trace.written = []

        let result = engine.tileWindows(windows, onWorkspace: 1, screen: screen)

        XCTAssertFalse(result.published)
        XCTAssertTrue(result.strandedIDs.isEmpty, "incumbents are not fallback targets")
        XCTAssertTrue(trace.written.isEmpty)
        XCTAssertEqual(engine.unverifiedGeometryWindowIDs, [841, 842])
        XCTAssertTrue(engine.intendedTileRects().isEmpty)
    }

    func testExplicitDepartureEndsIncumbentProtectionForLaterReadmission() throws {
        let f = try fixture()
        let window = f.windows[0]
        XCTAssertTrue(f.engine.tileWindows([window], onWorkspace: 1, screen: f.screen).published)
        f.engine.removeWindow(window, fromWorkspace: 1)
        f.trace.forgetWrites()
        f.trace.rejectNextRead = true

        let result = f.engine.tileWindows([window], onWorkspace: 1, screen: f.screen)

        XCTAssertFalse(result.published)
        XCTAssertEqual(result.strandedIDs, [window.windowID])
    }

    func testRejectedMembershipKeepsPriorTreeAndActualFrames() throws {
        let f = try fixture()
        f.trace.rejectNextRead = true
        let before = f.tree.structuralFingerprint()
        let originals = f.trace.frames

        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertEqual(f.engine.existingTree(forWorkspace: 1, screen: f.screen)?.structuralFingerprint(), before)
        XCTAssertEqual(f.trace.frames, originals)
    }

    func testMembershipIsNotPublishedDuringAXWrites() throws {
        let f = try fixture()
        let before = f.tree.structuralFingerprint()
        var observed: [BSPTree.StructuralFingerprint] = []
        f.trace.onWrite = {
            if let tree = f.engine.existingTree(forWorkspace: 1, screen: f.screen) {
                observed.append(tree.structuralFingerprint())
            }
        }

        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertFalse(observed.isEmpty)
        XCTAssertTrue(observed.allSatisfy { $0 == before })
        XCTAssertEqual(Set(f.engine.existingTree(forWorkspace: 1, screen: f.screen)?.allWindows.map(\.windowID) ?? []), Set(f.windows.map(\.windowID)))
    }

    func testRejectedAddWindowKeepsPriorMembership() throws {
        let f = try fixture()
        f.trace.rejectNextRead = true
        let before = f.tree.structuralFingerprint()

        f.engine.addWindow(f.windows[2], toWorkspace: 1, on: f.screen)

        XCTAssertEqual(f.engine.existingTree(forWorkspace: 1, screen: f.screen)?.structuralFingerprint(), before)
    }

    func testFitProbeChecksCompleteHiddenWorkspaceWithoutPublishingTree() throws {
        let f = try fixture()
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        let windows = Array(f.windows.prefix(2))
        for window in windows {
            window.observedMinSize = CGSize(width: usable.width * 0.7, height: usable.height * 0.7)
        }
        var writes = 0
        f.trace.onWrite = { writes += 1 }

        XCTAssertFalse(f.engine.canFitWindows(windows, onWorkspace: 2, screen: f.screen))
        XCTAssertNil(f.engine.existingTree(forWorkspace: 2, screen: f.screen))
        XCTAssertEqual(writes, 0)
    }

    func testFitProbeAcceptsCapacityAndRejectsDuplicatesWithoutWrites() throws {
        let f = try fixture()
        var writes = 0
        f.trace.onWrite = { writes += 1 }
        XCTAssertTrue(f.engine.canFitWindows(f.windows, onWorkspace: 2, screen: f.screen))
        XCTAssertFalse(f.engine.canFitWindows([f.windows[0], f.windows[0]], onWorkspace: 2, screen: f.screen))
        XCTAssertEqual(writes, 0)
    }

    func testUnreadableScratchpadCandidateKeepsPriorMembership() throws {
        let f = try fixture()
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        f.engine.tileScratchpad(Array(f.windows.prefix(2)), screen: f.screen, in: usable)
        let before = try XCTUnwrap(f.engine.existingTree(forWorkspace: 0, screen: f.screen)).structuralFingerprint()
        f.trace.rejectNextRead = true

        f.engine.tileScratchpad(f.windows, screen: f.screen, in: usable)

        XCTAssertEqual(f.engine.existingTree(forWorkspace: 0, screen: f.screen)?.structuralFingerprint(), before)
    }

    func testFailedFirstTileDoesNotPublishEmptyTree() throws {
        let f = try fixture()
        f.trace.rejectNextRead = true
        f.engine.tileWindows(f.windows, onWorkspace: 3, screen: f.screen)
        XCTAssertNil(f.engine.existingTree(forWorkspace: 3, screen: f.screen))
    }

    func testFailedScratchpadMigrationKeepsSourceTreeAndDoesNotPublishDestination() throws {
        let f = try fixture()
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        f.engine.tileScratchpad(Array(f.windows.prefix(2)), screen: f.screen, in: usable)
        let before = try XCTUnwrap(f.engine.existingTree(forWorkspace: 0, screen: f.screen)).structuralFingerprint()
        let destination = MembershipTestScreen()
        f.trace.rejectNextRead = true

        f.engine.tileScratchpad(f.windows, screen: destination, in: CGRect(x: 4000, y: 0, width: 1600, height: 1000))

        XCTAssertEqual(f.engine.existingTree(forWorkspace: 0, screen: f.screen)?.structuralFingerprint(), before)
        XCTAssertNil(f.engine.existingTree(forWorkspace: 0, screen: destination))
        XCTAssertFalse(unverifiedIDs(f.engine, workspace: TilingEngine.scratchpadWorkspace).isEmpty)
    }

    func testDegradedLayoutWithFailedRestorationKeepsPriorMembership() throws {
        let f = try fixture()
        // restoration runs and fails: the window will not shrink back to its
        // original, so the screen is near the originals, not the candidate
        f.trace.minSize[f.windows[0].windowID] = CGSize(width: 300, height: 300)
        let before = f.tree.structuralFingerprint()
        f.trace.rejectNextRead = true

        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertEqual(f.engine.existingTree(forWorkspace: 1, screen: f.screen)?.structuralFingerprint(), before)
    }

    func testSecondTargetFailureWithParkedOriginalsPublishesNothingAndWritesNoParkedFrame() throws {
        let f = try fixture()
        // originals parked off the usable frame, so they are not restoration
        // targets. every target is written, then the second one will not read
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        let parked = CGRect(x: usable.maxX + 200, y: usable.minY + 20, width: 120, height: 120)
        for window in f.windows { f.trace.frames[window.windowID] = parked }
        f.trace.rejectReadsFor = [f.windows[1].windowID]
        let before = f.tree.structuralFingerprint()

        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertEqual(f.engine.existingTree(forWorkspace: 1, screen: f.screen)?.structuralFingerprint(), before)
        XCTAssertEqual(f.trace.written, Set(f.windows.map(\.windowID)))
        XCTAssertFalse(f.trace.requested.values.contains { $0.origin == parked.origin },
                       "a parked original is never written back")
        XCTAssertEqual(unverifiedIDs(f.engine, workspace: 1), Set(f.windows.map(\.windowID)))
    }

    func testParkedOriginalsKeepThePriorRatiosAsWellAsTheMembership() throws {
        let f = try fixture()
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        // one window refuses to shrink, so pass 1 conflicts and pass 2
        // re-splits around it; the floor is unsatisfiable, so pass 2 fails too
        f.trace.minSize[f.windows[0].windowID] = CGSize(width: usable.width * 1.2, height: 0)
        for window in f.windows {
            f.trace.frames[window.windowID] = CGRect(x: usable.maxX + 200, y: usable.minY + 20,
                                                     width: 120, height: 120)
        }

        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        // a recorded minimum proves pass 1 rejected with a conflict, which is
        // what sends the transaction into the adjusted second pass
        XCTAssertNotNil(f.windows[0].observedMinSize)
        let published = try XCTUnwrap(f.engine.existingTree(forWorkspace: 1, screen: f.screen))
        XCTAssertEqual(Set(published.allWindows.map(\.windowID)),
                       Set(f.windows.prefix(2).map(\.windowID)))
        XCTAssertEqual(published.root.splitRatio, 0.6, accuracy: 0.0001,
                       "an unverified adjusted pass does not get to rewrite the live ratios")
    }

    func testCleanupFailureDoesNotPublishEvenThoughTheFramesReadBackFine() throws {
        let f = try fixture()
        // every setter succeeds and the frames land exactly where they were
        // asked to; only the EnhancedUI cleanup errors
        f.trace.endError = .cannotComplete
        let before = f.tree.structuralFingerprint()

        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertEqual(f.engine.existingTree(forWorkspace: 1, screen: f.screen)?.structuralFingerprint(), before)
        XCTAssertFalse(unverifiedIDs(f.engine, workspace: 1).isEmpty)
    }

    func testIncompleteReadbackDoesNotPublish() throws {
        let f = try fixture()
        // one window never reads back, so the final readback is incomplete
        // whatever the others say
        f.trace.rejectReadsFor = [f.windows[2].windowID]
        let before = f.tree.structuralFingerprint()

        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertEqual(f.engine.existingTree(forWorkspace: 1, screen: f.screen)?.structuralFingerprint(), before)
        XCTAssertFalse(unverifiedIDs(f.engine, workspace: 1).isEmpty)
    }

    func testWindowThatStopsShortOfItsTargetKeepsThePriorMembership() throws {
        let f = try fixture()
        // the portrait Terminal: asked for the full slot height, answers 340
        // points short, every time
        f.trace.heightShortfall[f.windows[0].windowID] = 340
        let before = f.tree.structuralFingerprint()

        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertEqual(f.engine.existingTree(forWorkspace: 1, screen: f.screen)?.structuralFingerprint(), before)
        XCTAssertEqual(f.engine.existingTree(forWorkspace: 1, screen: f.screen)?.root.splitRatio, 0.6)
        XCTAssertFalse(unverifiedIDs(f.engine, workspace: 1).isEmpty)
    }

    func testAcceptedRetryPublishesAndClearsTheUnverifiedMark() throws {
        let f = try fixture()
        f.trace.rejectNextRead = true
        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)
        XCTAssertFalse(unverifiedIDs(f.engine, workspace: 1).isEmpty)

        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertEqual(Set(f.engine.windowIDs(inTreeForWorkspace: 1, screen: f.screen)),
                       Set(f.windows.map(\.windowID)))
        XCTAssertTrue(unverifiedIDs(f.engine, workspace: 1).isEmpty)
    }

    func testSupersededLayoutLeavesNoUnverifiedMarkBehindForANewerAcceptedOne() throws {
        let f = try fixture()
        var bumped = false
        f.trace.onWrite = {
            guard !bumped else { return }
            bumped = true
            f.engine.beginLayoutGeneration()
        }

        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertTrue(bumped)
        XCTAssertTrue(unverifiedIDs(f.engine, workspace: 1).isEmpty,
                      "a superseded generation does not get to mark a key a newer owner holds")
        // and nothing was rolled back over the newer operation
        XCTAssertEqual(f.trace.written.count, 1)
    }

    func testOverlappingOriginalsRestoreWithoutPublishingThemAsATiledLayout() throws {
        let f = try fixture()
        // the originals sit on top of each other, the way an untiled newcomer
        // and an incumbent do
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        let stacked = CGRect(x: usable.minX + 40, y: usable.minY + 40, width: 400, height: 300)
        for window in f.windows { f.trace.frames[window.windowID] = stacked }
        f.trace.rejectNextRead = true
        let before = f.tree.structuralFingerprint()

        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertEqual(f.engine.existingTree(forWorkspace: 1, screen: f.screen)?.structuralFingerprint(), before)
        for window in f.windows {
            XCTAssertEqual(f.trace.frames[window.windowID], stacked,
                           "every original goes back exactly where it was")
        }
    }

    // MARK: - who the failed admission stranded

    func testFailedAdmissionNamesTheInsertedNewcomerNotTheWindowThatRefused() throws {
        let f = try fixture()
        // the incumbent refuses its frame, the way Safari 21611 did while
        // 26016 was the window that had just opened
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        f.trace.minSize[f.windows[0].windowID] = CGSize(width: usable.width * 1.2, height: 0)

        let result = f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertEqual(result.insertedIDs, [f.windows[2].windowID])
        XCTAssertEqual(result.failedInsertedIDs, [f.windows[2].windowID])
        XCTAssertFalse(result.published)
        XCTAssertNotNil(result.failure)
        XCTAssertFalse(result.publishedIDs.contains(f.windows[2].windowID))
    }

    func testFailedAdmissionKeepsTheIncumbentsMembershipAndRatios() throws {
        let f = try fixture()
        let before = f.tree.structuralFingerprint()
        f.trace.rejectNextRead = true

        let result = f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        let live = try XCTUnwrap(f.engine.existingTree(forWorkspace: 1, screen: f.screen))
        XCTAssertEqual(live.structuralFingerprint(), before)
        XCTAssertEqual(live.root.splitRatio, 0.6, accuracy: 0.0001)
        XCTAssertEqual(result.publishedIDs, Set(f.windows.prefix(2).map(\.windowID)))
        XCTAssertEqual(result.failedInsertedIDs, [f.windows[2].windowID])
    }

    func testAcceptedAdmissionStrandsNobody() throws {
        let f = try fixture()

        let result = f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertTrue(result.published)
        XCTAssertNil(result.failure)
        XCTAssertTrue(result.failedInsertedIDs.isEmpty)
        XCTAssertEqual(result.publishedIDs, Set(f.windows.map(\.windowID)))
    }

    func testAVerifiedRollbackReportsTheIncumbentsItPutBack() throws {
        let f = try fixture()
        f.trace.rejectNextRead = true

        let result = f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertTrue(result.restorationVerified)
        XCTAssertEqual(result.restoredIDs, Set(f.windows.map(\.windowID)))
    }

    // MARK: - the retry's minima bypass

    func testTheRetryHonoursWhatItsOwnAdmissionObserved() throws {
        let f = try fixture()
        let newcomer = f.windows[2]
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        // the newcomer refuses to shrink, so the admission fails and the
        // engine learns a bound from that very readback
        f.trace.minSize[newcomer.windowID] = CGSize(width: usable.width * 1.2, height: 0)

        let admission = f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)
        XCTAssertEqual(admission.failedInsertedIDs, [newcomer.windowID])
        XCTAssertEqual(f.engine.knownMinimumSizes[newcomer.windowID]?.provenance, .observed)

        // the app would accept the slot now, but the bound blocks the fit
        // check before a single setter can go out
        f.trace.minSize.removeValue(forKey: newcomer.windowID)
        let plain = f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)
        XCTAssertTrue(plain.insertedIDs.isEmpty, "the learned bound refuses the insert outright")
        XCTAssertFalse(f.engine.windowIDs(inTreeForWorkspace: 1, screen: f.screen).contains(newcomer.windowID))

        // the bound this admission itself observed passed the learning
        // guards, so the retry keeps it
        let retry = f.engine.retryAdmission(
            f.windows, onWorkspace: 1, screen: f.screen,
            bypassingMinimaBefore: [newcomer.windowID: admission.generation])
        XCTAssertTrue(retry.insertedIDs.isEmpty)
        XCTAssertEqual(retry.refusedIDs, [newcomer.windowID])
    }

    func testTheRetryStillIgnoresABoundOlderThanItsAdmission() throws {
        let f = try fixture()
        let newcomer = f.windows[2]
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        f.trace.minSize[newcomer.windowID] = CGSize(width: usable.width * 1.2, height: 0)

        let admission = f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)
        XCTAssertEqual(f.engine.knownMinimumSizes[newcomer.windowID]?.provenance, .observed)
        f.trace.minSize.removeValue(forKey: newcomer.windowID)

        // a later admission's reach covers this one, so the bound is the
        // possibly-stale kind the bypass exists for
        let retry = f.engine.retryAdmission(
            f.windows, onWorkspace: 1, screen: f.screen,
            bypassingMinimaBefore: [newcomer.windowID: admission.generation &+ 100])

        XCTAssertEqual(retry.insertedIDs, [newcomer.windowID])
        XCTAssertTrue(retry.published)
        XCTAssertTrue(retry.publishedIDs.contains(newcomer.windowID))
        XCTAssertNotNil(f.engine.knownMinimumSizes[newcomer.windowID],
                        "the bypass lasts one pass; it does not erase the memory")
    }

    func testStartupRetryRebuildsAfterLearningPortraitWindowWidths() {
        let screen = PortraitMembershipTestScreen()
        let trace = MembershipTrace()
        let engine = TilingEngine(displayManager: DisplayManager(screenSource: { [screen] }),
                                  frameSizingIOFactory: { _, generation in trace.io(generation) })
        engine.maxSplitsPerMonitor[screen.localizedName] = 2
        let windows = (1...4).map { makeWindow(id: CGWindowID(59_000 + $0)) }
        let widths: [CGFloat] = [574, 528, 708, 640]
        let rect = engine.displayManager.cgRect(for: screen)
        for window in windows {
            window.observedMinSize = CGSize(width: 420, height: 300)
            window.minSizeProvenance = .seeded
            trace.frames[window.windowID] = rect
        }
        trace.failNextSizeWriteID = windows.last?.windowID

        let admission = engine.tileWindows(windows, onWorkspace: 1, screen: screen)
        XCTAssertFalse(admission.published)
        XCTAssertTrue(admission.publishedIDs.isEmpty)

        for (window, width) in zip(windows, widths) {
            trace.minSize[window.windowID] = CGSize(width: width, height: 300)
        }
        trace.requested = [:]
        trace.written = []
        var retryWrites = 0
        trace.onWrite = { retryWrites += 1 }
        let bypass = Dictionary(uniqueKeysWithValues: windows.map {
            ($0.windowID, admission.generation &+ 1)
        })

        let retry = engine.retryAdmission(windows, onWorkspace: 1, screen: screen,
                                          bypassingMinimaBefore: bypass,
                                          refusingImpossibleArrangements: true)

        XCTAssertTrue(retry.published,
                      "failure=\(String(describing: retry.failure)) minima=\(engine.knownMinimumSizes) requested=\(trace.requested) frames=\(trace.frames)")
        XCTAssertEqual(retry.publishedIDs, Set(windows.map(\.windowID)))
        XCTAssertTrue(retry.refusedIDs.isEmpty)
        XCTAssertLessThanOrEqual(retryWrites, 24, "one candidate and one recovered topology")
        XCTAssertEqual(Set(engine.windowIDs(inTreeForWorkspace: 1, screen: screen)),
                       Set(windows.map(\.windowID)))
        XCTAssertTrue(windows.allSatisfy { trace.requested[$0.windowID]?.width == 1064 })
    }

    /// The Outlook thrash: two tenants whose learned floors cannot both sit
    /// on one screen. The admission probes and learns; the retry has nothing
    /// left to find out, so it must not probe again.
    func testARetryWithNothingNewToLearnResolvesWithoutWriting() {
        let screen = MembershipTestScreen()
        let trace = MembershipTrace()
        let engine = TilingEngine(displayManager: DisplayManager(screenSource: { [screen] }),
                                  frameSizingIOFactory: { _, generation in trace.io(generation) })
        let tenant = makeWindow(id: 32513)
        let newcomer = makeWindow(id: 32836)
        let rect = engine.displayManager.cgRect(for: screen)
        trace.frames[tenant.windowID] = rect
        trace.frames[newcomer.windowID] = rect
        XCTAssertTrue(engine.tileWindows([tenant], onWorkspace: 1, screen: screen).published)
        // the newcomer is wider than the whole usable frame
        trace.minSize[tenant.windowID] = CGSize(width: 900, height: 600)
        trace.minSize[newcomer.windowID] = CGSize(width: 1700, height: 600)
        var writes = 0
        trace.onWrite = { writes += 1 }

        let admission = engine.tileWindows([tenant, newcomer], onWorkspace: 1, screen: screen)
        XCTAssertEqual(admission.strandedIDs, [newcomer.windowID])
        XCTAssertEqual(engine.knownMinimumSizes[newcomer.windowID]?.size.width, 1700)
        XCTAssertEqual(engine.knownMinimumSizes[tenant.windowID]?.size.width, 900)
        XCTAssertGreaterThan(writes, 0, "the admission is where the probing belongs")
        writes = 0

        let retry = engine.retryAdmission([tenant, newcomer], onWorkspace: 1, screen: screen,
                                          bypassingMinimaBefore: [newcomer.windowID: admission.generation],
                                          refusingImpossibleArrangements: true)

        XCTAssertEqual(writes, 0, "both floors are known, so the arrangement is refused pre-write")
        XCTAssertEqual(retry.refusedIDs, [newcomer.windowID])
        XCTAssertEqual(retry.publishedIDs, [tenant.windowID])
        XCTAssertTrue(retry.insertedIDs.isEmpty)
    }

    /// The second Outlook window. The first one taught the engine a floor
    /// no slot on this screen can hold; the second must not have to prove it
    /// again with its own visible resize.
    func testASecondWindowOfARefusedAppIsJudgedBeforeAnyWriteOfItsOwn() {
        let screen = MembershipTestScreen()
        let trace = MembershipTrace()
        let engine = TilingEngine(displayManager: DisplayManager(screenSource: { [screen] }),
                                  frameSizingIOFactory: { _, generation in trace.io(generation) })
        let tenant = makeWindow(id: 32513)
        let first = makeWindow(id: 32836)
        first.bundleID = "com.microsoft.Outlook"
        let rect = engine.displayManager.cgRect(for: screen)
        for w in [tenant, first] { trace.frames[w.windowID] = rect }
        XCTAssertTrue(engine.tileWindows([tenant], onWorkspace: 1, screen: screen).published)
        trace.minSize[tenant.windowID] = CGSize(width: 620, height: 600)
        trace.minSize[first.windowID] = CGSize(width: 1700, height: 600)

        let admission = engine.tileWindows([tenant, first], onWorkspace: 1, screen: screen)
        XCTAssertEqual(admission.strandedIDs, [first.windowID])

        // the first one floats; a second window of the same app opens
        let second = makeWindow(id: 32850)
        second.bundleID = "com.microsoft.Outlook"
        trace.frames[second.windowID] = rect
        trace.minSize[second.windowID] = CGSize(width: 1700, height: 600)
        trace.written = []

        let result = engine.tileWindows([tenant, second], onWorkspace: 1, screen: screen)

        XCTAssertEqual(result.refusedIDs, [second.windowID])
        XCTAssertFalse(trace.written.contains(second.windowID),
                       "the app already told us its floor through its other window")
        XCTAssertEqual(engine.knownMinimumSizes[second.windowID]?.size.width, 1700)
        XCTAssertEqual(engine.knownMinimumSizes[second.windowID]?.provenance, .appHint)
    }

    /// A real hint: one Safari window refused `floor` points of width, so
    /// the app's hint is that floor and the next window of that app starts
    /// from it. The next window has no floor of its own — the hint is the
    /// only thing that can refuse it.
    private func safariHint(floor: CGFloat = 900, tenantFloor: CGFloat = 700)
    -> (engine: TilingEngine, screen: NSScreen, trace: MembershipTrace,
        tenant: HyprWindow, second: HyprWindow) {
        let screen = MembershipTestScreen()
        let trace = MembershipTrace()
        let engine = TilingEngine(displayManager: DisplayManager(screenSource: { [screen] }),
                                  frameSizingIOFactory: { _, generation in trace.io(generation) })
        let tenant = makeWindow(id: 32601)
        let first = makeWindow(id: 32602)
        first.bundleID = "com.apple.Safari"
        let rect = engine.displayManager.cgRect(for: screen)
        for w in [tenant, first] { trace.frames[w.windowID] = rect }
        engine.tileWindows([tenant], onWorkspace: 1, screen: screen)
        if tenantFloor > 0 {
            trace.minSize[tenant.windowID] = CGSize(width: tenantFloor, height: 600)
        }
        trace.minSize[first.windowID] = CGSize(width: floor, height: 600)
        engine.tileWindows([tenant, first], onWorkspace: 1, screen: screen)
        XCTAssertEqual(engine.knownMinimumSizes[first.windowID]?.size.width, floor,
                       "the first window's refusal is what makes the hint")

        let second = makeWindow(id: 32603)
        second.bundleID = "com.apple.Safari"
        trace.frames[second.windowID] = rect
        trace.written = []
        return (engine, screen, trace, tenant, second)
    }

    func testAnAppHintDoesNotRefuseAWindowTheSlotIsBigEnoughFor() {
        let f = safariHint()

        // ws2 holds nothing, so the slot is the whole 1584 pt usable width
        let result = f.engine.tileWindows([f.second], onWorkspace: 2, screen: f.screen)

        XCTAssertTrue(result.refusedIDs.isEmpty, "900 fits in 1584")
        XCTAssertTrue(result.publishedIDs.contains(f.second.windowID))
        XCTAssertEqual(f.engine.knownMinimumSizes[f.second.windowID]?.provenance, .appHint)
    }

    func testAnAppHintRefusesAWindowTheSlotIsTooSmallForWithoutWriting() {
        let f = safariHint(floor: 1700)

        // the app has already reported a floor wider than the whole screen
        let result = f.engine.tileWindows([f.tenant, f.second], onWorkspace: 1, screen: f.screen)

        XCTAssertEqual(result.refusedIDs, [f.second.windowID])
        XCTAssertFalse(f.trace.written.contains(f.second.windowID),
                       "the app already told us its floor through its other window")
    }

    func testAnExplicitFloatToTileProbesPastTheAppHint() {
        // 1700 is wider than the whole 1584 pt usable frame, so no
        // arrangement can hold the hint and the ordinary pass has no way in
        let f = safariHint(floor: 1700, tenantFloor: 0)
        let refused = f.engine.tileWindows([f.tenant, f.second], onWorkspace: 1, screen: f.screen)
        XCTAssertEqual(refused.refusedIDs, [f.second.windowID])
        XCTAssertFalse(f.trace.written.contains(f.second.windowID))
        f.trace.written = []

        // the user asks by hand. the hint is another window's evidence, so
        // this attempt sets it aside and asks the app itself
        let forced = f.engine.forceInsertWindow(f.second, toWorkspace: 1, on: f.screen,
                                                bypassingLearnedMinima: true)

        XCTAssertEqual(forced, .inserted)
        XCTAssertTrue(f.trace.written.contains(f.second.windowID), "one real attempt runs")
        let entry = f.engine.knownMinimumSizes[f.second.windowID]
        XCTAssertEqual(entry?.provenance, .observed,
                       "the window's own measurement replaces the hint")
        XCTAssertEqual(entry?.size.width, 788, "at the size it actually took")
    }

    func testARetryJudgesItsNewcomerAgainstTheTreeNotTheHeldWindowsBesideIt() {
        let screen = MembershipTestScreen()
        let trace = MembershipTrace()
        let engine = TilingEngine(displayManager: DisplayManager(screenSource: { [screen] }),
                                  frameSizingIOFactory: { _, generation in trace.io(generation) })
        let tenant = makeWindow(id: 32701)
        let held = makeWindow(id: 32702)
        let newcomer = makeWindow(id: 32703)
        let rect = engine.displayManager.cgRect(for: screen)
        for w in [tenant, held, newcomer] { trace.frames[w.windowID] = rect }
        XCTAssertTrue(engine.tileWindows([tenant], onWorkspace: 1, screen: screen).published)
        // a held window: assigned to the workspace, in no tree, and with a
        // floor no slot here can hold
        held.observedMinSize = CGSize(width: 1700, height: 1100)
        held.minSizeProvenance = .observed
        engine.primeMinimumSizes([held])

        let retry = engine.retryAdmission([tenant, held, newcomer], onWorkspace: 1, screen: screen,
                                          bypassingMinimaBefore: [newcomer.windowID: 999],
                                          refusingImpossibleArrangements: true)

        XCTAssertTrue(retry.publishedIDs.contains(newcomer.windowID),
                      "the newcomer fits beside the tenant; the held window is not its problem")
        XCTAssertFalse(retry.publishedIDs.contains(held.windowID))
    }

    func testTheBypassLeavesEveryOtherWindowsMinimumAlone() throws {
        let f = try fixture()
        let newcomer = f.windows[2]
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        f.trace.minSize[f.windows[0].windowID] = CGSize(width: usable.width * 1.2, height: 0)

        let admission = f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)
        let incumbentBound = f.engine.knownMinimumSizes[f.windows[0].windowID]
        XCTAssertEqual(incumbentBound?.provenance, .observed)

        _ = f.engine.retryAdmission(
            f.windows, onWorkspace: 1, screen: f.screen,
            bypassingMinimaBefore: [newcomer.windowID: admission.generation &+ 100])

        XCTAssertEqual(f.engine.knownMinimumSizes[f.windows[0].windowID]?.provenance, .observed)
    }

    // MARK: - explicit revalidation of learned minima

    /// A newcomer whose learned bound is stale: the app refused once, the
    /// engine wrote the bound down, and the app would take the slot now.
    private func staleNewcomerBound(_ f: (engine: TilingEngine, tree: BSPTree, windows: [HyprWindow], screen: NSScreen, trace: MembershipTrace)) -> HyprWindow {
        let newcomer = f.windows[2]
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        f.trace.minSize[newcomer.windowID] = CGSize(width: usable.width * 1.2, height: 0)
        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)
        f.trace.minSize.removeValue(forKey: newcomer.windowID)
        return newcomer
    }

    func testAStaleNewcomerBoundReadsAsRevalidatable() throws {
        let f = try fixture()
        let newcomer = staleNewcomerBound(f)
        XCTAssertEqual(f.engine.knownMinimumSizes[newcomer.windowID]?.provenance, .observed)

        let outlook = f.engine.admissionOutlook(newcomer, onWorkspace: 1, screen: f.screen)

        guard case let .revalidatable(refusals) = outlook else {
            return XCTFail("expected a revalidatable refusal, got \(outlook)")
        }
        XCTAssertFalse(refusals.isEmpty)
        XCTAssertTrue(refusals.contains { $0.source == .learned },
                      "the bound the app refused is what said no")
        XCTAssertTrue(refusals.allSatisfy { $0.incoming == newcomer.windowID })
    }

    func testAStaleIncumbentBoundIsBypassedForTheNewcomersSake() throws {
        let f = try fixture()
        let newcomer = f.windows[2]
        let incumbent = f.windows[0]
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        // the incumbents are what refuse, the way 21611 refused while 26016 was
        // the window trying to get in. both leaves, or the newcomer simply
        // takes the unconstrained one
        for window in f.windows.prefix(2) {
            f.trace.minSize[window.windowID] = CGSize(width: usable.width * 1.2, height: 0)
        }
        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)
        XCTAssertEqual(f.engine.knownMinimumSizes[incumbent.windowID]?.provenance, .observed)
        XCTAssertNil(f.engine.knownMinimumSizes[newcomer.windowID],
                     "the newcomer's own memory is empty; only the incumbents refused")
        for window in f.windows.prefix(2) { f.trace.minSize.removeValue(forKey: window.windowID) }

        let outlook = f.engine.admissionOutlook(newcomer, onWorkspace: 1, screen: f.screen)

        guard case let .revalidatable(refusals) = outlook else {
            return XCTFail("expected a revalidatable refusal, got \(outlook)")
        }
        XCTAssertTrue(refusals.contains { $0.tenant == incumbent.windowID && $0.source == .learned })
    }

    func testAnAcceptedRevalidationTilesTheWindowAndLowersTheBound() throws {
        let f = try fixture()
        let newcomer = staleNewcomerBound(f)
        let before = try XCTUnwrap(f.engine.knownMinimumSizes[newcomer.windowID]).size

        let result = f.engine.revalidateAdmission(f.windows, incoming: [newcomer.windowID],
                                                  onWorkspace: 1, screen: f.screen)

        XCTAssertTrue(result.published)
        XCTAssertTrue(result.publishedIDs.contains(newcomer.windowID))
        let after = try XCTUnwrap(f.engine.knownMinimumSizes[newcomer.windowID]).size
        XCTAssertLessThan(after.width, before.width,
                          "the accepted readback lowers the bound it disproved")
    }

    func testATrueLargeMinimumIsRefusedAndKeepsItsEvidenceExactly() throws {
        let f = try fixture()
        let newcomer = f.windows[2]
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        // the app really will not shrink, and still will not on the retry
        f.trace.minSize[newcomer.windowID] = CGSize(width: usable.width * 1.2, height: 0)
        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)
        let learned = try XCTUnwrap(f.engine.knownMinimumSizes[newcomer.windowID])
        let before = f.engine.windowIDs(inTreeForWorkspace: 1, screen: f.screen)

        let result = f.engine.revalidateAdmission(f.windows, incoming: [newcomer.windowID],
                                                  onWorkspace: 1, screen: f.screen)

        XCTAssertFalse(result.published)
        XCTAssertFalse(result.publishedIDs.contains(newcomer.windowID))
        XCTAssertEqual(f.engine.windowIDs(inTreeForWorkspace: 1, screen: f.screen), before,
                       "a refused attempt publishes nothing")
        XCTAssertEqual(f.engine.knownMinimumSizes[newcomer.windowID], learned,
                       "previous evidence is preserved exactly")
    }

    func testARefusedRevalidationStillRaisesABoundTheAppRefusedAgain() throws {
        let f = try fixture()
        let newcomer = f.windows[2]
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        f.trace.minSize[newcomer.windowID] = CGSize(width: usable.width * 1.2, height: 0)
        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)
        let learned = try XCTUnwrap(f.engine.knownMinimumSizes[newcomer.windowID])
        // the app refuses the attempt, and from higher up than last time
        f.trace.minSize[newcomer.windowID] = CGSize(width: usable.width * 1.2 + 200, height: 0)

        let result = f.engine.revalidateAdmission(f.windows, incoming: [newcomer.windowID],
                                                  onWorkspace: 1, screen: f.screen)

        XCTAssertFalse(result.published)
        let after = try XCTUnwrap(f.engine.knownMinimumSizes[newcomer.windowID])
        XCTAssertEqual(after.provenance, .observed)
        XCTAssertGreaterThan(after.size.width, learned.size.width,
                             "a refusal the learning guards let through is new evidence,"
                             + " not the bound the attempt set aside")
    }

    func testABoundTheMemoryNeverTookIsNamedSeededNotStructural() throws {
        let f = try fixture()
        let newcomer = f.windows[2]
        // an app-declared minimum priming refuses: above usableMinSizeMaxPx,
        // so no entry is written and the fit check reads the window's own
        newcomer.observedMinSize = CGSize(width: TilingConfig.usableMinSizeMaxPx + 1000, height: 0)
        newcomer.minSizeProvenance = .seeded

        let outlook = f.engine.admissionOutlook(newcomer, onWorkspace: 1, screen: f.screen)

        XCTAssertNil(f.engine.knownMinimumSizes[newcomer.windowID],
                     "the memory refused the value, so there is no entry to read provenance off")
        guard case let .refused(refusals) = outlook else {
            return XCTFail("expected a refusal, got \(outlook)")
        }
        XCTAssertFalse(refusals.isEmpty)
        XCTAssertTrue(refusals.contains { $0.source == .seeded },
                      "the app's own declared minimum is what said no")
        XCTAssertFalse(refusals.contains { $0.source == .structural },
                       "nothing here is a slot too small for the gap alone")
    }

    func testTheBypassIsSpentOnTheOneAttemptItWraps() throws {
        let f = try fixture()
        let newcomer = f.windows[2]
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        f.trace.minSize[newcomer.windowID] = CGSize(width: usable.width * 1.2, height: 0)
        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        // the attempt is refused, so nothing was disproved and nothing lowered
        f.engine.revalidateAdmission(f.windows, incoming: [newcomer.windowID],
                                     onWorkspace: 1, screen: f.screen)

        // the app would take it now, but the ordinary pass still honours the
        // bound: an explicit request buys one attempt, not a standing licence
        f.trace.minSize.removeValue(forKey: newcomer.windowID)
        let ordinary = f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)
        XCTAssertTrue(ordinary.insertedIDs.isEmpty)
        XCTAssertEqual(f.engine.knownMinimumSizes[newcomer.windowID]?.provenance, .observed)
    }

    func testAStructuralRefusalSurvivesTheBypassAndWritesNothing() throws {
        let f = try fixture()
        f.engine.maxSplitsPerMonitor = [f.screen.localizedName: 1]
        var writes = 0
        f.trace.onWrite = { writes += 1 }

        let outlook = f.engine.admissionOutlook(f.windows[2], onWorkspace: 1, screen: f.screen)

        guard case let .refused(refusals) = outlook else {
            return XCTFail("expected a structural refusal, got \(outlook)")
        }
        XCTAssertFalse(refusals.isEmpty)
        XCTAssertTrue(refusals.allSatisfy { $0.source == .structural })
        XCTAssertTrue(refusals.allSatisfy { $0.axis == "depth" })
        XCTAssertEqual(writes, 0, "a structural refusal never touches the screen")
    }

    func testASeededHintSurvivesTheBypassAndIsNamedAsASeededRefusal() throws {
        let f = try fixture()
        let newcomer = f.windows[2]
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        newcomer.observedMinSize = CGSize(width: usable.width * 1.2, height: 0)
        newcomer.minSizeProvenance = .seeded

        let outlook = f.engine.admissionOutlook(newcomer, onWorkspace: 1, screen: f.screen)

        guard case let .refused(refusals) = outlook else {
            return XCTFail("expected a refusal, got \(outlook)")
        }
        XCTAssertTrue(refusals.contains { $0.source == .seeded },
                      "a hint nothing has tested is not a learned bound")
    }

    func testAWindowThatFitsNeedsNoRevalidation() throws {
        let f = try fixture()
        var writes = 0
        f.trace.onWrite = { writes += 1 }

        XCTAssertEqual(f.engine.admissionOutlook(f.windows[2], onWorkspace: 1, screen: f.screen),
                       .fits)
        XCTAssertEqual(writes, 0)
    }

    func testTheOutlookLeavesTheMemoryAndTheTreeAlone() throws {
        let f = try fixture()
        let newcomer = staleNewcomerBound(f)
        let memory = f.engine.knownMinimumSizes
        let before = try XCTUnwrap(f.engine.existingTree(forWorkspace: 1, screen: f.screen))
            .structuralFingerprint()

        _ = f.engine.admissionOutlook(newcomer, onWorkspace: 1, screen: f.screen)

        XCTAssertEqual(f.engine.knownMinimumSizes, memory)
        XCTAssertEqual(f.engine.existingTree(forWorkspace: 1, screen: f.screen)?.structuralFingerprint(),
                       before)
    }

    // MARK: - a structural no-fit is reported, never routed

    func testABypassedPassReportsAStructuralNoFitInsteadOfRoutingIt() throws {
        let f = try fixture()
        f.engine.maxSplitsPerMonitor = [f.screen.localizedName: 1]
        let newcomer = f.windows[2]

        let ordinary = f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)
        XCTAssertEqual(ordinary.refusedIDs, [newcomer.windowID])

        let revalidated = f.engine.revalidateAdmission(f.windows, incoming: [newcomer.windowID],
                                                       onWorkspace: 1, screen: f.screen)

        XCTAssertEqual(revalidated.refusedIDs, [newcomer.windowID])
        XCTAssertEqual(revalidated.strandedIDs, [newcomer.windowID],
                       "the caller finishes it instead")
    }

    func testAFitProbeRunInsideABypassedPassStillSeesTheRealBound() throws {
        let f = try fixture()
        let newcomer = staleNewcomerBound(f)
        let incumbent = f.windows[0]
        var probed: Bool?
        f.trace.onWrite = {
            guard probed == nil else { return }
            // the shape routeUnfittedWindow asks in: the destination's tenants
            // plus the window, on a workspace with no tree of its own
            probed = f.engine.canFitWindows([incumbent, newcomer], onWorkspace: 9, screen: f.screen)
        }

        f.engine.revalidateAdmission(f.windows, incoming: [newcomer.windowID],
                                     onWorkspace: 1, screen: f.screen)

        XCTAssertEqual(probed, false,
                       "the probe answers on the memory as it stands, not on a bypass"
                       + " belonging to the pass it happened to run inside")
    }

    func testAWindowTheRequestNeverNamedIsJudgedAndRoutedByTheOrdinaryRules() throws {
        let f = try fixture()
        let asked = staleNewcomerBound(f)
        // a second newcomer turns up on the same workspace. the request was
        // never about it, so this pass must not lend it the tenants' bypass
        let bystander = makeWindow(id: 977)
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        f.trace.frames[bystander.windowID] = CGRect(x: usable.minX + 500, y: usable.minY + 20,
                                                    width: 120, height: 120)
        bystander.observedMinSize = CGSize(width: usable.width * 1.2, height: 0)
        bystander.minSizeProvenance = .observed
        f.engine.primeMinimumSizes([bystander])

        let result = f.engine.revalidateAdmission(f.windows + [bystander],
                                                  incoming: [asked.windowID],
                                                  onWorkspace: 1, screen: f.screen)

        XCTAssertFalse(result.insertedIDs.contains(bystander.windowID),
                       "its own learned bound still refuses it")
        XCTAssertTrue(result.refusedIDs.contains(bystander.windowID))
    }

    func testARefusedRevalidationPutsTheIncumbentsBackWhenTheNewcomerCameFromElsewhere() throws {
        let f = try fixture()
        let newcomer = f.windows[2]
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        // the window is standing somewhere this screen's usable rect does not
        // cover, the way a window being moved from another screen is
        let offScreen = CGRect(x: usable.maxX + 400, y: usable.minY + 20, width: 120, height: 120)
        f.trace.frames[newcomer.windowID] = offScreen
        let incumbentOriginals = f.windows.prefix(2).map { f.trace.frames[$0.windowID] }
        f.trace.rejectNextRead = true

        let result = f.engine.revalidateAdmission(f.windows, incoming: [newcomer.windowID],
                                                  onWorkspace: 1, screen: f.screen,
                                                  restorationReach: offScreen)

        XCTAssertFalse(result.published)
        XCTAssertTrue(result.restorationVerified,
                      "the rollback can reach both screens, so it runs and verifies")
        XCTAssertEqual(f.windows.prefix(2).map { f.trace.frames[$0.windowID] }, incumbentOriginals,
                       "the incumbents are back on their originals, not the failed candidate")
        XCTAssertEqual(f.trace.frames[newcomer.windowID], offScreen,
                       "and the newcomer is back where it came from")
    }

    func testWithoutTheReachTheRollbackLeavesTheNewcomerOnTheDestination() throws {
        let f = try fixture()
        let newcomer = f.windows[2]
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        let offScreen = CGRect(x: usable.maxX + 400, y: usable.minY + 20, width: 120, height: 120)
        f.trace.frames[newcomer.windowID] = offScreen
        let incumbentOriginals = f.windows.prefix(2).map { f.trace.frames[$0.windowID] }
        f.trace.rejectNextRead = true

        let result = f.engine.revalidateAdmission(f.windows, incoming: [newcomer.windowID],
                                                  onWorkspace: 1, screen: f.screen)

        XCTAssertFalse(result.published)
        XCTAssertEqual(result.restoredIDs, Set(f.windows.prefix(2).map(\.windowID)),
                       "the incumbents still go back")
        XCTAssertEqual(f.windows.prefix(2).map { f.trace.frames[$0.windowID] }, incumbentOriginals)
        XCTAssertNotEqual(f.trace.frames[newcomer.windowID], offScreen,
                          "but the newcomer is not taken home — that is what the reach is for")
        XCTAssertTrue(usable.contains(try XCTUnwrap(f.trace.frames[newcomer.windowID])))
    }

    // MARK: - clearing the mark

    func testTheMarkClearsWhenEveryAttemptOnTheKeyRestoredItsOriginals() throws {
        let f = try fixture()
        f.trace.rejectNextRead = true
        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)
        XCTAssertFalse(unverifiedIDs(f.engine, workspace: 1).isEmpty)

        XCTAssertTrue(f.engine.clearUnverifiedGeometry(forWorkspace: 1, screen: f.screen))
        XCTAssertTrue(unverifiedIDs(f.engine, workspace: 1).isEmpty)
    }

    func testTheMarkStandsOnceAnyAttemptOnTheKeyFailedToRestore() throws {
        let f = try fixture()
        // originals parked off the usable frame: no rollback runs at all, so
        // the incumbents are left on the candidate's frames
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        let parked = CGRect(x: usable.maxX + 200, y: usable.minY + 20, width: 120, height: 120)
        for window in f.windows { f.trace.frames[window.windowID] = parked }
        f.trace.rejectReadsFor = [f.windows[1].windowID]
        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)
        XCTAssertFalse(unverifiedIDs(f.engine, workspace: 1).isEmpty)

        XCTAssertFalse(f.engine.clearUnverifiedGeometry(forWorkspace: 1, screen: f.screen))
        XCTAssertFalse(unverifiedIDs(f.engine, workspace: 1).isEmpty,
                       "nobody knows where the incumbents are, so the key keeps its mark")
    }

    func testALaterVerifiedRollbackDoesNotRedeemAnEarlierFailedOne() throws {
        let f = try fixture()
        // first attempt: originals parked, so nothing is restored
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        let parked = CGRect(x: usable.maxX + 200, y: usable.minY + 20, width: 120, height: 120)
        for window in f.windows { f.trace.frames[window.windowID] = parked }
        f.trace.rejectReadsFor = [f.windows[1].windowID]
        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        // second attempt: the originals are on screen now and the rollback
        // verifies — but it restored the frames the first attempt left, not
        // the ones the tree describes
        f.trace.rejectReadsFor = []
        for (index, window) in f.windows.enumerated() {
            f.trace.frames[window.windowID] = CGRect(x: usable.minX + 20 + CGFloat(index) * 150,
                                                     y: usable.minY + 20, width: 120, height: 120)
        }
        f.trace.forgetWrites()
        f.trace.rejectNextRead = true
        let second = f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertTrue(second.restorationVerified,
                      "pass 2's rollback has to verify or this proves nothing")
        XCTAssertFalse(f.engine.clearUnverifiedGeometry(forWorkspace: 1, screen: f.screen))
        XCTAssertFalse(unverifiedIDs(f.engine, workspace: 1).isEmpty)
    }

    func testAnAcceptedLayoutStillClearsTheMarkAfterAFailedRollback() throws {
        let f = try fixture()
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        let parked = CGRect(x: usable.maxX + 200, y: usable.minY + 20, width: 120, height: 120)
        for window in f.windows { f.trace.frames[window.windowID] = parked }
        f.trace.rejectReadsFor = [f.windows[1].windowID]
        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)
        XCTAssertFalse(f.engine.clearUnverifiedGeometry(forWorkspace: 1, screen: f.screen))

        f.trace.rejectReadsFor = []
        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertTrue(unverifiedIDs(f.engine, workspace: 1).isEmpty,
                      "fresh verified geometry is the one thing that redeems a key")
    }

    private func unverifiedIDs(_ engine: TilingEngine, workspace: Int) -> Set<CGWindowID> {
        engine.unverifiedLayouts.filter { $0.workspace == workspace }
            .reduce(into: Set<CGWindowID>()) { $0.formUnion($1.windowIDs) }
    }

    func testDegradedLayoutWithoutWritesKeepsPriorMembership() throws {
        let f = try fixture()
        // no capture for the new window, so the transaction gives up before
        // any AX write happens
        f.trace.frames.removeValue(forKey: f.windows[2].windowID)
        let before = f.tree.structuralFingerprint()
        var writes = 0
        f.trace.onWrite = { writes += 1 }

        f.engine.tileWindows(f.windows, onWorkspace: 1, screen: f.screen)

        XCTAssertEqual(writes, 0)
        XCTAssertEqual(f.engine.existingTree(forWorkspace: 1, screen: f.screen)?.structuralFingerprint(), before)
    }

    private func fixture() throws -> (engine: TilingEngine, tree: BSPTree, windows: [HyprWindow], screen: NSScreen, trace: MembershipTrace) {
        let screen = NSScreen.main ?? NSScreen.screens.first ?? MembershipHomeScreen()
        let windows = (901...903).map { id in
            HyprWindow(element: AXUIElementCreateApplication(99999), windowID: CGWindowID(id), ownerPID: 99999)
        }
        let trace = MembershipTrace()
        let engine = TilingEngine(displayManager: DisplayManager(screenSource: { [screen] }), frameSizingIOFactory: { _, generation in trace.io(generation) })
        _ = engine.prepareTileLayout(Array(windows.prefix(2)), onWorkspace: 1, screen: screen)
        let tree = try XCTUnwrap(engine.existingTree(forWorkspace: 1, screen: screen))
        tree.root.splitRatio = 0.6
        tree.root.userSetRatio = true
        let usable = engine.displayManager.cgRect(for: screen)
        for (index, window) in windows.enumerated() {
            trace.frames[window.windowID] = CGRect(x: usable.minX + 20 + CGFloat(index) * 150,
                                                   y: usable.minY + 20, width: 120, height: 120)
        }
        return (engine, tree, windows, screen, trace)
    }
}

final class TilingEngineSwapRevalidationTests: XCTestCase {
    func testSwapProbesPastAStaleObservedMinimumAndLowersItOnAcceptance() throws {
        let f = try fixture(provenance: .observed)

        XCTAssertTrue(f.engine.swapWindows(f.windows[0], f.windows[3],
                                           onWorkspace: 1, screen: f.screen))
        XCTAssertFalse(f.trace.written.isEmpty)
        XCTAssertLessThan(f.engine.knownMinimumSizes[f.windows[0].windowID]?.size.width
                          ?? .infinity, 1500)
    }

    func testSwapProbesPastAnAppHintAndAdoptsItsOwnAcceptedSize() throws {
        let f = try fixture(provenance: .appHint)

        XCTAssertTrue(f.engine.swapWindows(f.windows[0], f.windows[3],
                                           onWorkspace: 1, screen: f.screen))
        XCTAssertEqual(f.engine.knownMinimumSizes[f.windows[0].windowID]?.provenance,
                       .observed)
        XCTAssertLessThan(f.engine.knownMinimumSizes[f.windows[0].windowID]?.size.width
                          ?? .infinity, 1500)
    }

    func testPreparedSwapCarriesItsScopedRevalidationIntoFinalApply() throws {
        let f = try fixture(provenance: .observed)

        XCTAssertNotNil(f.engine.prepareSwapLayout(f.windows[0], f.windows[3],
                                                    onWorkspace: 1, screen: f.screen))
        XCTAssertTrue(f.engine.applyComputedLayout(onWorkspace: 1, screen: f.screen))
        XCTAssertLessThan(f.engine.knownMinimumSizes[f.windows[0].windowID]?.size.width
                          ?? .infinity, 1500)
    }

    func testSupersededPreparedSwapCannotReuseItsBypassOrWriteStaleFrames() throws {
        let f = try fixture(provenance: .observed)
        XCTAssertNotNil(f.engine.prepareSwapLayout(f.windows[0], f.windows[3],
                                                    onWorkspace: 1, screen: f.screen))

        _ = f.engine.beginLayoutGeneration()
        f.engine.forgetMinimumSize(windowID: f.windows[0].windowID)
        f.windows[0].observedMinSize = CGSize(width: 1500, height: 0)
        f.windows[0].minSizeProvenance = .seeded
        f.engine.primeMinimumSizes(f.windows)
        f.trace.written = []

        XCTAssertFalse(f.engine.applyComputedLayout(onWorkspace: 1, screen: f.screen))
        XCTAssertTrue(f.trace.written.isEmpty)
        XCTAssertFalse(f.engine.canSwapWindows(f.windows[0], f.windows[3],
                                               onWorkspace: 1, screen: f.screen),
                       "the superseded operation's learned-bound bypass must be gone")
    }

    func testSeededSwapRefusalRemainsPreflightOnly() throws {
        let f = try fixture(provenance: .seeded)

        XCTAssertFalse(f.engine.swapWindows(f.windows[0], f.windows[3],
                                            onWorkspace: 1, screen: f.screen))
        XCTAssertTrue(f.trace.written.isEmpty)
    }

    func testRevalidatedSwapStillRestoresWhenAXConfirmsTheMinimum() throws {
        let f = try fixture(provenance: .observed)
        let originalOrder = f.tree.allWindows.map(\.windowID)
        let usable = f.engine.displayManager.cgRect(for: f.screen)
        let rightX = usable.minX + 1716
        f.trace.frames = [
            f.windows[0].windowID: CGRect(x: usable.minX + 8, y: usable.minY + 8,
                                          width: 1700, height: usable.height - 16),
            f.windows[1].windowID: CGRect(x: rightX, y: usable.minY + 8,
                                          width: usable.maxX - rightX - 8, height: 344),
            f.windows[2].windowID: CGRect(x: rightX, y: usable.minY + 360,
                                          width: usable.maxX - rightX - 8, height: 344),
            f.windows[3].windowID: CGRect(x: rightX, y: usable.minY + 712,
                                          width: usable.maxX - rightX - 8,
                                          height: usable.maxY - usable.minY - 720)
        ]
        f.windows[0].observedMinSize = CGSize(width: 1700, height: 0)
        let originalFrames = f.trace.frames
        f.trace.minSize[f.windows[0].windowID] = CGSize(width: 1700, height: 0)

        XCTAssertFalse(f.engine.swapWindows(f.windows[0], f.windows[3],
                                            onWorkspace: 1, screen: f.screen))
        XCTAssertEqual(f.tree.allWindows.map(\.windowID), originalOrder)
        XCTAssertEqual(f.trace.frames, originalFrames)
    }

    private func fixture(provenance: MinSizeProvenance) throws
        -> (engine: TilingEngine, tree: BSPTree, windows: [HyprWindow],
            screen: NSScreen, trace: MembershipTrace) {
        let screen = MembershipHomeScreen()
        let trace = MembershipTrace()
        let engine = TilingEngine(
            displayManager: DisplayManager(screenSource: { [screen] }),
            frameSizingIOFactory: { _, generation in trace.io(generation) })
        let windows = (981...984).map { makeWindow(id: CGWindowID($0)) }
        _ = engine.prepareTileLayout(windows, onWorkspace: 1, screen: screen)
        let tree = try XCTUnwrap(engine.existingTree(forWorkspace: 1, screen: screen))
        let rect = engine.displayManager.cgRect(for: screen)
        trace.frames = Dictionary(uniqueKeysWithValues: tree.layout(
            in: rect, gap: engine.gapSize, padding: engine.outerPadding
        ).map { ($0.0.windowID, $0.1) })
        windows[0].observedMinSize = CGSize(width: 1500, height: 0)
        windows[0].minSizeProvenance = provenance
        trace.written = []
        return (engine, tree, windows, screen, trace)
    }
}

private final class MembershipTrace {
    var frames: [CGWindowID: CGRect] = [:]
    var rejectNextRead = false
    /// windows whose reads fail from the first write onwards, so a failure
    /// can be aimed at one target instead of whichever is read first
    var rejectReadsFor: Set<CGWindowID> = []
    var onWrite: (() -> Void)?
    var failNextSizeWriteID: CGWindowID?
    /// floor a window refuses to shrink below, the way a real min-size app behaves
    var minSize: [CGWindowID: CGSize] = [:]
    /// how far short of the height it is asked for a window settles — the
    /// portrait Terminal case, which answers short whatever the ask
    var heightShortfall: [CGWindowID: CGFloat] = [:]
    /// error the EnhancedUI cleanup returns after the setters have all
    /// succeeded, so a clean-looking frame still ends in a failure
    var endError: AXError?
    /// the frames the engine asked for, before any floor is applied
    var requested: [CGWindowID: CGRect] = [:]
    /// every window a setter went out for
    var written: Set<CGWindowID> = []
    /// forget that a setter has ever run, so a second pass in the same test
    /// gets the same read behaviour as the first — otherwise rejectNextRead
    /// fires on the capture instead of on the candidate's readback
    func forgetWrites() { wrote = false }
    private var wrote = false
    private var now: TimeInterval = 0

    func io(_ generation: @escaping () -> UInt64) -> FrameSizingIO {
        var io = FrameSizingIO(setMessagingTimeout: { _, _ in .success },
                      writeSize: { [self] id, size, _ in
                          onWrite?(); wrote = true; written.insert(id)
                          if failNextSizeWriteID == id {
                              failNextSizeWriteID = nil
                              return .cannotComplete
                          }
                          requested[id, default: .zero].size = size
                          let floor = minSize[id] ?? .zero
                          let short = heightShortfall[id] ?? 0
                          frames[id]?.size = CGSize(width: max(size.width, floor.width),
                                                    height: max(size.height - short, floor.height))
                          return .success
                      },
                      writePosition: { [self] id, position, _ in
                          onWrite?(); written.insert(id)
                          requested[id, default: .zero].origin = position
                          frames[id]?.origin = position
                          return .success
                      },
                      readPosition: { [self] id, _ in
                          if wrote && rejectReadsFor.contains(id) { return (.cannotComplete, nil) }
                          if wrote && rejectNextRead { rejectNextRead = false; return (.cannotComplete, nil) }
                          return (.success, frames[id]?.origin)
                      },
                      readSize: { [self] id, _ in (.success, frames[id]?.size) },
                      now: { [self] in now }, sleep: { [self] in now += $0 }, currentGeneration: generation)
        io.endFrameWrite = { [self] _, _, _ -> AXFrameWriteBatch.EndResult in
            guard let endError else { return .restored }
            return .failed(endError)
        }
        return io
    }
}

private final class MembershipTestScreen: NSScreen {
    override var frame: NSRect { NSRect(x: 4000, y: 0, width: 1600, height: 1000) }
    override var visibleFrame: NSRect { frame }
}

private final class PortraitMembershipTestScreen: NSScreen {
    override var frame: NSRect { NSRect(x: 4000, y: 0, width: 1080, height: 1890) }
    override var visibleFrame: NSRect { frame }
}

private final class MembershipHomeScreen: NSScreen {
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 1920, height: 1080) }
    override var visibleFrame: NSRect { frame }
}
