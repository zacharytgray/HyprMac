import XCTest
@testable import HyprMac

final class TiledDragTransactionTests: XCTestCase {
    private final class FakeAX {
        var frames: [CGWindowID: CGRect]
        var generation: UInt64 = 1
        var writes: [(CGWindowID, CGRect)] = []
        var reads = 0
        var readIDs: [CGWindowID] = []
        var readError: AXError?
        var time: TimeInterval = 0
        var callAdvance: TimeInterval = 0
        var writeErrors: [AXError] = []
        var readErrors: [AXError] = []
        var onWrite: (() -> Void)?
        var forcedSizes: [CGSize] = []
        var sizeUndershoot: CGFloat = 0
        var readDrift: CGFloat = 0
        var readNumber: CGFloat = 0
        /// seconds a window takes to answer a position write, a position
        /// read, or the enhanced-UI read before its writes. a call whose
        /// timeout is shorter uses the whole timeout and gets
        /// `cannotComplete`, the way AX gives up on a busy app
        var positionWriteAnswer: [CGWindowID: TimeInterval] = [:]
        var positionReadAnswer: [CGWindowID: TimeInterval] = [:]
        var beginAnswer: [CGWindowID: TimeInterval] = [:]
        /// the call timeout each slow call was given, in order
        var slowCallTimeouts: [TimeInterval] = []

        init(frames: [CGWindowID: CGRect]) { self.frames = frames }

        private func answers(_ answer: TimeInterval?, within timeout: TimeInterval) -> Bool {
            guard let answer else { return true }
            slowCallTimeouts.append(timeout)
            time += min(answer, timeout)
            return answer <= timeout
        }

        func factory(windows: [CGWindowID: HyprWindow], current: @escaping () -> UInt64) -> FrameSizingIO {
            var pendingSizes: [CGWindowID: CGSize] = [:]
            var io = FrameSizingIO(
                setMessagingTimeout: { _, _ in .success },
                writeSize: { [unowned self] id, size, _ in
                    onWrite?()
                    if !writeErrors.isEmpty {
                        let error = writeErrors.removeFirst()
                        if error != .success { return error }
                    }
                    pendingSizes[id] = size
                    frames[id]?.size = forcedSizes.isEmpty
                        ? CGSize(width: size.width - sizeUndershoot, height: size.height)
                        : forcedSizes.removeFirst()
                    writes.append((id, frames[id] ?? CGRect(origin: .zero, size: size)))
                    return .success
                },
                writePosition: { [unowned self] id, point, timeout in
                    onWrite?()
                    guard answers(positionWriteAnswer[id], within: timeout) else { return .cannotComplete }
                    if !writeErrors.isEmpty {
                        let error = writeErrors.removeFirst()
                        if error != .success { return error }
                    }
                    frames[id]?.origin = point
                    if let size = pendingSizes[id] { frames[id]?.size = size }
                    writes.append((id, frames[id] ?? CGRect(origin: point, size: .zero)))
                    return .success
                },
                readPosition: { [unowned self] id, timeout in
                    reads += 1
                    readIDs.append(id)
                    time += callAdvance
                    guard answers(positionReadAnswer[id], within: timeout) else {
                        return (.cannotComplete, nil)
                    }
                    if let readError { return (readError, nil) }
                    if !readErrors.isEmpty {
                        let error = readErrors.removeFirst()
                        if error != .success { return (error, nil) }
                    }
                    guard var origin = frames[id]?.origin else { return (.invalidUIElement, nil) }
                    readNumber += 1
                    origin.x += readDrift * readNumber
                    return (.success, origin)
                },
                readSize: { [unowned self] id, _ in
                    reads += 1
                    readIDs.append(id)
                    time += callAdvance
                    if let readError { return (readError, nil) }
                    if !readErrors.isEmpty {
                        let error = readErrors.removeFirst()
                        if error != .success { return (error, nil) }
                    }
                    return (.success, frames[id]?.size)
                },
                now: { [unowned self] in time },
                sleep: { [unowned self] interval in time += interval },
                currentGeneration: current
            )
            io.beginFrameWrite = { [unowned self] id, timeout, _ in
                answers(beginAnswer[id], within: timeout)
                    ? .ready(.noop(windowID: id)) : .failed(.cannotComplete)
            }
            return io
        }
    }

    private func fixture(maxDepth: Int = 3) -> (BSPTree, [CGWindowID: HyprWindow], TiledDragContext) {
        let tree = BSPTree()
        let windows = [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)]
        windows.forEach { _ = tree.insert($0, maxDepth: 4) }
        let context = TiledDragContext(
            workspace: 1, physicalDisplayID: 77,
            usableFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            gap: 8, padding: 8, maxDepth: maxDepth,
            memberIDs: Set(windows.map(\.windowID)), floatingIDs: [],
            fingerprint: tree.structuralFingerprint())
        return (tree, Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) }), context)
    }

    func testCaptureUsesActualFramesOnceAndIsImmutable() {
        let (tree, windows, context) = fixture()
        let originals = Dictionary(uniqueKeysWithValues: tree.layout(in: context.usableFrame,
            gap: context.gap, padding: context.padding).map { ($0.0.windowID, $0.1) })
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        let result = transaction.capture(draggedID: 1, tree: tree, context: context,
                                         generation: 1, currentContext: { context })
        guard case let .captured(snapshot) = result else { return XCTFail("capture failed") }
        XCTAssertEqual(snapshot.originalFrames, originals)
        XCTAssertEqual(fake.reads, originals.count * 2)
        fake.frames[1] = .zero
        XCTAssertEqual(snapshot.originalFrames[1], originals[1])
        XCTAssertEqual(snapshot.originalTree.structuralFingerprint(), context.fingerprint)
        XCTAssertEqual(windows.count, 3)
    }

    func testCaptureReadFailureIsUnknownAndNeverWrites() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        fake.readError = .cannotComplete
        guard case .unknown = TiledDragTransaction(ioFactory: fake.factory).capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("failed read must be unknown") }
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testCaptureTimeoutIsUnknownAndNeverWrites() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        fake.callAdvance = 1
        guard case .unknown(.deadlineExceeded) = TiledDragTransaction(ioFactory: fake.factory).capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("slow capture must time out") }
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testCaptureStaleContextIsSupersededAndNeverWrites() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        guard case .unknown(.superseded) = TiledDragTransaction(ioFactory: fake.factory).capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { nil }) else { return XCTFail("stale capture must be superseded") }
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testCaptureFloatingWindowIsIneligibleAndNeverWrites() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let changed = replacing(context, floatingIDs: [1])
        guard case .ineligible(.floating) = TiledDragTransaction(ioFactory: fake.factory).capture(
            draggedID: 1, tree: tree, context: changed, generation: 1,
            currentContext: { changed }) else { return XCTFail("floating capture must be ineligible") }
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testCaptureInTheScratchpadWorksLikeAnyWorkspaceAndNeverWrites() {
        // the layer's tiles drag and swap like a workspace's
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let changed = replacing(context, workspace: TilingEngine.scratchpadWorkspace)
        guard case .captured = TiledDragTransaction(ioFactory: fake.factory).capture(
            draggedID: 1, tree: tree, context: changed, generation: 1,
            currentContext: { changed }) else { return XCTFail("scratchpad capture must be captured") }
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testPointerCaptureReadsTilesAndOccludersOnceAndPublishesCompleteFrames() {
        let (tree, _, context) = fixture()
        let occluder = makeWindow(id: 40)
        var frames = layoutFrames(tree, context)
        frames[40] = CGRect(x: 900, y: 700, width: 100, height: 50)
        let fake = FakeAX(frames: frames)
        var published: [CGWindowID: CGRect]?
        let result = TiledDragTransaction(ioFactory: fake.factory).capture(
            pointer: center(frames[1]!), tree: tree, context: context,
            occludingWindows: [occluder], generation: 1, currentContext: { context },
            onCapturedFrames: { published = $0 })
        XCTAssertEqual(published, frames)
        XCTAssertEqual(fake.reads, frames.count * 2)
        guard case let .captured(snapshot) = result else { return XCTFail("capture failed") }
        XCTAssertEqual(snapshot.draggedID, 1)
        XCTAssertEqual(snapshot.originalFrames, frames.filter { context.memberIDs.contains($0.key) })
    }

    func testPointerCapturePublishesCompleteFramesBeforeRejectingOccludedHit() {
        let (tree, _, context) = fixture()
        let occluder = makeWindow(id: 40)
        var frames = layoutFrames(tree, context)
        frames[40] = frames[1]
        let fake = FakeAX(frames: frames)
        var published: [CGWindowID: CGRect]?
        let result = TiledDragTransaction(ioFactory: fake.factory).capture(
            pointer: center(frames[1]!), tree: tree, context: context,
            occludingWindows: [occluder], generation: 1, currentContext: { context },
            onCapturedFrames: { published = $0 })
        XCTAssertEqual(published, frames)
        XCTAssertTrue(fake.writes.isEmpty)
        guard case .ineligible(.noTarget) = result else {
            return XCTFail("occluded tile must not be captured")
        }
    }

    func testPointerCaptureRejectsAmbiguousTileHit() {
        let (tree, _, context) = fixture()
        var frames = layoutFrames(tree, context)
        frames[2] = frames[1]
        let fake = FakeAX(frames: frames)
        guard case .ineligible(.noTarget) = TiledDragTransaction(ioFactory: fake.factory).capture(
            pointer: center(frames[1]!), tree: tree, context: context,
            occludingWindows: [], generation: 1, currentContext: { context }) else {
            return XCTFail("ambiguous tile hit must be rejected")
        }
    }

    func testPointerCaptureReadFailureIsUnknownAndDoesNotPublish() {
        let (tree, _, context) = fixture()
        let frames = layoutFrames(tree, context)
        let fake = FakeAX(frames: frames)
        fake.readError = .cannotComplete
        var published = false
        let result = TiledDragTransaction(ioFactory: fake.factory).capture(
            pointer: center(frames[1]!), tree: tree, context: context,
            occludingWindows: [], generation: 1, currentContext: { context },
            onCapturedFrames: { _ in published = true })
        guard case .unknown(.readFailed(_, .cannotComplete)) = result else {
            return XCTFail("failed combined read must be unknown")
        }
        XCTAssertFalse(published)
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testPointerCaptureRejectsNonfinitePointer() {
        let (tree, _, context) = fixture()
        let frames = layoutFrames(tree, context)
        let fake = FakeAX(frames: frames)
        guard case .ineligible(.noTarget) = TiledDragTransaction(ioFactory: fake.factory).capture(
            pointer: CGPoint(x: CGFloat.nan, y: 100), tree: tree, context: context,
            occludingWindows: [], generation: 1, currentContext: { context }) else {
            return XCTFail("nonfinite pointer must be rejected")
        }
        XCTAssertEqual(fake.reads, 0)
    }

    func testPointerCaptureRejectsFloatingContext() {
        let (tree, _, base) = fixture()
        let context = replacing(base, floatingIDs: [1])
        let fake = FakeAX(frames: layoutFrames(tree, context))
        guard case .ineligible(.floating) = TiledDragTransaction(ioFactory: fake.factory).capture(
            pointer: CGPoint(x: 100, y: 100), tree: tree, context: context,
            occludingWindows: [], generation: 1, currentContext: { context }) else {
            return XCTFail("floating context must be rejected")
        }
        XCTAssertEqual(fake.reads, 0)
    }

    func testPointerCaptureInTheScratchpadContext() {
        let (tree, _, base) = fixture()
        let context = replacing(base, workspace: TilingEngine.scratchpadWorkspace)
        let frames = layoutFrames(tree, context)
        let fake = FakeAX(frames: frames)
        guard case let .captured(snapshot) = TiledDragTransaction(ioFactory: fake.factory).capture(
            pointer: center(frames[1]!), tree: tree, context: context,
            occludingWindows: [], generation: 1, currentContext: { context }) else {
            return XCTFail("scratchpad context must capture")
        }
        XCTAssertEqual(snapshot.draggedID, 1)
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testPointerCaptureRejectsDuplicateAcrossTilesAndOccludersBeforeReads() {
        let (tree, windows, context) = fixture()
        let frames = layoutFrames(tree, context)
        let fake = FakeAX(frames: frames)
        guard case .unknown(.duplicateWindowID(1)) = TiledDragTransaction(ioFactory: fake.factory).capture(
            pointer: center(frames[1]!), tree: tree, context: context,
            occludingWindows: [windows[1]!], generation: 1, currentContext: { context }) else {
            return XCTFail("duplicate tile and occluder ID must be rejected")
        }
        XCTAssertEqual(fake.reads, 0)
    }

    func testAcceptedInsertionReturnsCandidateWithoutMutatingOriginal() {
        let (tree, _, context) = fixture()
        let originals = Dictionary(uniqueKeysWithValues: tree.layout(in: context.usableFrame,
            gap: context.gap, padding: context.padding).map { ($0.0.windowID, $0.1) })
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1, currentContext: { context }) else {
            return XCTFail("capture failed")
        }
        guard case let .committed(candidate, _, _) = transaction.drop(
            snapshot, mode: .insert(targetID: 2, edge: .left), currentContext: { context }) else {
            return XCTFail("drop did not commit")
        }
        XCTAssertEqual(tree.structuralFingerprint(), context.fingerprint)
        XCTAssertNotEqual(candidate.structuralFingerprint(), context.fingerprint)
    }

    func testStaleContextPerformsNoWrites() {
        let (tree, _, context) = fixture()
        let originals = Dictionary(uniqueKeysWithValues: tree.layout(in: context.usableFrame,
            gap: context.gap, padding: context.padding).map { ($0.0.windowID, $0.1) })
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1, currentContext: { context }) else {
            return XCTFail("capture failed")
        }
        var stale = context
        stale = TiledDragContext(workspace: 2, physicalDisplayID: stale.physicalDisplayID,
            usableFrame: stale.usableFrame, gap: stale.gap, padding: stale.padding,
            maxDepth: stale.maxDepth, memberIDs: stale.memberIDs,
            floatingIDs: stale.floatingIDs, fingerprint: stale.fingerprint)
        XCTAssertSuperseded(transaction.drop(snapshot, mode: .insert(targetID: 2, edge: .right),
                                              currentContext: { stale }))
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testMaxDepthRejectsCandidateButVerifiesOriginalFrameRestoration() {
        let (tree, _, context) = fixture(maxDepth: 1)
        let originals = Dictionary(uniqueKeysWithValues: tree.layout(in: context.usableFrame,
            gap: context.gap, padding: context.padding).map { ($0.0.windowID, $0.1) })
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1, currentContext: { context }) else {
            return XCTFail("capture failed")
        }
        fake.frames[1]?.origin.x += 100
        _ = transaction.drop(snapshot, mode: .insert(targetID: 2, edge: .left), currentContext: { context })
        XCTAssertEqual(fake.writes.count, originals.count * 3,
                       "max-depth rejection may write only one resize-move-resize restoration per original")
        XCTAssertEqual(fake.frames, originals)
        XCTAssertEqual(tree.structuralFingerprint(), context.fingerprint)
    }

    func testNoTargetRestoresMovedWindowAndMissingCaptureDoesNoWrites() {
        let (tree, _, context) = fixture()
        let originals = Dictionary(uniqueKeysWithValues: tree.layout(in: context.usableFrame,
            gap: context.gap, padding: context.padding).map { ($0.0.windowID, $0.1) })
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1, currentContext: { context }) else {
            return XCTFail("capture failed")
        }
        fake.frames[1]?.origin.x += 100
        _ = transaction.drop(snapshot, mode: nil, currentContext: { context })
        XCTAssertEqual(fake.frames, originals)

        fake.writes.removeAll()
        fake.frames.removeValue(forKey: 2)
        guard case .unknown = transaction.capture(draggedID: 1, tree: tree, context: context,
                                                  generation: 1, currentContext: { context }) else {
            return XCTFail("missing frame must be unknown")
        }
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testInvalidTargetRestoresMovedWindow() {
        let (tree, _, context) = fixture()
        let originals = layoutFrames(tree, context)
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.frames[1]?.origin.x += 100
        guard case .rejectedRestored = transaction.drop(
            snapshot, mode: .insert(targetID: 99, edge: .left), currentContext: { context }) else {
            return XCTFail("invalid target must restore")
        }
        XCTAssertEqual(fake.frames, originals)
    }

    func testAcceptedLeftEdge() { assertAccepted(edge: .left) }
    func testAcceptedRightEdge() { assertAccepted(edge: .right) }
    func testAcceptedTopEdge() { assertAccepted(edge: .top) }
    func testAcceptedBottomEdge() { assertAccepted(edge: .bottom) }

    func testSwapUsesCandidateAndPreservesSource() {
        let (tree, _, context) = fixture()
        let originalOrder = tree.allWindows.map(\.windowID)
        let originalFingerprint = tree.structuralFingerprint()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        guard case let .committed(candidate, _, _) = transaction.drop(
            snapshot, mode: .swap(targetID: 2), currentContext: { context }) else {
            return XCTFail("swap did not commit")
        }
        XCTAssertEqual(candidate.allWindows.map(\.windowID), [2, 1, 3])
        XCTAssertEqual(tree.allWindows.map(\.windowID), originalOrder)
        XCTAssertEqual(tree.structuralFingerprint(), originalFingerprint)
    }

    func testCandidateWriteFailureRestoresFramesAndLeavesSourceUntouched() {
        let (tree, _, context) = fixture()
        let originals = layoutFrames(tree, context)
        let fingerprint = tree.structuralFingerprint()
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.writeErrors = [.cannotComplete]
        let outcome = transaction.drop(snapshot, mode: .insert(targetID: 2, edge: .right),
                                       currentContext: { context })
        guard case .rejectedRestored = outcome else { return XCTFail("expected verified restore") }
        XCTAssertEqual(fake.frames, originals)
        XCTAssertEqual(tree.structuralFingerprint(), fingerprint)
    }

    func testRestorationReadFailureIsDegraded() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.writeErrors = [.cannotComplete]
        fake.readError = .cannotComplete
        guard case let .degraded(candidate, restoration, _, _) = transaction.drop(
            snapshot, mode: .insert(targetID: 2, edge: .right), currentContext: { context }) else {
            return XCTFail("expected degraded restoration")
        }
        XCTAssertNotNil(candidate)
        XCTAssertNotNil(restoration)
    }

    func testRestorationGeometryRejectionIsDegraded() {
        let (tree, _, context) = fixture()
        let originals = layoutFrames(tree, context)
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.writeErrors = [.cannotComplete]
        let wrong = CGSize(width: originals[1]!.width + 40, height: originals[1]!.height)
        fake.forcedSizes = [wrong, wrong] + tree.allWindows.dropFirst().flatMap {
            [originals[$0.windowID]!.size, originals[$0.windowID]!.size]
        }
        fake.callAdvance = 0.02
        guard case let .degraded(_, restoration, _, _) = transaction.drop(
            snapshot, mode: .insert(targetID: 2, edge: .right), currentContext: { context }) else {
            return XCTFail("expected degraded restoration")
        }
        guard case .geometryMismatch(1) = restoration else {
            return XCTFail("expected restoration geometry rejection")
        }
    }

    func testCandidateReadFailureRestoresOriginalFrames() {
        let (tree, _, context) = fixture()
        let originals = layoutFrames(tree, context)
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.readErrors = [.cannotComplete]
        guard case .rejectedRestored = transaction.drop(
            snapshot, mode: .insert(targetID: 2, edge: .right),
            currentContext: { context }) else { return XCTFail("expected verified restore") }
        XCTAssertEqual(fake.frames, originals)
    }

    func testContextChangeDuringAXDoesNotWriteOriginalFrames() {
        let (tree, _, context) = fixture()
        let originals = layoutFrames(tree, context)
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        var live: TiledDragContext? = context
        var changed = false
        fake.onWrite = {
            guard !changed else { return }
            changed = true
            live = nil
        }
        fake.writes.removeAll()
        XCTAssertTrue(isSuperseded(transaction.drop(
            snapshot, mode: .insert(targetID: 2, edge: .left),
            currentContext: { live })))
        XCTAssertFalse(fake.writes.contains { originals[$0.0] == $0.1 },
                       "superseded candidate must not roll back old frames")
    }

    func testEveryContextDimensionInvalidatesWithoutWrites() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        let contexts = [
            contextCopy(context, workspace: 2),
            contextCopy(context, displayID: 78),
            contextCopy(context, usableFrame: context.usableFrame.insetBy(dx: 1, dy: 0)),
            contextCopy(context, gap: context.gap + 1),
            contextCopy(context, padding: context.padding + 1),
            contextCopy(context, maxDepth: context.maxDepth + 1),
            contextCopy(context, memberIDs: [1, 2]),
            contextCopy(context, floatingIDs: [3]),
            contextCopy(context, fingerprint: .init(nodes: []))
        ]
        fake.writes.removeAll()
        for changed in contexts {
            XCTAssertTrue(isSuperseded(transaction.drop(
                snapshot, mode: .insert(targetID: 2, edge: .left), currentContext: { changed })))
        }
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testLiveSourceMutationInvalidatesEvenWhenResolverReturnsCapturedContext() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        _ = tree.insert(makeWindow(id: 99), maxDepth: 5)
        fake.writes.removeAll()
        XCTAssertTrue(isSuperseded(transaction.drop(
            snapshot, mode: .insert(targetID: 2, edge: .left), currentContext: { context })))
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testSwapOverCurrentMaxDepthRestoresWithoutCandidateWrites() {
        let (tree, _, base) = fixture()
        let context = contextCopy(base, maxDepth: 1)
        let originals = layoutFrames(tree, context)
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.writes.removeAll()
        guard case .rejectedRestored = transaction.drop(
            snapshot, mode: .swap(targetID: 2), currentContext: { context }) else {
            return XCTFail("over-depth swap must restore")
        }
        XCTAssertEqual(fake.writes.count, originals.count * 3)
        XCTAssertEqual(fake.frames, originals)
    }

    func testZeroGapTouchingAndFractionalGeometryAreAccepted() {
        let (tree, _, base) = fixture()
        tree.root.splitRatio = 1.0 / 3.0
        let context = contextCopy(base, usableFrame: CGRect(x: 0.25, y: 0.5,
            width: 1200.5, height: 800.25), gap: 0, fingerprint: tree.structuralFingerprint())
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        guard case .committed = transaction.drop(
            snapshot, mode: .swap(targetID: 2), currentContext: { context }) else {
            return XCTFail("touching fractional layout must be accepted")
        }
    }

    func testNeverSettledRestorationIsDegraded() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.readDrift = 2
        fake.readNumber = 0
        guard case let .degraded(_, restoration, _, _) = transaction.drop(
            snapshot, mode: nil, currentContext: { context }) else {
            return XCTFail("unsettled restoration must degrade")
        }
        XCTAssertEqual(restoration, .attemptsExhausted)
    }

    func testWindowMissingDuringCandidateIsDegraded() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.frames.removeValue(forKey: 2)
        guard case let .degraded(candidate, restoration, _, _) = transaction.drop(
            snapshot, mode: .insert(targetID: 2, edge: .left), currentContext: { context }) else {
            return XCTFail("missing window must degrade")
        }
        XCTAssertNotNil(candidate)
        XCTAssertNotNil(restoration)
    }

    func testFourColumnCandidateAppliesThroughRealSizingTransaction() {
        let tree = BSPTree()
        let windows = (1...4).map { makeWindow(id: CGWindowID($0)) }
        windows.forEach { _ = tree.insert($0, maxDepth: 4) }
        forceHorizontal(tree.root)
        let context = TiledDragContext(
            workspace: 1, physicalDisplayID: 77,
            usableFrame: CGRect(x: 0, y: 0, width: 1600, height: 800),
            gap: 8, padding: 0, maxDepth: 4,
            memberIDs: Set(windows.map(\.windowID)), floatingIDs: [],
            fingerprint: tree.structuralFingerprint())
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        guard case let .committed(_, frames, _) = transaction.drop(
            snapshot, mode: .insert(targetID: 2, edge: .left), currentContext: { context }) else {
            return XCTFail("four-column candidate must commit")
        }
        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(Set(frames.values.map(\.minX)).count, 4)
    }

    func testDropReleaseReadsOnlyDraggedWindowAndCommitsResizeOverThreshold() {
        let (tree, _, context) = fixture()
        let originals = layoutFrames(tree, context)
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.frames[1]!.size.width += 21
        fake.reads = 0
        fake.readIDs.removeAll()
        var classificationReadIDs: [CGWindowID] = []
        fake.onWrite = {
            if classificationReadIDs.isEmpty { classificationReadIDs = fake.readIDs }
        }
        guard case let .committed(candidate, actualFrames, _) = transaction.dropRelease(
            snapshot, mode: nil, currentContext: { context }) else {
            return XCTFail("manual resize must commit a candidate")
        }
        XCTAssertEqual(classificationReadIDs, [1, 1],
                       "release classification reads only dragged position and size")
        XCTAssertEqual(actualFrames, fake.frames)
        XCTAssertNotEqual(candidate.structuralFingerprint(), context.fingerprint)
        XCTAssertEqual(tree.structuralFingerprint(), context.fingerprint)
    }

    func testOffMonitorSizeChangeWithoutTargetRestoresInsteadOfResizingSourceTree() {
        let (tree, _, context) = fixture()
        let originals = layoutFrames(tree, context)
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.frames[1] = CGRect(x: 1400, y: 100, width: 800, height: 500)

        guard case .rejectedRestored(reason: .preflight(.noTarget), _) =
                transaction.dropRelease(snapshot, mode: nil, currentContext: { context }) else {
            return XCTFail("off-monitor release must restore the source layout")
        }
        XCTAssertEqual(fake.frames, originals)
        XCTAssertEqual(tree.structuralFingerprint(), context.fingerprint)
    }

    func testInsertionUsesKnownMinimumBeforeWritingCandidate() {
        let tree = BSPTree()
        let windows = [makeWindow(id: 1), makeWindow(id: 2)]
        windows.forEach { _ = tree.insert($0, maxDepth: 3) }
        let context = TiledDragContext(
            workspace: 1, physicalDisplayID: 77,
            usableFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            gap: 8, padding: 8, maxDepth: 3,
            memberIDs: Set(windows.map(\.windowID)), floatingIDs: [],
            fingerprint: tree.structuralFingerprint()
        )
        let originals = layoutFrames(tree, context)
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(
            ioFactory: fake.factory,
            minimumSize: { $0?.windowID == 1 ? CGSize(width: 619, height: 0) : .zero }
        )
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 2, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.frames[2]!.origin.x += 2

        guard case let .committed(_, actualFrames, _) = transaction.dropRelease(
            snapshot, mode: .insert(targetID: 1, edge: .right),
            currentContext: { context }) else {
            return XCTFail("known fitting minimum must not reject the insertion")
        }
        XCTAssertGreaterThanOrEqual(actualFrames[1]?.width ?? 0, 619)
    }

    func testDropReleaseAtThresholdUsesOrdinaryNoTargetRestoration() {
        let (tree, _, context) = fixture()
        let originals = layoutFrames(tree, context)
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.frames[1]!.size.width += 20
        guard case .rejectedRestored(reason: .preflight(.noTarget), _) = transaction.dropRelease(
            snapshot, mode: nil, currentContext: { context }) else {
            return XCTFail("threshold-sized change must use ordinary drop")
        }
        XCTAssertEqual(fake.frames, originals)
    }

    func testNoTargetRestorationRejectsCellQuantizedUndershoot() throws {
        let (tree, _, context) = fixture()
        let originals = layoutFrames(tree, context)
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        var moved = try XCTUnwrap(fake.frames[1])
        moved.origin.x += 2
        fake.frames[1] = moved
        fake.sizeUndershoot = 6

        guard case let .degraded(candidateReason, restorationReason, actualFrames, _) =
                transaction.dropRelease(snapshot, mode: nil, currentContext: { context }) else {
            return XCTFail("inexact restoration must be degraded")
        }
        XCTAssertEqual(candidateReason, .preflight(.noTarget))
        XCTAssertEqual(restorationReason, .geometryMismatch(1))
        XCTAssertEqual(actualFrames[1]?.width, originals[1].map { $0.width - 6 })
    }

    func testDropReleaseClassificationReadFailureRestoresOriginals() {
        let (tree, _, context) = fixture()
        let originals = layoutFrames(tree, context)
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.frames[1]!.size.width += 40
        fake.readErrors = [.cannotComplete]
        guard case .rejectedRestored(reason: .sizing(.readFailed(1, .cannotComplete)), _) =
                transaction.dropRelease(snapshot, mode: nil, currentContext: { context }) else {
            return XCTFail("classification failure must be reported after restoration")
        }
        XCTAssertEqual(fake.frames, originals)
    }

    func testDropReleaseStaleContextDoesNoReadsOrWrites() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.reads = 0
        fake.writes.removeAll()
        XCTAssertTrue(isSuperseded(transaction.dropRelease(
            snapshot, mode: nil, currentContext: { nil })))
        XCTAssertEqual(fake.reads, 0)
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testValidatorAllowsNumericalSlackInsideGapEpsilonButRejectsOutside() {
        let targets = [
            FrameSizingAttempt.Target(windowID: 1,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            FrameSizingAttempt.Target(windowID: 2,
                frame: CGRect(x: 108, y: 0, width: 100, height: 100))
        ]
        let fake = FakeAX(frames: [:])
        let attempt = FrameSizingAttempt(io: fake.factory(windows: [:], current: { 1 }))
        var frames = Dictionary(uniqueKeysWithValues: targets.map { ($0.windowID, $0.frame) })
        // a 28 pt gap less the 20 pt cell allowance puts the floor at the
        // windows' own 8 pt separation, so only the epsilon is under test
        frames[2]!.origin.x -= 0.00005
        XCTAssertEqual(attempt.validateFrames(targets: targets, actualFrames: frames,
                                               usableFrame: CGRect(x: 0, y: 0, width: 300, height: 100),
                                               gap: 28).verdict, .accepted)
        frames[2]!.origin.x -= 0.00015
        XCTAssertEqual(attempt.validateFrames(targets: targets, actualFrames: frames,
                                               usableFrame: CGRect(x: 0, y: 0, width: 300, height: 100),
                                               gap: 28).verdict, .rejected(.gapViolation(1, 2)))
    }

    func testValidatorAcceptsOnePointPositionAndSizeButRejectsMore() {
        let target = FrameSizingAttempt.Target(windowID: 1,
            frame: CGRect(x: 10, y: 10, width: 100, height: 100))
        let fake = FakeAX(frames: [:])
        let attempt = FrameSizingAttempt(io: fake.factory(windows: [:], current: { 1 }))
        let usable = CGRect(x: 0, y: 0, width: 300, height: 300)
        let atBoundary = CGRect(x: 11, y: 10, width: 101, height: 100)
        XCTAssertEqual(attempt.validateFrames(targets: [target], actualFrames: [1: atBoundary],
                                               usableFrame: usable, gap: 0).verdict, .accepted)
        let beyond = CGRect(x: 11.0001, y: 10, width: 101.0001, height: 100)
        XCTAssertEqual(attempt.validateFrames(targets: [target], actualFrames: [1: beyond],
                                               usableFrame: usable, gap: 0).verdict,
                       .rejected(.geometryMismatch(1)))
    }

    func testValidatorRejectsOverlapBeyondTheAggregateSlack() {
        let fake = FakeAX(frames: [:])
        let attempt = FrameSizingAttempt(io: fake.factory(windows: [:], current: { 1 }))
        func verdict(secondX: CGFloat) -> FrameSizingAttempt.Verdict {
            let targets = [
                FrameSizingAttempt.Target(windowID: 1,
                    frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
                FrameSizingAttempt.Target(windowID: 2,
                    frame: CGRect(x: secondX, y: 0, width: 100, height: 100))
            ]
            let frames = Dictionary(uniqueKeysWithValues: targets.map { ($0.windowID, $0.frame) })
            return attempt.validateFrames(targets: targets, actualFrames: frames,
                                          usableFrame: CGRect(x: 0, y: 0, width: 300, height: 100),
                                          gap: 0).verdict
        }
        // one point of overlap on both axes is comparison slack, no more
        XCTAssertEqual(verdict(secondX: 99), .accepted)
        XCTAssertEqual(verdict(secondX: 98.99999), .rejected(.overlap(1, 2)))
    }

    func testDropReleaseHeightChangeOverThresholdCommitsResize() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.frames[1]!.size.height += 21
        guard case let .committed(candidate, _, _) = transaction.dropRelease(
            snapshot, mode: .insert(targetID: 2, edge: .left),
            currentContext: { context }) else {
            return XCTFail("height-only manual resize must commit")
        }
        XCTAssertEqual(candidate.structuralFingerprint(), context.fingerprint,
                       "height delta must select resize rather than insertion")
    }

    func testResizeCandidateWriteRefusalRestoresPredragFrames() {
        let (tree, _, context) = fixture()
        let originals = layoutFrames(tree, context)
        let fake = FakeAX(frames: originals)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.frames[1]!.size.width += 21
        fake.writeErrors = [.cannotComplete]
        guard case .rejectedRestored(reason: .sizing(.writeFailed(_, .cannotComplete)), _) =
                transaction.dropRelease(snapshot, mode: nil, currentContext: { context }) else {
            return XCTFail("resize refusal must restore originals")
        }
        XCTAssertEqual(fake.frames, originals)
        XCTAssertEqual(tree.structuralFingerprint(), context.fingerprint)
    }

    func testClassificationFailureSupersededDuringRollbackReturnsSuperseded() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.readErrors = [.cannotComplete]
        var current: TiledDragContext? = context
        fake.onWrite = { current = nil }
        XCTAssertTrue(isSuperseded(transaction.dropRelease(
            snapshot, mode: nil, currentContext: { current })))
    }

    func testDropReleaseIgnoresContentDragWhenWindowDidNotMove() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.writes.removeAll()
        guard case .ignored = transaction.dropRelease(
            snapshot, mode: .insert(targetID: 2, edge: .left),
            currentContext: { context }) else {
            return XCTFail("content drag without window movement must be ignored")
        }
        XCTAssertTrue(fake.writes.isEmpty)
        XCTAssertEqual(tree.structuralFingerprint(), context.fingerprint)
    }

    func testDropReleaseIgnoresMovementAtPositionAndSizeTolerance() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.frames[1]!.origin.x += 1
        fake.frames[1]!.origin.y -= 1
        fake.frames[1]!.size.width += 1
        fake.frames[1]!.size.height -= 1
        guard case .ignored = transaction.dropRelease(
            snapshot, mode: .insert(targetID: 2, edge: .left),
            currentContext: { context }) else {
            return XCTFail("movement at configured tolerance must be ignored")
        }
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testDropReleaseTwoPointMovementStillAppliesShortDragInsertion() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.frames[1]!.origin.x += 2
        guard case .committed = transaction.dropRelease(
            snapshot, mode: .insert(targetID: 2, edge: .left),
            currentContext: { context }) else {
            return XCTFail("two-point actual movement must apply insertion")
        }
        XCTAssertFalse(fake.writes.isEmpty)
    }

    // MARK: - across trees

    func testAcrossTreesInsertCommitsBothCandidatesWithoutTouchingEitherTree() {
        let (tree, context, target, frames) = crossFixture()
        let fake = FakeAX(frames: frames)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        let release = CGRect(origin: CGPoint(x: 1300, y: 100), size: frames[1]!.size)
        fake.frames[1] = release
        let slot = frames[11]!

        guard case let .acrossTrees(.committed(source, actual, _), cross) = transaction.dropAcrossTrees(
            snapshot, into: target, pointer: CGPoint(x: slot.midX, y: slot.maxY - 2),
            swapRequested: false, releaseFrame: release, currentContext: { context }) else {
            return XCTFail("expected a committed drop across trees")
        }
        XCTAssertEqual(source.allWindows.map(\.windowID), [2, 3])
        XCTAssertEqual(cross.targetCandidate?.allWindows.map(\.windowID), [10, 11, 1])
        XCTAssertEqual(cross.moves, [1: 2])
        XCTAssertEqual(tree.structuralFingerprint(), context.fingerprint)
        XCTAssertEqual(target.tree.structuralFingerprint(), target.context.fingerprint)
        XCTAssertEqual(Set(actual.keys), [1, 2, 3, 10, 11])
        XCTAssertTrue(target.context.usableFrame.contains(actual[1]!))
        XCTAssertTrue(context.usableFrame.contains(actual[2]!))
    }

    func testAcrossTreesSwapThatCannotFitAKnownMinimumRestoresOnlyTheSource() {
        let (tree, context, target, frames) = crossFixture()
        let fake = FakeAX(frames: frames)
        // 10 cannot shrink into the dragged window's slot, even at 0.85
        let transaction = TiledDragTransaction(
            ioFactory: fake.factory,
            minimumSize: { $0?.windowID == 10 ? CGSize(width: 1100, height: 0) : .zero })
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        let release = CGRect(origin: CGPoint(x: 1300, y: 100), size: frames[1]!.size)
        fake.frames[1] = release

        let outcome = transaction.dropAcrossTrees(
            snapshot, into: target, pointer: center(frames[10]!), swapRequested: true,
            releaseFrame: release, currentContext: { context })

        // refused before the first write: the release screen was only read
        guard case let .rejectedRestored(reason, restored) = outcome else {
            return XCTFail("expected an ordinary restore of the source, got \(outcome)")
        }
        XCTAssertEqual(reason, .preflight(.noRoom))
        XCTAssertEqual(fake.frames, frames)
        XCTAssertEqual(Set(restored.keys), [1, 2, 3])
        XCTAssertEqual(Set(fake.writes.map { $0.0 }), [1, 2, 3], "nothing written on the release screen")
        XCTAssertEqual(fake.writes.count, 3 * 3, "one resize-move-resize per source original")
    }

    func testAcrossTreesSourceWriteFailureAfterTheTargetLandedRestoresBothTrees() {
        let (tree, context, target, frames) = crossFixture()
        let fake = FakeAX(frames: frames)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        let release = CGRect(origin: CGPoint(x: 1300, y: 100), size: frames[1]!.size)
        fake.frames[1] = release
        // the release screen's three windows take all nine setters, then the
        // source's first one fails
        fake.writeErrors = Array(repeating: .success, count: 9) + [.cannotComplete]
        let slot = frames[11]!

        let outcome = transaction.dropAcrossTrees(
            snapshot, into: target, pointer: CGPoint(x: slot.midX, y: slot.maxY - 2),
            swapRequested: false, releaseFrame: release, currentContext: { context })

        guard case let .acrossTrees(.rejectedRestored(reason, restored), _) = outcome else {
            return XCTFail("expected a verified rollback of both trees")
        }
        XCTAssertEqual(reason, .sizing(.writeFailed(2, .cannotComplete)))
        XCTAssertEqual(fake.frames, frames)
        XCTAssertEqual(restored, frames)
    }

    func testAcrossTreesStaleTargetDuringWritesIsSupersededWithoutRollback() {
        let (tree, context, fresh, frames) = crossFixture()
        var targetContext: TiledDragContext? = fresh.context
        let target = TiledDragCrossTarget(tree: fresh.tree, context: fresh.context,
                                          currentContext: { targetContext })
        let fake = FakeAX(frames: frames)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        let release = CGRect(origin: CGPoint(x: 1300, y: 100), size: frames[1]!.size)
        fake.frames[1] = release
        fake.onWrite = { targetContext = nil }

        XCTAssertSuperseded(transaction.dropAcrossTrees(
            snapshot, into: target, pointer: center(frames[10]!), swapRequested: false,
            releaseFrame: release, currentContext: { context }))
        XCTAssertEqual(fake.writes.count, 1, "a newer operation owns the geometry")
    }

    func testDropReleaseHandsOnlyAPlainMoveToTheCrossTreePath() {
        let (tree, _, context) = fixture()
        let frames = layoutFrames(tree, context)
        let fake = FakeAX(frames: frames)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        var moved: [CGRect] = []
        let handoff: (CGRect) -> TiledDragDropOutcome = { frame in
            moved.append(frame)
            return .superseded
        }

        // unmoved: nothing to do
        guard case .ignored = transaction.dropRelease(snapshot, mode: nil,
                                                      currentContext: { context },
                                                      moved: handoff) else {
            return XCTFail("an unmoved window must be ignored")
        }
        // resized off the source: the ordinary restore
        fake.frames[1] = CGRect(x: 1500, y: 100, width: 300, height: 300)
        guard case .rejectedRestored(reason: .preflight(.noTarget), _) = transaction.dropRelease(
            snapshot, mode: nil, currentContext: { context }, moved: handoff) else {
            return XCTFail("a resize candidate must keep the same-tree rule")
        }
        XCTAssertTrue(moved.isEmpty)
        // a plain move goes across, with the frame it was read at
        let release = CGRect(origin: CGPoint(x: 1500, y: 100), size: frames[1]!.size)
        fake.frames[1] = release
        XCTAssertSuperseded(transaction.dropRelease(snapshot, mode: nil,
                                                    currentContext: { context }, moved: handoff))
        XCTAssertEqual(moved, [release])
    }

    func testReleasePolicyRefusesADisabledMonitorAndTheScratchpadLayer() {
        XCTAssertEqual(TiledDragReleasePolicy.resolve(monitorDisabled: false, scratchpadVisible: false,
                                                      visibleWorkspace: { 4 }), .workspace(4))
        XCTAssertEqual(TiledDragReleasePolicy.resolve(monitorDisabled: true, scratchpadVisible: false,
                                                      visibleWorkspace: { 4 }),
                       .refused("monitor disabled"))
        XCTAssertEqual(TiledDragReleasePolicy.resolve(monitorDisabled: false, scratchpadVisible: true,
                                                      visibleWorkspace: { 4 }),
                       .refused("scratchpad visible"))
    }

    // MARK: - AX timeout recovery

    func testAcrossTreesSlowPositionWriteGetsOneLongerTryAndCommits() {
        let (tree, context, target, frames) = crossFixture()
        let fake = FakeAX(frames: frames)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        let release = CGRect(origin: CGPoint(x: 1300, y: 100), size: frames[1]!.size)
        fake.frames[1] = release
        // Messages, live: a position write refused at the 100 ms call timeout
        fake.positionWriteAnswer[1] = 0.15
        let slot = frames[11]!

        guard case let .acrossTrees(.committed(_, actual, progress), cross) = transaction.dropAcrossTrees(
            snapshot, into: target, pointer: CGPoint(x: slot.midX, y: slot.maxY - 2),
            swapRequested: false, releaseFrame: release, currentContext: { context }) else {
            return XCTFail("the longer try must land the drop")
        }
        XCTAssertEqual(fake.slowCallTimeouts, [0.1, 0.25])
        XCTAssertTrue(progress.candidateVerified)
        XCTAssertEqual(cross.moves, [1: 2])
        XCTAssertEqual(actual[1], fake.frames[1])
        XCTAssertTrue(target.context.usableFrame.contains(fake.frames[1]!))
    }

    func testAcrossTreesRollbackThatTimesOutGetsOneLongerTryAndVerifies() {
        let (tree, context, target, frames) = crossFixture()
        let fake = FakeAX(frames: frames)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        let release = CGRect(origin: CGPoint(x: 1300, y: 100), size: frames[1]!.size)
        fake.frames[1] = release
        // the release screen refuses outright, then the dragged window's
        // rollback times out on the read that opens its writes, as Messages did
        fake.writeErrors = [.failure]
        fake.beginAnswer[1] = 0.15
        let slot = frames[11]!

        let outcome = transaction.dropAcrossTrees(
            snapshot, into: target, pointer: CGPoint(x: slot.midX, y: slot.maxY - 2),
            swapRequested: false, releaseFrame: release, currentContext: { context })

        guard case let .acrossTrees(.rejectedRestored(reason, restored), _) = outcome else {
            return XCTFail("the longer try must verify the rollback, got \(outcome)")
        }
        XCTAssertEqual(reason, .sizing(.writeFailed(10, .failure)))
        XCTAssertEqual(fake.slowCallTimeouts, [0.1, 0.25])
        XCTAssertEqual(fake.frames, frames)
        XCTAssertEqual(restored, frames)
    }

    func testSameTreeDropSlowPositionWriteGetsOneLongerTryAndCommits() {
        let (tree, _, context) = fixture()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.positionWriteAnswer[2] = 0.15

        guard case .committed = transaction.drop(snapshot, mode: .insert(targetID: 2, edge: .left),
                                                 currentContext: { context }) else {
            return XCTFail("the longer try must land the drop")
        }
        XCTAssertEqual(fake.slowCallTimeouts, [0.1, 0.25])
    }

    func testSettleReadThatTimesOutGetsOneLongerTry() {
        let (tree, _, context) = fixture()
        let frames = layoutFrames(tree, context)
        let fake = FakeAX(frames: frames)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        fake.positionReadAnswer[1] = 0.15

        // unmoved, once the longer read answers
        guard case .ignored = transaction.dropRelease(snapshot, mode: nil,
                                                      currentContext: { context }) else {
            return XCTFail("the longer read must classify the release")
        }
        XCTAssertEqual(fake.slowCallTimeouts, [0.1, 0.25])
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testSpentDropBudgetCutsTheLongerTries() {
        let (tree, context, target, frames) = crossFixture()
        let fake = FakeAX(frames: frames)
        // the first timeout alone spends this budget
        let transaction = TiledDragTransaction(ioFactory: fake.factory,
                                               budget: TiledDragBudget(limit: 0.05))
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        let release = CGRect(origin: CGPoint(x: 1300, y: 100), size: frames[1]!.size)
        fake.frames[1] = release
        fake.positionWriteAnswer[1] = 0.15
        let slot = frames[11]!

        let outcome = transaction.dropAcrossTrees(
            snapshot, into: target, pointer: CGPoint(x: slot.midX, y: slot.maxY - 2),
            swapRequested: false, releaseFrame: release, currentContext: { context })

        XCTAssertEqual(fake.slowCallTimeouts, [0.1, 0.1],
                       "the candidate and the rollback each get their plain try, no 250 ms one")
        guard case .acrossTrees(.degraded, _) = outcome else {
            return XCTFail("expected the plain outcome, got \(outcome)")
        }
    }

    func testDropBudgetCountsFromTheFirstStart() {
        let budget = TiledDragBudget(limit: 1)
        budget.start(at: 10)
        budget.start(at: 20)
        XCTAssertTrue(budget.allowsRecovery(at: 10.9))
        XCTAssertFalse(budget.allowsRecovery(at: 11))
        XCTAssertTrue(TiledDragBudget(limit: 1).allowsRecovery(at: 50), "an unstarted budget starts now")
        XCTAssertEqual(TiledDragBudget.defaultLimit, 2.5)
    }

    func testCommitWhoseSettersDidNotAllSucceedCannotPublish() {
        var progress = FrameSizingAttempt.Progress()
        progress.targetIDs = [1, 10]
        progress.writesCompleted = [1, 10]
        progress.readbackComplete = true
        progress.readbackStable = true
        XCTAssertNil(TiledDragTransaction.unverifiedCommit(progress))
        progress.writesCompleted = [1]
        XCTAssertEqual(TiledDragTransaction.unverifiedCommit(progress), .writeFailed(10, .failure))
        progress.writesCompleted = [1, 10]
        progress.readbackStable = false
        XCTAssertEqual(TiledDragTransaction.unverifiedCommit(progress), .attemptsExhausted)
    }

    func testTimeoutRecoveryIsOptInAndLeavesAnInstantRefusalAlone() {
        let frames: [CGWindowID: CGRect] = [1: CGRect(x: 0, y: 0, width: 400, height: 300)]
        let targets = [FrameSizingAttempt.Target(windowID: 1,
                                                 frame: CGRect(x: 10, y: 10, width: 400, height: 300))]
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)

        let slow = FakeAX(frames: frames)
        slow.positionWriteAnswer[1] = 0.15
        let plain = FrameSizingTransaction(
            attempt: FrameSizingAttempt(io: slow.factory(windows: [:], current: { 1 })))
            .candidate(targets: targets, usableFrame: bounds, gap: 8, generation: 1)
        XCTAssertEqual(plain.verdict, .rejected(.writeFailed(1, .cannotComplete)))
        XCTAssertEqual(slow.slowCallTimeouts, [0.1], "off unless the caller asks")

        // a cannotComplete that comes straight back is AX refusing, not a timeout
        let quick = FakeAX(frames: frames)
        quick.writeErrors = [.success, .cannotComplete]
        let refused = FrameSizingTransaction(
            attempt: FrameSizingAttempt(io: quick.factory(windows: [:], current: { 1 })),
            recoversTimeouts: true)
            .candidate(targets: targets, usableFrame: bounds, gap: 8, generation: 1)
        XCTAssertEqual(refused.verdict, .rejected(.writeFailed(1, .cannotComplete)))
        XCTAssertEqual(quick.writes.count, 1, "no second try")
    }

    func testTimeoutRecoveryBudgetMatchesTheVerifiedLayoutsAndKeepsAScaleBudget() {
        let relaxed = FrameSizingConfiguration().withTimeoutRecoveryBudget
        XCTAssertEqual(relaxed.deadline, 0.75)
        XCTAssertEqual(relaxed.perCallTimeout, 0.25)
        let scaled = FrameSizingConfiguration().withScaleChangeBudget.withTimeoutRecoveryBudget
        XCTAssertEqual(scaled.deadline, FrameSizingConfiguration().scaleChangeDeadline)
        XCTAssertEqual(scaled.perCallTimeout, 0.25)
    }

    func testFailureTracesPrintRawAXCodes() {
        XCTAssertEqual(FrameSizingFailure.writeFailed(77705, .cannotComplete).trace,
                       "writeFailed(77705, -25204)")
        XCTAssertEqual(TiledDragFailure.sizing(.readFailed(71889, .cannotComplete)).trace,
                       "sizing(readFailed(71889, -25204))")
        XCTAssertEqual(TiledDragFailure.preflight(.noTarget).trace, "preflight(noTarget)")
    }

    // MARK: - live drop preview

    func testPreviewOfASwapIsTheWholeTargetTileAndNoRoomShowsNothing() {
        let (tree, context, target, frames) = crossFixture()
        let transaction = TiledDragTransaction(ioFactory: FakeAX(frames: frames).factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else { return XCTFail("capture failed") }
        let hit = TiledDragTarget(windowID: 11, edge: .left)

        XCTAssertEqual(transaction.previewFrame(snapshot, plan: .otherMonitor(hit), swap: true,
                                                target: target), frames[11])
        XCTAssertNil(transaction.previewFrame(snapshot, plan: .none, swap: false, target: target))
        XCTAssertNil(transaction.previewFrame(snapshot, plan: .otherMonitor(hit), swap: false,
                                              target: nil))

        // 11 cannot shrink into the dragged window's slot, so the drop would
        // restore with noRoom, and the preview shows nothing
        let crowded = TiledDragTransaction(
            ioFactory: FakeAX(frames: frames).factory,
            minimumSize: { $0?.windowID == 11 ? CGSize(width: 1100, height: 0) : .zero })
        XCTAssertNil(crowded.previewFrame(snapshot, plan: .otherMonitor(hit), swap: true,
                                          target: target))
    }

    // MARK: - resize or move, by where the press landed

    func testResizeBorderIsAnInnerBandNarrowAtTheTop() {
        let (tree, _, context) = fixture()
        let frames = layoutFrames(tree, context)
        let frame = frames[1]!
        func edges(_ point: CGPoint?) -> Set<BSPTargetEdge>? {
            snapshot(tree, context, frames, press: point).pressedEdges
        }
        XCTAssertEqual(edges(CGPoint(x: frame.midX, y: frame.midY)), [])
        XCTAssertEqual(edges(CGPoint(x: frame.midX, y: frame.minY + 20)), [], "title bar")
        XCTAssertEqual(edges(CGPoint(x: frame.midX, y: frame.minY + 5)), [], "the title bar's top strip")
        XCTAssertEqual(edges(CGPoint(x: frame.midX, y: frame.minY + 2)), [.top])
        XCTAssertEqual(edges(CGPoint(x: frame.minX + 7, y: frame.midY)), [.left])
        XCTAssertEqual(edges(CGPoint(x: frame.minX + 9, y: frame.midY)), [])
        XCTAssertEqual(edges(CGPoint(x: frame.maxX - 3, y: frame.midY)), [.right])
        XCTAssertEqual(edges(CGPoint(x: frame.midX, y: frame.maxY - 1)), [.bottom])
        XCTAssertEqual(edges(CGPoint(x: frame.maxX - 2, y: frame.maxY - 2)), [.right, .bottom])
        XCTAssertEqual(edges(CGPoint(x: frame.midX, y: frame.minY - 3)), [], "outside is not a capture")
        XCTAssertNil(edges(nil), "a capture by id does not know")
    }

    func testGestureIsAResizeOnlyWhenEveryGrabbedEdgesOppositeHeld() {
        let (tree, _, context) = fixture()
        // an 800x600 window: minX 100, maxX 900, minY 100, maxY 700
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        func gesture(press: CGPoint, to now: CGRect) -> TiledDragGesture {
            snapshot(tree, context, [1: frame], press: press).gesture(to: now)
        }
        let bottomLeft = CGPoint(x: 103, y: 697)
        let topRight = CGPoint(x: 897, y: 102)
        let bottomRight = CGPoint(x: 897, y: 697)
        let leftEdge = CGPoint(x: 103, y: 400)
        let topStrip = CGPoint(x: 500, y: 102)
        XCTAssertEqual(snapshot(tree, context, [1: frame], press: bottomLeft).pressedEdges,
                       [.left, .bottom])

        let cases: [(String, CGPoint, CGRect, TiledDragGesture)] = [
            ("bottom-left corner, down 100 / left 10", bottomLeft,
             CGRect(x: 90, y: 100, width: 810, height: 700), .resize),
            ("bottom-left corner, down 100 / left 30", bottomLeft,
             CGRect(x: 70, y: 100, width: 830, height: 700), .resize),
            ("top-right corner, right 100 / up 10", topRight,
             CGRect(x: 100, y: 90, width: 900, height: 610), .resize),
            ("bottom-right corner, down 100 / right 10", bottomRight,
             CGRect(x: 100, y: 100, width: 810, height: 700), .resize),
            ("left edge, aspect-locked height, top held", leftEdge,
             CGRect(x: 40, y: 100, width: 860, height: 645), .resize),
            ("left edge, a 10 pt drag", leftEdge,
             CGRect(x: 90, y: 100, width: 810, height: 600), .resize),
            ("a corner-ish drag that registered only the right edge", CGPoint(x: 897, y: 690),
             CGRect(x: 100, y: 100, width: 810, height: 700), .resize),
            ("top strip, the app shrinks across screens", topStrip,
             CGRect(x: 1350, y: 30, width: 800, height: 321), .move),
            ("top strip, no size change", topStrip,
             CGRect(x: 100, y: 400, width: 800, height: 600), .move),
            ("left band, a vertical move the app shortens", leftEdge,
             CGRect(x: 100, y: 300, width: 800, height: 450), .move),
            ("left edge, the whole window moved and shrank", leftEdge,
             CGRect(x: 500, y: 100, width: 780, height: 600), .move),
            ("a press that selects text", CGPoint(x: 500, y: 400), frame, .unmoved),
            ("a mid-window press whose window moved", CGPoint(x: 500, y: 400),
             CGRect(x: 110, y: 100, width: 780, height: 600), .move)
        ]
        for (name, press, now, expected) in cases {
            XCTAssertEqual(gesture(press: press, to: now), expected, name)
        }

        // no press point: size alone decides, over 20 points as before
        let byID = snapshot(tree, context, [1: frame], press: nil)
        XCTAssertEqual(byID.gesture(to: CGRect(x: 1000, y: 100, width: 830, height: 600)), .resize)
        XCTAssertEqual(byID.gesture(to: CGRect(x: 1000, y: 100, width: 810, height: 600)), .move)
    }

    func testTopStripPressDraggedAcrossIsAMoveWithAPreview() {
        let (tree, context, target, frames) = crossFixture()
        let fake = FakeAX(frames: frames)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        let topStrip = CGPoint(x: frames[1]!.midX, y: frames[1]!.minY + 2)
        guard case let .captured(snapshot) = transaction.capture(
            pointer: topStrip, tree: tree, context: context, occludingWindows: [],
            generation: 1, currentContext: { context }) else { return XCTFail("capture failed") }
        XCTAssertEqual(snapshot.pressedEdges, [.top])
        let slot = frames[11]!
        let point = CGPoint(x: slot.midX, y: slot.maxY - 2)
        let plan = TiledDropPlanner.plan(pointer: point, draggedID: 1,
                                         sourceTiles: context.usableFrame,
                                         sourceSlots: snapshot.originalFrames,
                                         release: .otherMonitor(slots: TiledDropPlanner.slots(
                                            of: target.tree, in: target.context.usableFrame,
                                            gap: 8, padding: 8)))
        var moved: [CGRect] = []
        for shrink: CGFloat in [0, 279] {
            // mid-drag the preview sees a move, and so does the drop
            let released = CGRect(x: 1300, y: 100, width: frames[1]!.width,
                                  height: frames[1]!.height - shrink)
            XCTAssertEqual(snapshot.gesture(to: released), .move, "shrink \(shrink)")
            XCTAssertNotNil(transaction.previewFrame(snapshot, plan: plan, swap: false,
                                                     target: target), "shrink \(shrink)")
            fake.frames[1] = released
            XCTAssertSuperseded(transaction.dropRelease(snapshot, mode: nil,
                                                        currentContext: { context }) { frame in
                moved.append(frame)
                return .superseded
            })
        }
        XCTAssertEqual(moved.count, 2, "both drops go across as moves")
    }

    private func snapshot(_ tree: BSPTree, _ context: TiledDragContext,
                          _ frames: [CGWindowID: CGRect], press: CGPoint?) -> TiledDragSnapshot {
        TiledDragSnapshot(draggedID: 1, sourceTree: tree, originalTree: tree, context: context,
                          originalFrames: frames, generation: 1, pressPoint: press)
    }

    func testTitleBarPressWithAnAppResizeOnAnotherMonitorIsACrossMonitorMove() {
        let (tree, _, context) = fixture()
        let frames = layoutFrames(tree, context)
        let fake = FakeAX(frames: frames)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        let titleBar = CGPoint(x: frames[1]!.midX, y: frames[1]!.minY + 20)
        guard case let .captured(snapshot) = transaction.capture(
            pointer: titleBar, tree: tree, context: context, occludingWindows: [],
            generation: 1, currentContext: { context }) else { return XCTFail("capture failed") }
        // dragged by the title bar onto the next display, where the app
        // takes 279 points off its own height, as Messages did at 14:47:51
        let released = CGRect(x: 1350, y: 30, width: frames[1]!.width,
                              height: frames[1]!.height - 279)
        fake.frames[1] = released
        var moved: [CGRect] = []

        let outcome = transaction.dropRelease(snapshot, mode: nil, currentContext: { context }) { frame in
            moved.append(frame)
            return .superseded
        }

        XCTAssertSuperseded(outcome)
        XCTAssertEqual(moved, [released], "a title-bar drag is a move, whatever size the app reports")
    }

    func testTitleBarPressWithAnAppResizeOnTheSameScreenChangesNoRatio() {
        let (tree, _, context) = fixture()
        let frames = layoutFrames(tree, context)
        let fake = FakeAX(frames: frames)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        let titleBar = CGPoint(x: frames[1]!.midX, y: frames[1]!.minY + 20)
        guard case let .captured(snapshot) = transaction.capture(
            pointer: titleBar, tree: tree, context: context, occludingWindows: [],
            generation: 1, currentContext: { context }) else { return XCTFail("capture failed") }
        // the 14:50:09 shape: moved a little, centre still on the source,
        // 178 points shorter by the app's own doing
        var released = frames[1]!.offsetBy(dx: 60, dy: 40)
        released.size.height -= 178
        fake.frames[1] = released

        guard case .rejectedRestored(reason: .preflight(.noTarget), _) = transaction.dropRelease(
            snapshot, mode: nil, currentContext: { context }) else {
            return XCTFail("a move with no target must restore, not resize")
        }
        XCTAssertEqual(fake.frames, frames)
        XCTAssertEqual(tree.structuralFingerprint(), context.fingerprint)
    }

    func testEdgePressWithASizeChangeIsStillAResize() {
        let (tree, _, context) = fixture()
        let frames = layoutFrames(tree, context)
        let fake = FakeAX(frames: frames)
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        let rightEdge = CGPoint(x: frames[1]!.maxX - 3, y: frames[1]!.midY)
        guard case let .captured(snapshot) = transaction.capture(
            pointer: rightEdge, tree: tree, context: context, occludingWindows: [],
            generation: 1, currentContext: { context }) else { return XCTFail("capture failed") }
        XCTAssertEqual(snapshot.pressedEdges, [.right])
        fake.frames[1]!.size.width += 60

        guard case let .committed(candidate, _, _) = transaction.dropRelease(
            snapshot, mode: nil, currentContext: { context }) else {
            return XCTFail("an edge drag must still resize")
        }
        XCTAssertTrue(candidate.root.userSetRatio, "the manual resize moved the root split")
    }

    /// The same three-window source as `fixture`, next to a two-window
    /// tree on a display to its right, workspace 2.
    private func crossFixture() -> (BSPTree, TiledDragContext, TiledDragCrossTarget,
                                    [CGWindowID: CGRect]) {
        let (tree, _, context) = fixture()
        let targetTree = BSPTree()
        [makeWindow(id: 10), makeWindow(id: 11)].forEach { _ = targetTree.insert($0, maxDepth: 4) }
        let targetContext = TiledDragContext(
            workspace: 2, physicalDisplayID: 78,
            usableFrame: CGRect(x: 1200, y: 0, width: 1000, height: 800),
            gap: 8, padding: 8, maxDepth: 3,
            memberIDs: [10, 11], floatingIDs: [],
            fingerprint: targetTree.structuralFingerprint())
        let frames = layoutFrames(tree, context).merging(layoutFrames(targetTree, targetContext)) {
            first, _ in first
        }
        return (tree, context,
                TiledDragCrossTarget(tree: targetTree, context: targetContext,
                                     currentContext: { targetContext }),
                frames)
    }

    private func XCTAssertSuperseded(_ outcome: TiledDragDropOutcome,
                                     file: StaticString = #filePath, line: UInt = #line) {
        guard case .superseded = outcome else {
            return XCTFail("expected superseded", file: file, line: line)
        }
    }

    private func isSuperseded(_ outcome: TiledDragDropOutcome) -> Bool {
        if case .superseded = outcome { return true }
        return false
    }

    private func assertAccepted(edge: BSPTargetEdge, file: StaticString = #filePath,
                                line: UInt = #line) {
        let (tree, _, context) = fixture()
        let fingerprint = tree.structuralFingerprint()
        let fake = FakeAX(frames: layoutFrames(tree, context))
        let transaction = TiledDragTransaction(ioFactory: fake.factory)
        guard case let .captured(snapshot) = transaction.capture(
            draggedID: 1, tree: tree, context: context, generation: 1,
            currentContext: { context }) else {
            return XCTFail("capture failed", file: file, line: line)
        }
        guard case let .committed(candidate, _, _) = transaction.drop(
            snapshot, mode: .insert(targetID: 2, edge: edge), currentContext: { context }) else {
            return XCTFail("edge did not commit", file: file, line: line)
        }
        XCTAssertEqual(tree.structuralFingerprint(), fingerprint, file: file, line: line)
        XCTAssertNotEqual(candidate.structuralFingerprint(), fingerprint, file: file, line: line)
    }

    private func layoutFrames(_ tree: BSPTree,
                              _ context: TiledDragContext) -> [CGWindowID: CGRect] {
        Dictionary(uniqueKeysWithValues: tree.layout(in: context.usableFrame,
            gap: context.gap, padding: context.padding).map { ($0.0.windowID, $0.1) })
    }

    private func replacing(_ context: TiledDragContext,
                           workspace: Int? = nil,
                           floatingIDs: Set<CGWindowID>? = nil) -> TiledDragContext {
        TiledDragContext(
            workspace: workspace ?? context.workspace,
            physicalDisplayID: context.physicalDisplayID,
            usableFrame: context.usableFrame,
            gap: context.gap,
            padding: context.padding,
            maxDepth: context.maxDepth,
            memberIDs: context.memberIDs,
            floatingIDs: floatingIDs ?? context.floatingIDs,
            fingerprint: context.fingerprint
        )
    }

    private func contextCopy(_ context: TiledDragContext,
                             workspace: Int? = nil,
                             displayID: CGDirectDisplayID? = nil,
                             usableFrame: CGRect? = nil,
                             gap: CGFloat? = nil,
                             padding: CGFloat? = nil,
                             maxDepth: Int? = nil,
                             memberIDs: Set<CGWindowID>? = nil,
                             floatingIDs: Set<CGWindowID>? = nil,
                             fingerprint: BSPTree.StructuralFingerprint? = nil) -> TiledDragContext {
        TiledDragContext(
            workspace: workspace ?? context.workspace,
            physicalDisplayID: displayID ?? context.physicalDisplayID,
            usableFrame: usableFrame ?? context.usableFrame,
            gap: gap ?? context.gap,
            padding: padding ?? context.padding,
            maxDepth: maxDepth ?? context.maxDepth,
            memberIDs: memberIDs ?? context.memberIDs,
            floatingIDs: floatingIDs ?? context.floatingIDs,
            fingerprint: fingerprint ?? context.fingerprint
        )
    }

    private func forceHorizontal(_ node: BSPNode) {
        guard !node.isLeaf else { return }
        node.splitOverride = .horizontal
        if let left = node.left { forceHorizontal(left) }
        if let right = node.right { forceHorizontal(right) }
    }

    private func center(_ frame: CGRect) -> CGPoint {
        CGPoint(x: frame.midX, y: frame.midY)
    }
}
