import XCTest
@testable import HyprMac

final class FrameReadbackPollerTests: XCTestCase {
    func testWorkspaceRevealSettlesDestinationPositionBeforeTallResize() {
        let window = makeWindow(id: 31)
        let target = CGRect(x: -1072, y: -88, width: 1064, height: 1874)
        var frame = CGRect(x: 3439, y: 1347, width: 1064, height: 900)
        var destinationReady = false
        var writes: [String] = []
        var time: TimeInterval = 0
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, size, _ in
                writes.append("size")
                frame.size = CGSize(width: size.width,
                                    height: destinationReady ? size.height : min(size.height, 1528))
                return .success
            },
            writePosition: { _, position, _ in writes.append("position"); frame.origin = position; return .success },
            readPosition: { _, _ in (.success, frame.origin) },
            readSize: { _, _ in (.success, frame.size) },
            now: { time }, sleep: { time += $0; destinationReady = true }, currentGeneration: { 1 })

        let result = FrameReadbackPoller(generation: { 1 }, ioFactory: { _, _ in io })
            .applyWorkspaceReveal([(window, target)], positionFirstWindowIDs: [31],
                                  usableFrame: target, gap: 8, generation: 1)

        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertEqual(frame, target)
        XCTAssertEqual(writes, ["position", "size", "size"])
    }

    func testWorkspaceRevealStopsWhenSupersededWhilePositionSettles() {
        let window = makeWindow(id: 32)
        let target = CGRect(x: -1072, y: -88, width: 1064, height: 1874)
        var frame = CGRect(x: 3439, y: 1347, width: 1064, height: 900)
        var generation: UInt64 = 1
        var sizeWrites = 0
        var time: TimeInterval = 0
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, _, _ in sizeWrites += 1; return .success },
            writePosition: { _, position, _ in frame.origin = position; return .success },
            readPosition: { _, _ in (.success, frame.origin) },
            readSize: { _, _ in (.success, frame.size) },
            now: { time }, sleep: { time += $0; generation = 2 }, currentGeneration: { generation })

        let result = FrameReadbackPoller(generation: { generation }, ioFactory: { _, _ in io })
            .applyWorkspaceReveal([(window, target)], positionFirstWindowIDs: [32],
                                  usableFrame: target, gap: 8, generation: 1)

        XCTAssertEqual(result.verdict, .unknown(.superseded))
        XCTAssertEqual(sizeWrites, 0)
    }

    func testWorkspaceRevealPropagatesPositionSettleReadFailure() {
        let window = makeWindow(id: 33)
        let target = CGRect(x: -1072, y: -88, width: 1064, height: 1874)
        var sizeWrites = 0
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, _, _ in sizeWrites += 1; return .success },
            writePosition: { _, _, _ in .success },
            readPosition: { _, _ in (.cannotComplete, nil) },
            readSize: { _, _ in (.success, target.size) },
            now: { 0 }, sleep: { _ in }, currentGeneration: { 1 })

        let result = FrameReadbackPoller(generation: { 1 }, ioFactory: { _, _ in io })
            .applyWorkspaceReveal([(window, target)], positionFirstWindowIDs: [33],
                                  usableFrame: target, gap: 8, generation: 1)

        XCTAssertEqual(result.verdict, .unknown(.readFailed(33, .cannotComplete)))
        XCTAssertEqual(sizeWrites, 0)
    }

    func testOrdinaryLayoutKeepsExistingSizeFirstSequence() {
        let window = makeWindow(id: 34)
        let target = CGRect(x: 0, y: 0, width: 300, height: 400)
        var frame = target
        var writes: [String] = []
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, size, _ in writes.append("size"); frame.size = size; return .success },
            writePosition: { _, position, _ in writes.append("position"); frame.origin = position; return .success },
            readPosition: { _, _ in (.success, frame.origin) },
            readSize: { _, _ in (.success, frame.size) },
            now: { 0 }, sleep: { _ in }, currentGeneration: { 1 })

        let result = FrameReadbackPoller(generation: { 1 }, ioFactory: { _, _ in io })
            .applyLayout([(window, target)], usableFrame: target, gap: 8, generation: 1)

        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertEqual(writes, ["size", "position", "size"])
    }

    func testEmptyLayoutStillHonorsSupersession() {
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, _, _ in .success },
            writePosition: { _, _, _ in .success },
            readPosition: { _, _ in (.success, .zero) },
            readSize: { _, _ in (.success, CGSize(width: 100, height: 100)) },
            now: { 0 }, sleep: { _ in }, currentGeneration: { 2 }
        )
        let result = FrameReadbackPoller(generation: { 2 }, ioFactory: { _, _ in io })
            .applyLayout([], usableFrame: .zero, gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.superseded))
    }

    func testDuplicateCaptureInputsFailSafelyBeforeDictionaryConstruction() {
        let window = makeWindow(id: 38)
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, _, _ in .success },
            writePosition: { _, _, _ in .success },
            readPosition: { _, _ in (.success, .zero) },
            readSize: { _, _ in (.success, CGSize(width: 100, height: 100)) },
            now: { 0 }, sleep: { _ in }, currentGeneration: { 1 }
        )
        let result = FrameReadbackPoller(generation: { 1 }, ioFactory: { _, _ in io })
            .captureFrames([window, window], generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.duplicateWindowID(38)))
    }

    func testDuplicateInputsRejectWithoutDictionaryTrapOrAXCalls() {
        let window = makeWindow(id: 39)
        var called = false
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in called = true; return .success },
            writeSize: { _, _, _ in called = true; return .success },
            writePosition: { _, _, _ in called = true; return .success },
            readPosition: { _, _ in called = true; return (.success, .zero) },
            readSize: { _, _ in called = true; return (.success, CGSize(width: 100, height: 100)) },
            now: { 0 }, sleep: { _ in }, currentGeneration: { 1 }
        )
        let target = CGRect(x: 0, y: 0, width: 300, height: 400)
        let result = FrameReadbackPoller(generation: { 1 }, ioFactory: { _, _ in io })
            .applyLayout([(window, target), (window, target)],
                         usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                         gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .rejected(.duplicateWindowID(39)))
        XCTAssertFalse(called)
    }

    func testUnknownReadbackDoesNotCacheOrProduceMinimumEvidence() {
        let window = makeWindow(id: 40)
        let original = CGRect(x: 20, y: 20, width: 600, height: 500)
        let target = CGRect(x: 0, y: 0, width: 300, height: 400)
        window.cachedFrame = original
        var reads = 0
        var time: TimeInterval = 0
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, _, _ in .success },
            writePosition: { _, _, _ in .success },
            readPosition: { _, _ in
                reads += 1
                return reads == 1 ? (.success, CGPoint.zero) : (.cannotComplete, nil)
            },
            readSize: { _, _ in (.success, CGSize(width: 450, height: 400)) },
            now: { time }, sleep: { time += $0 }, currentGeneration: { 1 }
        )
        let poller = FrameReadbackPoller(generation: { 1 }, ioFactory: { _, _ in io })
        let result = poller.applyLayout([(window, target)],
                                        usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                        gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.readFailed(40, .cannotComplete)))
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertTrue(result.observations.isEmpty)
        XCTAssertTrue(result.accepted.isEmpty)
        XCTAssertNil(window.cachedFrame)
    }

    func testFinalPassReturnsVerifiedRejection() {
        let window = makeWindow(id: 41)
        let target = CGRect(x: 0, y: 0, width: 300, height: 400)
        var time: TimeInterval = 0
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, _, _ in .success },
            writePosition: { _, _, _ in .success },
            readPosition: { _, _ in (.success, CGPoint.zero) },
            readSize: { _, _ in (.success, CGSize(width: 450, height: 400)) },
            now: { time }, sleep: { time += $0 }, currentGeneration: { 1 }
        )
        let result = FrameReadbackPoller(generation: { 1 }, ioFactory: { _, _ in io })
            .applyFinal([(window, target)],
                        usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                        gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .rejected(.geometryMismatch(41)))
        XCTAssertEqual(result.conflicts.count, 1)
    }

    func testCellRoundedOvershootAcceptsAndTeachesNoMinimum() {
        let window = makeWindow(id: 43)
        let target = CGRect(x: 20, y: 20, width: 3424, height: 1301)
        let rounded = CGRect(x: 20, y: 20, width: 3425, height: 1309)
        var time: TimeInterval = 0
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, _, _ in .success },
            writePosition: { _, _, _ in .success },
            readPosition: { _, _ in (.success, rounded.origin) },
            readSize: { _, _ in (.success, rounded.size) },
            now: { time }, sleep: { time += $0 }, currentGeneration: { 1 }
        )
        let result = FrameReadbackPoller(generation: { 1 }, ioFactory: { _, _ in io })
            .applyLayout([(window, target)],
                         usableFrame: CGRect(x: 0, y: 0, width: 3600, height: 1400),
                         gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertTrue(result.observations.isEmpty)
        XCTAssertEqual(result.accepted.count, 1)
        XCTAssertNil(window.observedMinSize)
    }

    func testRejectedLayoutBlamesTheOversizedWindowNotTheRoundedOne() {
        let rounded = makeWindow(id: 44)
        let oversized = makeWindow(id: 45)
        let roundedTarget = CGRect(x: 0, y: 0, width: 500, height: 800)
        let oversizedTarget = CGRect(x: 508, y: 0, width: 492, height: 800)
        let actual: [CGWindowID: CGRect] = [
            44: CGRect(x: 0, y: 0, width: 508, height: 800),
            45: CGRect(x: 508, y: 0, width: 600, height: 800)
        ]
        var time: TimeInterval = 0
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, _, _ in .success },
            writePosition: { _, _, _ in .success },
            readPosition: { id, _ in (.success, actual[id]?.origin) },
            readSize: { id, _ in (.success, actual[id]?.size) },
            now: { time }, sleep: { time += $0 }, currentGeneration: { 1 }
        )
        let result = FrameReadbackPoller(generation: { 1 }, ioFactory: { _, _ in io })
            .applyLayout([(rounded, roundedTarget), (oversized, oversizedTarget)],
                         usableFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                         gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .rejected(.geometryMismatch(45)))
        XCTAssertEqual(result.conflicts.map { $0.window.windowID }, [45])
        XCTAssertEqual(result.observations.map { $0.window.windowID }, [45])
    }

    func testSupersededReadbackPreservesNewerCachedFrame() {
        let window = makeWindow(id: 42)
        let target = CGRect(x: 0, y: 0, width: 300, height: 400)
        let newer = CGRect(x: 500, y: 0, width: 500, height: 800)
        window.cachedFrame = target
        var generation: UInt64 = 1
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, _, _ in .success },
            writePosition: { _, _, _ in .success },
            readPosition: { _, _ in
                window.cachedFrame = newer
                generation = 2
                return (.success, target.origin)
            },
            readSize: { _, _ in (.success, target.size) },
            now: { 0 }, sleep: { _ in }, currentGeneration: { generation }
        )
        let result = FrameReadbackPoller(generation: { generation }, ioFactory: { _, _ in io })
            .applyLayout([(window, target)],
                         usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                         gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.superseded))
        XCTAssertEqual(window.cachedFrame, newer)
    }

    func testEachEntryPointReportsItsPhase() {
        let window = makeWindow(id: 50)
        let target = CGRect(x: 0, y: 0, width: 300, height: 400)
        var time: TimeInterval = 0
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, _, _ in .success },
            writePosition: { _, _, _ in .success },
            readPosition: { _, _ in (.success, target.origin) },
            readSize: { _, _ in (.success, target.size) },
            now: { time }, sleep: { time += $0 }, currentGeneration: { 1 }
        )
        let poller = FrameReadbackPoller(generation: { 1 }, ioFactory: { _, _ in io })
        let usable = CGRect(x: 0, y: 0, width: 1000, height: 800)

        XCTAssertEqual(poller.applyLayout([(window, target)], usableFrame: usable,
                                          gap: 8, generation: 1).progress.phase, .candidate)
        XCTAssertEqual(poller.applyFinal([(window, target)], usableFrame: usable,
                                         gap: 8, generation: 1).progress.phase, .adjusted)
        XCTAssertEqual(poller.applyRestoration([(window, target)], usableFrame: usable,
                                               gap: 8, generation: 1).progress.phase, .restoration)
    }

    func testClassifiedResultCarriesWriteProgress() {
        let window = makeWindow(id: 51)
        let target = CGRect(x: 0, y: 0, width: 300, height: 400)
        let oversized = CGRect(x: 0, y: 0, width: 600, height: 400)
        var time: TimeInterval = 0
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, _, _ in .success },
            writePosition: { _, _, _ in .success },
            readPosition: { _, _ in (.success, oversized.origin) },
            readSize: { _, _ in (.success, oversized.size) },
            now: { time }, sleep: { time += $0 }, currentGeneration: { 1 }
        )
        let result = FrameReadbackPoller(generation: { 1 }, ioFactory: { _, _ in io })
            .applyLayout([(window, target)],
                         usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                         gap: 8, generation: 1)

        XCTAssertEqual(result.verdict, .rejected(.geometryMismatch(51)))
        XCTAssertEqual(result.progress.targetIDs, [51])
        XCTAssertEqual(result.progress.possiblyWritten, [51])
        XCTAssertEqual(result.progress.writesCompleted, [51])
        XCTAssertTrue(result.progress.readbackComplete)
        XCTAssertEqual(result.observations.count, 1)
    }

    func testSupersededEntryStillNamesItsPhaseAndTargets() {
        let window = makeWindow(id: 52)
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, _, _ in .success },
            writePosition: { _, _, _ in .success },
            readPosition: { _, _ in (.success, .zero) },
            readSize: { _, _ in (.success, CGSize(width: 100, height: 100)) },
            now: { 0 }, sleep: { _ in }, currentGeneration: { 9 }
        )
        let result = FrameReadbackPoller(generation: { 9 }, ioFactory: { _, _ in io })
            .applyRestoration([(window, CGRect(x: 0, y: 0, width: 100, height: 100))],
                              usableFrame: CGRect(x: 0, y: 0, width: 500, height: 500),
                              gap: 8, generation: 3)

        XCTAssertEqual(result.verdict, .unknown(.superseded))
        XCTAssertEqual(result.progress.phase, .restoration)
        XCTAssertEqual(result.progress.generation, 3)
        XCTAssertEqual(result.progress.targetIDs, [52])
        XCTAssertTrue(result.progress.possiblyWritten.isEmpty)
    }

    func testOversizeAtTheWrongOriginTeachesNoMinimum() {
        let window = makeWindow(id: 60)
        let target = CGRect(x: 0, y: 0, width: 300, height: 400)
        // the app never moved: it is still where it was, at the size it was
        let stale = CGRect(x: 400, y: 120, width: 600, height: 500)
        var time: TimeInterval = 0
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, _, _ in .success },
            writePosition: { _, _, _ in .success },
            readPosition: { _, _ in (.success, stale.origin) },
            readSize: { _, _ in (.success, stale.size) },
            now: { time }, sleep: { time += $0 }, currentGeneration: { 1 }
        )
        let result = FrameReadbackPoller(generation: { 1 }, ioFactory: { _, _ in io })
            .applyLayout([(window, target)],
                         usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                         gap: 8, generation: 1)

        XCTAssertEqual(result.verdict, .rejected(.geometryMismatch(60)))
        XCTAssertTrue(result.conflicts.isEmpty, "stale geometry must not trigger an adjusted write")
        XCTAssertTrue(result.observations.isEmpty)
    }

    func testWrongOriginWindowDoesNotBlockAGoodNeighboursEvidence() {
        let stranded = makeWindow(id: 61)
        let oversized = makeWindow(id: 62)
        let strandedTarget = CGRect(x: 0, y: 0, width: 500, height: 800)
        let oversizedTarget = CGRect(x: 508, y: 0, width: 492, height: 800)
        let actual: [CGWindowID: CGRect] = [
            // never moved: wrong origin and a size that means nothing
            61: CGRect(x: 0, y: 50, width: 560, height: 700),
            // moved, settled, and refused to be this narrow
            62: CGRect(x: 508, y: 0, width: 600, height: 800)
        ]
        var time: TimeInterval = 0
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, _, _ in .success },
            writePosition: { _, _, _ in .success },
            readPosition: { id, _ in (.success, actual[id]?.origin) },
            readSize: { id, _ in (.success, actual[id]?.size) },
            now: { time }, sleep: { time += $0 }, currentGeneration: { 1 }
        )
        let result = FrameReadbackPoller(generation: { 1 }, ioFactory: { _, _ in io })
            .applyLayout([(stranded, strandedTarget), (oversized, oversizedTarget)],
                         usableFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                         gap: 8, generation: 1)

        XCTAssertEqual(result.verdict, .rejected(.geometryMismatch(61)))
        XCTAssertEqual(result.observations.map { $0.window.windowID }, [62])
        XCTAssertEqual(result.conflicts.map { $0.window.windowID }, [62])
    }

    func testOvershootIsLearnedOnlyPastTheRoundingBoundary() {
        func observations(actualWidth: CGFloat) -> [FrameReadbackPoller.Observation] {
            let window = makeWindow(id: 63)
            let target = CGRect(x: 0, y: 0, width: 300, height: 400)
            let actual = CGRect(x: 0, y: 0, width: actualWidth, height: 400)
            var time: TimeInterval = 0
            let io = FrameSizingIO(
                setMessagingTimeout: { _, _ in .success },
                writeSize: { _, _, _ in .success },
                writePosition: { _, _, _ in .success },
                readPosition: { _, _ in (.success, actual.origin) },
                readSize: { _, _ in (.success, actual.size) },
                now: { time }, sleep: { time += $0 }, currentGeneration: { 1 }
            )
            return FrameReadbackPoller(generation: { 1 }, ioFactory: { _, _ in io })
                .applyLayout([(window, target)],
                             usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                             gap: 8, generation: 1).observations
        }

        XCTAssertTrue(observations(actualWidth: 320).isEmpty)
        XCTAssertEqual(observations(actualWidth: 321).count, 1)
    }

    func testAggregateRejectionOnRoundedFramesTeachesNoMinimum() {
        let rounded = makeWindow(id: 66)
        let neighbour = makeWindow(id: 67)
        let roundedTarget = CGRect(x: 0, y: 0, width: 500, height: 800)
        let neighbourTarget = CGRect(x: 508, y: 0, width: 492, height: 800)
        // 16 pt of cell rounding: inside the per-window allowance, through
        // the 8 pt gap and 8 pt into the neighbour
        let actual: [CGWindowID: CGRect] = [
            66: CGRect(x: 0, y: 0, width: 516, height: 800),
            67: neighbourTarget
        ]
        var time: TimeInterval = 0
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, _, _ in .success },
            writePosition: { _, _, _ in .success },
            readPosition: { id, _ in (.success, actual[id]?.origin) },
            readSize: { id, _ in (.success, actual[id]?.size) },
            now: { time }, sleep: { time += $0 }, currentGeneration: { 1 }
        )
        let result = FrameReadbackPoller(generation: { 1 }, ioFactory: { _, _ in io })
            .applyLayout([(rounded, roundedTarget), (neighbour, neighbourTarget)],
                         usableFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                         gap: 8, generation: 1)

        XCTAssertEqual(result.verdict, .rejected(.overlap(66, 67)))
        XCTAssertTrue(result.conflicts.isEmpty, "no window here refused its own size")
        XCTAssertTrue(result.observations.isEmpty)
        XCTAssertTrue(result.accepted.isEmpty, "a rejected layout accepts nothing")
    }

    func testRestorationReadbackIsNeverLearningEvidence() {
        let window = makeWindow(id: 64)
        // the original frame we are rolling back to, answered oversized
        let target = CGRect(x: 0, y: 0, width: 300, height: 400)
        let actual = CGRect(x: 0, y: 0, width: 600, height: 400)
        var time: TimeInterval = 0
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, _, _ in .success },
            writePosition: { _, _, _ in .success },
            readPosition: { _, _ in (.success, actual.origin) },
            readSize: { _, _ in (.success, actual.size) },
            now: { time }, sleep: { time += $0 }, currentGeneration: { 1 }
        )
        let result = FrameReadbackPoller(generation: { 1 }, ioFactory: { _, _ in io })
            .applyRestoration([(window, target)],
                              usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                              gap: 8, generation: 1)

        XCTAssertEqual(result.verdict, .rejected(.geometryMismatch(64)))
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertTrue(result.observations.isEmpty)
        XCTAssertTrue(result.accepted.isEmpty)
    }

    func testIOFailureAfterPartialSamplesTeachesNothing() {
        let oversized = makeWindow(id: 65)
        let unreadable = makeWindow(id: 66)
        let oversizedTarget = CGRect(x: 0, y: 0, width: 300, height: 400)
        let unreadableTarget = CGRect(x: 508, y: 0, width: 300, height: 400)
        var time: TimeInterval = 0
        let io = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, _, _ in .success },
            writePosition: { _, _, _ in .success },
            readPosition: { id, _ in
                id == 65 ? (.success, CGPoint.zero) : (.cannotComplete, nil)
            },
            readSize: { _, _ in (.success, CGSize(width: 600, height: 400)) },
            now: { time }, sleep: { time += $0 }, currentGeneration: { 1 }
        )
        let result = FrameReadbackPoller(generation: { 1 }, ioFactory: { _, _ in io })
            .applyLayout([(oversized, oversizedTarget), (unreadable, unreadableTarget)],
                         usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                         gap: 8, generation: 1)

        XCTAssertEqual(result.verdict, .unknown(.readFailed(66, .cannotComplete)))
        XCTAssertEqual(result.actualFrames.count, 1, "the first window did read back")
        XCTAssertTrue(result.observations.isEmpty)
    }

    func testLearningRefusalNamesTheGuardThatStoppedIt() {
        let target = CGRect(x: 0, y: 0, width: 300, height: 400)
        let onTarget = CGRect(x: 0, y: 0, width: 600, height: 400)
        let complete = FrameSizingAttempt.Progress(
            phase: .candidate, generation: 1, targetIDs: [90],
            possiblyWritten: [90], writesCompleted: [90],
            readbackComplete: true, readbackStable: true
        )
        func refusal(verdict: FrameSizingAttempt.Verdict = .rejected(.geometryMismatch(90)),
                     progress: FrameSizingAttempt.Progress = complete,
                     actual: CGRect = onTarget) -> FrameReadbackPoller.LearningRefusal? {
            FrameReadbackPoller.learningRefusal(windowID: 90, target: target, actual: actual,
                                                verdict: verdict, progress: progress,
                                                positionTolerance: 1)
        }

        XCTAssertNil(refusal())
        XCTAssertEqual(refusal(verdict: .accepted), .notRejected)
        XCTAssertEqual(refusal(verdict: .unknown(.attemptsExhausted)), .notRejected)
        XCTAssertEqual(refusal(verdict: .rejected(.writeFailed(90, .cannotComplete))), .ioFailure)
        XCTAssertEqual(refusal(verdict: .rejected(.cleanupFailed(90, primary: nil,
                                                                error: .cannotComplete))), .ioFailure)
        // another window's aggregate failure does not silence this one
        XCTAssertNil(refusal(verdict: .rejected(.overlap(91, 92))))
        XCTAssertNil(refusal(verdict: .rejected(.geometryMismatch(91))))

        var restoration = complete
        restoration.phase = .restoration
        XCTAssertEqual(refusal(progress: restoration), .restorationPhase)

        var unwritten = complete
        unwritten.writesCompleted = []
        XCTAssertEqual(refusal(progress: unwritten), .writesIncomplete)

        var partial = complete
        partial.readbackComplete = false
        XCTAssertEqual(refusal(progress: partial), .readbackIncomplete)

        var unstable = complete
        unstable.readbackStable = false
        XCTAssertEqual(refusal(progress: unstable), .readbackIncomplete)

        XCTAssertEqual(refusal(actual: onTarget.offsetBy(dx: 2, dy: 0)), .originMismatch)
        XCTAssertEqual(refusal(actual: onTarget.offsetBy(dx: 0, dy: 2)), .originMismatch)
        XCTAssertNil(refusal(actual: onTarget.offsetBy(dx: 1, dy: 1)))
    }

    func testAnEmptyAttemptCannotSatisfyTheLearningGuards() {
        // an attempt with no targets reports a complete, stable readback of
        // nothing. no window is in writesCompleted, so nothing can learn.
        let empty = FrameSizingAttempt.Progress(phase: .candidate, generation: 1,
                                                readbackComplete: true, readbackStable: true)
        XCTAssertEqual(FrameReadbackPoller.learningRefusal(
            windowID: 90, target: CGRect(x: 0, y: 0, width: 300, height: 400),
            actual: CGRect(x: 0, y: 0, width: 600, height: 400),
            verdict: .rejected(.geometryMismatch(90)), progress: empty,
            positionTolerance: 1
        ), .writesIncomplete)
    }

    func testAxisNamingCoversBothSingleAndDoubleConflicts() {
        XCTAssertEqual(FrameReadbackPoller.axis(width: true, height: true), "width+height")
        XCTAssertEqual(FrameReadbackPoller.axis(width: true, height: false), "width")
        XCTAssertEqual(FrameReadbackPoller.axis(width: false, height: true), "height")
        XCTAssertEqual(FrameReadbackPoller.axis(width: false, height: false), "none")
    }
}
