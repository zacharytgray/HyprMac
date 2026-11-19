import XCTest
@testable import HyprMac

final class FrameSizingTransactionTests: XCTestCase {
    private final class Fake {
        var time: TimeInterval = 0
        var generation: UInt64 = 1
        var frames: [CGWindowID: CGRect] = [:]
        var operations: [String] = []
        var reads: [CGWindowID: [(AXError, CGRect?)]] = [:]
        var sizeReads: [CGWindowID: [(AXError, CGSize?)]] = [:]
        var writeErrors: [AXError] = []
        var timeoutErrors: [AXError] = []
        var timeoutAdvances: [TimeInterval] = []
        var writeAdvances: [TimeInterval] = []
        var positionReadAdvances: [TimeInterval] = []
        var sizeReadAdvances: [TimeInterval] = []
        var callAdvance: TimeInterval = 0
        var sizeWriteTimes: [TimeInterval] = []

        func io() -> FrameSizingIO {
            FrameSizingIO(
                setMessagingTimeout: { [unowned self] id, _ in
                    operations.append("timeout:\(id)")
                    time += timeoutAdvances.isEmpty ? callAdvance : timeoutAdvances.removeFirst()
                    if !timeoutErrors.isEmpty { return timeoutErrors.removeFirst() }
                    return .success
                },
                writeSize: { [unowned self] id, size, _ in
                    operations.append("size:\(id)")
                    sizeWriteTimes.append(time)
                    time += writeAdvances.isEmpty ? callAdvance : writeAdvances.removeFirst()
                    if !writeErrors.isEmpty { return writeErrors.removeFirst() }
                    frames[id]?.size = size
                    return .success
                },
                writePosition: { [unowned self] id, point, _ in
                    operations.append("position:\(id)")
                    time += writeAdvances.isEmpty ? callAdvance : writeAdvances.removeFirst()
                    if !writeErrors.isEmpty { return writeErrors.removeFirst() }
                    frames[id]?.origin = point
                    return .success
                },
                readPosition: { [unowned self] id, _ in
                    operations.append("position-read:\(id)")
                    time += positionReadAdvances.isEmpty ? callAdvance : positionReadAdvances.removeFirst()
                    if var scripted = reads[id], !scripted.isEmpty {
                        let next = scripted.removeFirst()
                        reads[id] = scripted
                        return (next.0, next.1?.origin)
                    }
                    guard let frame = frames[id] else { return (.invalidUIElement, nil) }
                    return (.success, frame.origin)
                },
                readSize: { [unowned self] id, _ in
                    operations.append("size-read:\(id)")
                    time += sizeReadAdvances.isEmpty ? callAdvance : sizeReadAdvances.removeFirst()
                    if var scripted = sizeReads[id], !scripted.isEmpty {
                        let next = scripted.removeFirst()
                        sizeReads[id] = scripted
                        return next
                    }
                    guard let frame = frames[id] else { return (.invalidUIElement, nil) }
                    return (.success, frame.size)
                },
                now: { [unowned self] in time },
                sleep: { [unowned self] interval in time += interval },
                currentGeneration: { [unowned self] in generation }
            )
        }
    }

    func testImmediateExactAcceptanceUsesResizeMoveResize() {
        let fake = Fake()
        let id: CGWindowID = 7
        let target = CGRect(x: 8, y: 8, width: 492, height: 784)
        fake.frames[id] = CGRect(x: 20, y: 20, width: 800, height: 700)
        let attempt = FrameSizingAttempt(io: fake.io())

        let result = attempt.apply(
            targets: [.init(windowID: id, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            gap: 8,
            generation: 1
        )

        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertEqual(result.actualFrames[id], target)
        XCTAssertEqual(fake.operations, ["timeout:7", "size:7", "timeout:7", "position:7", "timeout:7", "size:7", "timeout:7", "position-read:7", "timeout:7", "size-read:7", "timeout:7", "position-read:7", "timeout:7", "size-read:7"])
    }

    func testTraceFrameReadsBeforeAndAfterEverySetterWithoutChangingTheVerdict() {
        let id: CGWindowID = 43
        let target = CGRect(x: 8, y: 8, width: 492, height: 784)
        func run(traced: Bool) -> (FrameSizingAttempt.Result, Int) {
            let fake = Fake()
            fake.frames[id] = CGRect(x: 20, y: 20, width: 800, height: 700)
            var probes = 0
            var io = fake.io()
            if traced {
                io.traceFrame = { probes += 1; return fake.frames[$0] }
            }
            let result = FrameSizingAttempt(io: io).apply(
                targets: [.init(windowID: id, frame: target)],
                usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
            return (result, probes)
        }
        let (plain, none) = run(traced: false)
        let (probed, count) = run(traced: true)
        XCTAssertEqual(none, 0)
        XCTAssertEqual(count, 4, "before, size, position, size2")
        XCTAssertEqual(probed.verdict, plain.verdict)
        XCTAssertEqual(probed.actualFrames, plain.actualFrames)
    }

    // the probes are extra AX reads inside the write deadline. the Debug
    // build keeps the file log on, so they must not ride along with it.
    func testProductionIOTracesFramesOnlyWhenAskedTo() {
        let key = LogConfig.frameWriteTraceKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertNil(FrameSizingIO.accessibility(windows: [:], currentGeneration: { 0 }).traceFrame)
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertNotNil(FrameSizingIO.accessibility(windows: [:], currentGeneration: { 0 }).traceFrame)
    }

    func testDelayedAcceptancePollsWithinDeadline() {
        let fake = Fake()
        let id: CGWindowID = 8
        let target = CGRect(x: 10, y: 10, width: 300, height: 300)
        fake.frames[id] = target
        fake.reads[id] = [(.success, CGRect(x: 10, y: 10, width: 350, height: 300)),
                          (.success, target), (.success, target)]
        fake.sizeReads[id] = [(.success, CGSize(width: 350, height: 300)),
                              (.success, target.size), (.success, target.size)]
        var config = FrameSizingConfiguration()
        config.pollInterval = 0.01
        let result = FrameSizingAttempt(io: fake.io(), configuration: config).apply(
            targets: [.init(windowID: id, frame: target)], usableFrame: CGRect(x: 0, y: 0, width: 800, height: 800),
            gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertEqual(fake.operations.filter { $0 == "position-read:8" }.count, 3)
    }

    func testExplicitWriteErrorIsRejected() {
        let fake = Fake()
        fake.frames[9] = CGRect(x: 0, y: 0, width: 100, height: 100)
        fake.writeErrors = [.cannotComplete]
        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: 9, frame: CGRect(x: 0, y: 0, width: 200, height: 200))],
            usableFrame: CGRect(x: 0, y: 0, width: 800, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .rejected(.writeFailed(9, .cannotComplete)))
    }

    // PR #82, 2026-11-18: a parked Dia window revealed into the left half
    // answered its size write with -25205 again after the 1pt nudge resend.
    // AX then read 1491x1646, the nudge value, whatever the window did.
    private func refusedReveal(server: CGRect?) -> (FrameSizingAttempt.Result, Fake) {
        let fake = Fake()
        let id: CGWindowID = 7345
        // the fake applies nothing it scripts an error for, so AX already
        // reports the nudge value, as Dia's did
        fake.frames[id] = CGRect(x: 8, y: 38, width: 1491, height: 1646)
        fake.writeErrors = [.success, .attributeUnsupported, .attributeUnsupported]
        var config = FrameSizingConfiguration()
        config.positionSettleWindowIDs = [id]
        var io = fake.io()
        if let server { io.serverFrame = { _ in server } }
        let result = FrameSizingAttempt(io: io, configuration: config).apply(
            targets: [.init(windowID: id, frame: CGRect(x: 8, y: 38, width: 1492, height: 1646))],
            usableFrame: CGRect(x: 0, y: 30, width: 3008, height: 1662), gap: 8, generation: 1)
        return (result, fake)
    }

    func testARefusedSizeTheWindowServerHasOnTargetIsAccepted() {
        let landed = CGRect(x: 8, y: 38, width: 1492, height: 1646)
        let (result, fake) = refusedReveal(server: landed)
        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertEqual(result.actualFrames[7345], landed, "the published frame is the window server's")
        XCTAssertEqual(result.progress.serverJudged, [7345])
        XCTAssertEqual(result.progress.writesCompleted, [7345])
        XCTAssertEqual(fake.operations.filter { $0 == "size:7345" }.count, 2,
                       "a refused setter goes on to the next one")
    }

    func testARefusedSizeIsNotAcceptedOnTheAppsOwnReadback() {
        // AX says 1491 wide, a point off the target. the window never
        // shrank: the window server still has it full width
        let (result, _) = refusedReveal(server: CGRect(x: 8, y: 38, width: 2992, height: 1646))
        XCTAssertEqual(result.verdict, .rejected(.writeFailed(7345, .attributeUnsupported)),
                       "a write failure, not a geometry mismatch: nothing was learned about a minimum")
        XCTAssertEqual(result.actualFrames[7345]?.width, 2992)
    }

    func testARefusedSizeWithNoWindowServerProviderStaysAWriteFailure() {
        let (result, fake) = refusedReveal(server: nil)
        XCTAssertEqual(result.verdict, .rejected(.writeFailed(7345, .attributeUnsupported)))
        XCTAssertEqual(fake.operations.filter { $0 == "size:7345" }.count, 1)
        XCTAssertTrue(result.progress.serverJudged.isEmpty)
    }

    // both size writes on window 9 answered -25205 (size, position, size2),
    // then the window server answers from `server`, which sees the fake's clock
    private func refusedGrow(deadline: TimeInterval? = nil,
                             lastSize: AXError = .attributeUnsupported,
                             server: @escaping (Fake) -> CGRect?) -> (FrameSizingAttempt.Result, Fake) {
        let fake = Fake()
        fake.frames[9] = CGRect(x: 0, y: 0, width: 200, height: 200)
        fake.writeErrors = [.attributeUnsupported, .success, lastSize]
        var config = FrameSizingConfiguration()
        if let deadline {
            config.deadline = deadline
            config.deadlineCap = deadline
        }
        var io = fake.io()
        io.serverFrame = { [unowned fake] _ in server(fake) }
        let result = FrameSizingAttempt(io: io, configuration: config).apply(
            targets: [.init(windowID: 9, frame: CGRect(x: 0, y: 0, width: 200, height: 200))],
            usableFrame: CGRect(x: 0, y: 0, width: 800, height: 800), gap: 8, generation: 1)
        return (result, fake)
    }

    private static let old9 = CGRect(x: 0, y: 0, width: 100, height: 200)
    private static let landed9 = CGRect(x: 0, y: 0, width: 200, height: 200)

    func testAWindowServerThatCatchesUpInsideThePassIsAccepted() {
        // the ordinary settle would have judged the old bounds at 240 ms
        for lag in [0.0, 0.24, 0.30] {
            let (result, fake) = refusedGrow { $0.time + 0.0001 >= lag ? Self.landed9 : Self.old9 }
            XCTAssertEqual(result.verdict, .accepted, "server lag \(lag)")
            XCTAssertEqual(result.actualFrames[9], Self.landed9)
            XCTAssertLessThan(fake.time, 0.40)
        }
    }

    func testAWindowServerStillOffTargetAfterItsWholeWindowIsAFailedWrite() {
        let (result, fake) = refusedGrow { _ in Self.old9 }
        XCTAssertEqual(result.verdict, .rejected(.writeFailed(9, .attributeUnsupported)))
        XCTAssertGreaterThanOrEqual(fake.time + 0.0001, 0.36, "not judged before the server settle ran")
        XCTAssertEqual(result.progress.refusedSetters, [9])
    }

    func testASizeWhoseLastSetterSucceededIsJudgedAsGeometry() {
        // size answered -25205, size2 got a success code: the last answer
        // counts, so a size still short is a mismatch to learn from
        let (result, _) = refusedGrow(lastSize: .success) { _ in Self.old9 }
        XCTAssertEqual(result.verdict, .rejected(.geometryMismatch(9)))
        XCTAssertEqual(result.progress.serverJudged, [9])
        XCTAssertTrue(result.progress.refusedSetters.isEmpty)
    }

    func testABudgetThatEndsBeforeTheServerWindowIsATimeoutNotARefusal() {
        let (result, _) = refusedGrow(deadline: 0.2) { _ in Self.old9 }
        XCTAssertEqual(result.verdict, .unknown(.deadlineExceeded))
        XCTAssertTrue(result.verdict.failure?.isTimeout ?? false, "the recovery retries it, never floats for it")
    }

    func testOneMissingWindowServerFrameIsAskedAgain() {
        var asked = 0
        let (result, _) = refusedGrow { _ in
            asked += 1
            return asked == 1 ? nil : Self.landed9
        }
        XCTAssertEqual(result.verdict, .accepted)
    }

    func testAWindowTheServerNoLongerDescribesIsUnavailableNotRefused() {
        // it closed after the AX reads: missing evidence, not a refused frame
        let (result, _) = refusedGrow { _ in nil }
        XCTAssertEqual(result.verdict, .unknown(.windowUnavailable(9)))
    }

    func testANewerGenerationDuringAServerLookupStopsThePass() {
        let (result, _) = refusedGrow { fake in
            fake.generation = 2
            return Self.landed9
        }
        XCTAssertEqual(result.verdict, .unknown(.superseded))
    }

    func testARefusedPositionOnAStagedWindowStillSendsEverySetter() {
        // position-first with a staging origin: position, size, position2, size2
        let fake = Fake()
        let id: CGWindowID = 31
        let target = CGRect(x: -1072, y: 853, width: 1064, height: 462)
        fake.frames[id] = CGRect(x: 3439, y: 1310, width: 1708, height: 1296)
        fake.writeErrors = [.attributeUnsupported, .success, .attributeUnsupported, .success]
        var config = FrameSizingConfiguration()
        config.positionSettleWindowIDs = [id]
        config.stagingOrigins = [id: CGPoint(x: -1072, y: -88)]
        var io = fake.io()
        io.serverFrame = { _ in target }
        let result = FrameSizingAttempt(io: io, configuration: config).apply(
            targets: [.init(windowID: id, frame: target)],
            usableFrame: CGRect(x: -1080, y: -96, width: 1080, height: 1890), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .accepted, "a display left of and above the primary: negative origins")
        XCTAssertEqual(fake.operations.filter { $0 == "position:\(id)" }.count, 2)
        XCTAssertEqual(fake.operations.filter { $0 == "size:\(id)" }.count, 2)
        XCTAssertEqual(result.progress.refusedSetters, [id])
    }

    // the 1pt nudge got a success code after a first -25205
    private func nudged(server: CGRect) -> FrameSizingAttempt.Result {
        let fake = Fake()
        fake.frames[9] = CGRect(x: 0, y: 0, width: 500, height: 400)
        var io = fake.io()
        io.serverFrame = { _ in server }
        io.suspects.mark(.init(pid: 0, windowID: 9))
        return FrameSizingAttempt(io: io).apply(
            targets: [.init(windowID: 9, frame: CGRect(x: 0, y: 0, width: 300, height: 400))],
            usableFrame: CGRect(x: 0, y: 0, width: 800, height: 800), gap: 8, generation: 1)
    }

    func testAWriteTheNudgeRescuedIsStillJudgedByTheWindowServer() {
        let result = nudged(server: CGRect(x: 0, y: 0, width: 300, height: 400))
        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertEqual(result.progress.serverJudged, [9])
        XCTAssertTrue(result.progress.refusedSetters.isEmpty)
    }

    func testANudgedWindowHeldAtItsMinimumIsStillAGeometryMismatch() {
        // AX says 300 wide. the window server has it at its 500 minimum.
        // that stays a mismatch the min-size memory can learn from
        let result = nudged(server: CGRect(x: 0, y: 0, width: 500, height: 400))
        XCTAssertEqual(result.verdict, .rejected(.geometryMismatch(9)))
        XCTAssertEqual(result.actualFrames[9]?.width, 500)
    }

    func testAnotherWindowsMinimumIsStillReportedBesideARefusedSetter() {
        // 1 is held at a minimum and read through AX. 2 answered -25205 and
        // stands on its target on the window server
        let fake = Fake()
        let left = CGRect(x: 0, y: 0, width: 300, height: 800)
        let right = CGRect(x: 308, y: 0, width: 400, height: 800)
        fake.frames[1] = CGRect(x: 0, y: 0, width: 500, height: 800)
        fake.frames[2] = right
        // 1: size refused by its minimum (scripted, not applied), position, size2. 2: size answered -25205
        fake.writeErrors = [.success, .success, .success, .attributeUnsupported]
        var io = fake.io()
        io.serverFrame = { _ in right }
        let result = FrameSizingAttempt(io: io).apply(
            targets: [.init(windowID: 1, frame: left), .init(windowID: 2, frame: right)],
            usableFrame: CGRect(x: 0, y: 0, width: 800, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .rejected(.geometryMismatch(1)))
        XCTAssertEqual(result.progress.serverJudged, [2])
    }

    // left (2) is judged by the window server, right (1) by AX. AX has both
    // exactly on target, so only the server's frame can fail the pair
    private func mixedPair(serverLeft: CGRect) -> FrameSizingAttempt.Verdict {
        let fake = Fake()
        let left = CGRect(x: 0, y: 0, width: 400, height: 800)
        let right = CGRect(x: 408, y: 0, width: 400, height: 800)
        fake.frames[2] = left
        fake.frames[1] = right
        var io = fake.io()
        io.serverFrame = { _ in serverLeft }
        io.suspects.mark(.init(pid: 0, windowID: 2))
        return FrameSizingAttempt(io: io).apply(
            targets: [.init(windowID: 2, frame: left), .init(windowID: 1, frame: right)],
            usableFrame: CGRect(x: 0, y: 0, width: 816, height: 800), gap: 8, generation: 1).verdict
    }

    func testAServerFrameAndAnAXFrameAreCheckedTogether() {
        // each within the 20 pt size allowance on its own
        XCTAssertEqual(mixedPair(serverLeft: CGRect(x: 0, y: 0, width: 400, height: 800)), .accepted)
        XCTAssertEqual(mixedPair(serverLeft: CGRect(x: 0, y: 0, width: 405, height: 800)), .accepted)
        XCTAssertEqual(mixedPair(serverLeft: CGRect(x: 0, y: 0, width: 407.5, height: 800)),
                       .rejected(.gapViolation(2, 1)), "the server frame eats the gap")
        XCTAssertEqual(mixedPair(serverLeft: CGRect(x: 0, y: 0, width: 412, height: 800)),
                       .rejected(.overlap(2, 1)), "the server frame lies over its neighbour")
    }

    // MARK: - round 5: probes from the review of 81f3059

    func testARollbackOfAMarkedWindowIsVerifiedByTheWindowServerToo() {
        // the candidate's size was answered -25205 and the window stopped at
        // 500. the rollback setters succeed and AX reports the original 600,
        // but the window server still has 500: nothing was restored
        let fake = Fake()
        let original = CGRect(x: 0, y: 0, width: 600, height: 800)
        let stuck = CGRect(x: 0, y: 0, width: 500, height: 800)
        fake.frames[14] = original
        fake.writeErrors = [.attributeUnsupported, .success, .attributeUnsupported]
        var serverReadsInRollback = 0
        var io = fake.io()
        io.serverFrame = { [unowned fake] _ in
            if fake.operations.filter({ $0 == "size:14" }).count > 2 { serverReadsInRollback += 1 }
            return stuck
        }
        let outcome = FrameSizingTransaction(attempt: FrameSizingAttempt(io: io)).apply(
            targets: [.init(windowID: 14, frame: CGRect(x: 0, y: 0, width: 400, height: 800))],
            originalFrames: [14: original],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(outcome.outcome, .degraded(candidateReason: .writeFailed(14, .attributeUnsupported),
                                                  restorationReason: .geometryMismatch(14),
                                                  actualFrames: [14: stuck]))
        XCTAssertGreaterThan(serverReadsInRollback, 0)
    }

    // left (2) is marked and shrinking on the window server from 412 to 400
    // beside a neighbour at x=408. each sample passes the size allowance alone
    private func shrinkingBesideANeighbour(landsAt: TimeInterval?) -> (FrameSizingAttempt.Verdict, TimeInterval) {
        let fake = Fake()
        let left = CGRect(x: 0, y: 0, width: 400, height: 800)
        let right = CGRect(x: 408, y: 0, width: 400, height: 800)
        fake.frames[2] = left
        fake.frames[1] = right
        var io = fake.io()
        io.serverFrame = { [unowned fake] _ in
            if let landsAt, fake.time + 0.0001 >= landsAt { return left }
            return CGRect(x: 0, y: 0, width: 412, height: 800)
        }
        io.suspects.mark(.init(pid: 0, windowID: 2))
        let verdict = FrameSizingAttempt(io: io).apply(
            targets: [.init(windowID: 2, frame: left), .init(windowID: 1, frame: right)],
            usableFrame: CGRect(x: 0, y: 0, width: 816, height: 800), gap: 8, generation: 1).verdict
        return (verdict, fake.time)
    }

    func testAMarkedWindowStillSettlingDoesNotFailTheAggregateChecksEarly() {
        let (verdict, time) = shrinkingBesideANeighbour(landsAt: 0.06)
        XCTAssertEqual(verdict, .accepted, "the overlap at 30 ms was a window on its way")
        XCTAssertLessThan(time, 0.2)
    }

    func testAMarkedWindowThatNeverSettlesFailsTheAggregateCheckAtItsDeadline() {
        let (verdict, time) = shrinkingBesideANeighbour(landsAt: nil)
        XCTAssertEqual(verdict, .rejected(.overlap(2, 1)))
        XCTAssertGreaterThanOrEqual(time + 0.0001, 0.36)
    }

    func testAMarkedWindowIsNeverReadThroughAX() {
        // AX size answers -25205 too. the window server has it on target
        let fake = Fake()
        let target = CGRect(x: 0, y: 0, width: 300, height: 400)
        fake.frames[9] = target
        fake.sizeReads[9] = Array(repeating: (.attributeUnsupported, nil), count: 40)
        var io = fake.io()
        io.serverFrame = { _ in target }
        io.suspects.mark(.init(pid: 0, windowID: 9))
        let result = FrameSizingAttempt(io: io).apply(
            targets: [.init(windowID: 9, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 800, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertFalse(fake.operations.contains("size-read:9"))
        XCTAssertFalse(fake.operations.contains("position-read:9"))
    }

    func testARefusedPositionThatLandedDoesNotHideAMinimum() {
        // size, position, size2: the position was answered -25205 and landed.
        // both sizes succeeded and the window server shows a real 500 floor
        let fake = Fake()
        fake.frames[9] = CGRect(x: 40, y: 40, width: 500, height: 400)
        fake.writeErrors = [.success, .attributeUnsupported, .success]
        var io = fake.io()
        io.serverFrame = { _ in CGRect(x: 0, y: 0, width: 500, height: 400) }
        let result = FrameSizingAttempt(io: io).apply(
            targets: [.init(windowID: 9, frame: CGRect(x: 0, y: 0, width: 300, height: 400))],
            usableFrame: CGRect(x: 0, y: 0, width: 800, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .rejected(.geometryMismatch(9)),
                       "the size setters succeeded, so a short size is a floor to learn")
    }

    func testARefusedPositionThatDidNotLandIsStillAWriteFailure() {
        let fake = Fake()
        fake.frames[9] = CGRect(x: 40, y: 40, width: 300, height: 400)
        fake.writeErrors = [.success, .attributeUnsupported, .success]
        var io = fake.io()
        io.serverFrame = { _ in CGRect(x: 40, y: 40, width: 300, height: 400) }
        let result = FrameSizingAttempt(io: io).apply(
            targets: [.init(windowID: 9, frame: CGRect(x: 0, y: 0, width: 300, height: 400))],
            usableFrame: CGRect(x: 0, y: 0, width: 800, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .rejected(.writeFailed(9, .attributeUnsupported)))
    }

    // MARK: - round 6: one reader per window, marks in an identity-keyed store

    func testACaptureReadsASuspectWindowFromTheWindowServerAndNeverThroughAX() {
        // AX says 600 and its size read fails. the window server has 500
        let fake = Fake()
        fake.frames[9] = CGRect(x: 0, y: 0, width: 600, height: 400)
        fake.frames[10] = CGRect(x: 608, y: 0, width: 200, height: 400)
        fake.sizeReads[9] = [(.attributeUnsupported, nil)]
        let io = fake.io().withServer { $0 == 9 ? CGRect(x: 0, y: 0, width: 500, height: 400) : nil }
        io.suspects.mark(.init(pid: 0, windowID: 9))
        let capture = FrameSizingAttempt(io: io).captureFrames(windowIDs: [9, 10], generation: 1)
        XCTAssertEqual(capture.verdict, .accepted)
        XCTAssertEqual(capture.actualFrames[9]?.width, 500, "what is on screen, so a rollback restores that")
        XCTAssertEqual(capture.actualFrames[10]?.width, 200, "its neighbour still reads AX")
        XCTAssertFalse(fake.operations.contains("size-read:9"))
        XCTAssertFalse(fake.operations.contains("position-read:9"))
        XCTAssertTrue(io.suspects.contains(.init(pid: 0, windowID: 9)), "a capture does not clear a mark")
    }

    func testTheMarkIsKeyedByIdentityAndSurvivesANewIOForTheSameWindow() {
        // an admission retry walks the windows again and builds a new IO
        let suspects = FrameSuspects()
        let first = Fake()
        first.frames[9] = CGRect(x: 0, y: 0, width: 600, height: 400)
        first.writeErrors = [.attributeUnsupported, .success, .attributeUnsupported]
        var io = first.io().withServer { _ in CGRect(x: 0, y: 0, width: 500, height: 400) }
        io.suspects = suspects
        io.suspectKey = { .init(pid: 77, windowID: $0) }
        let refused = FrameSizingAttempt(io: io).apply(
            targets: [.init(windowID: 9, frame: CGRect(x: 0, y: 0, width: 300, height: 400))],
            usableFrame: CGRect(x: 0, y: 0, width: 800, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(refused.verdict, .rejected(.writeFailed(9, .attributeUnsupported)))
        XCTAssertTrue(suspects.contains(.init(pid: 77, windowID: 9)))

        let second = Fake()
        second.frames[9] = CGRect(x: 0, y: 0, width: 600, height: 400)
        var retry = second.io().withServer { _ in CGRect(x: 0, y: 0, width: 500, height: 400) }
        retry.suspects = suspects
        retry.suspectKey = { .init(pid: 77, windowID: $0) }
        let capture = FrameSizingAttempt(io: retry).captureFrames(windowIDs: [9], generation: 1)
        XCTAssertEqual(capture.actualFrames[9]?.width, 500, "the new IO reads the server at once")

        // the same window id under another pid is another window
        retry.suspectKey = { .init(pid: 78, windowID: $0) }
        XCTAssertEqual(FrameSizingAttempt(io: retry).captureFrames(windowIDs: [9], generation: 1)
            .actualFrames[9]?.width, 600)
        suspects.forget(windowID: 9)
        XCTAssertFalse(suspects.contains(.init(pid: 77, windowID: 9)), "closed or replaced: a reused id starts clean")
    }

    // MARK: - round 7: a mark lasts as long as the window

    func testAnAcceptedPassDoesNotHideTheMarkFromALaterRollback() {
        // a cross-display drag: display one accepts 500 -> 300, display two
        // fails, and the rollback of display one must still ask the server
        let fake = Fake()
        let key = FrameSuspects.Key(pid: 0, windowID: 9)
        fake.frames[9] = CGRect(x: 0, y: 0, width: 500, height: 400)
        var server = CGRect(x: 0, y: 0, width: 500, height: 400)
        var serverReads = 0
        let io = fake.io().withServer { _ in serverReads += 1; return server }
        io.suspects.mark(key)
        let attempt = FrameSizingAttempt(io: io)
        let usable = CGRect(x: 0, y: 0, width: 800, height: 800)

        server.size.width = 300
        let first = attempt.apply(targets: [.init(windowID: 9, frame: CGRect(x: 0, y: 0, width: 300, height: 400))],
                                  usableFrame: usable, gap: 8, generation: 1)
        XCTAssertEqual(first.verdict, .accepted)
        XCTAssertTrue(io.suspects.contains(key), "no pass retires a mark")

        // the rollback setters succeed and AX says 500. the window stays at 300
        serverReads = 0
        let rollback = attempt.apply(targets: [.init(windowID: 9, frame: CGRect(x: 0, y: 0, width: 500, height: 400))],
                                     usableFrame: usable, gap: 8, generation: 1, phase: .restoration)
        XCTAssertEqual(fake.frames[9]?.width, 500)
        XCTAssertNotEqual(rollback.verdict, .accepted)
        XCTAssertEqual(rollback.actualFrames[9]?.width, 300)
        XCTAssertGreaterThan(serverReads, 0)
    }

    func testAPositionRefusalThatReturnsPastTheDeadlineIsStillRecorded() {
        let fake = Fake()
        let key = FrameSuspects.Key(pid: 0, windowID: 9)
        fake.frames[9] = CGRect(x: 40, y: 40, width: 500, height: 400)
        fake.writeErrors = [.success, .attributeUnsupported]
        fake.writeAdvances = [0, 0.5]
        let io = fake.io().withServer { _ in CGRect(x: 40, y: 40, width: 300, height: 400) }
        let result = FrameSizingAttempt(io: io).apply(
            targets: [.init(windowID: 9, frame: CGRect(x: 0, y: 0, width: 300, height: 400))],
            usableFrame: CGRect(x: 0, y: 0, width: 800, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.deadlineExceeded), "the deadline verdict stands")
        XCTAssertTrue(io.suspects.contains(key), "and the answer was recorded before it")

        // so the rollback is read from the window server: AX says 500, it has 300
        let rollback = FrameSizingAttempt(io: io).apply(
            targets: [.init(windowID: 9, frame: CGRect(x: 40, y: 40, width: 500, height: 400))],
            usableFrame: CGRect(x: 0, y: 0, width: 800, height: 800), gap: 8, generation: 1,
            phase: .restoration)
        XCTAssertNotEqual(rollback.verdict, .accepted)
        XCTAssertEqual(rollback.actualFrames[9]?.width, 300)
    }

    func testHidingAWindowKeepsItsMarkAndOnlyAForgottenOrReopenedOneLosesIt() {
        let screen = SuspectTestScreen()
        let engine = TilingEngine(displayManager: DisplayManager(screenSource: { [screen] }))
        let id: CGWindowID = 4_000_000_823
        let key = FrameSuspects.Key(pid: 4242, windowID: id)
        defer { FrameSuspects.shared.forget(windowID: id) }

        FrameSuspects.shared.mark(key)
        engine.removeWindowID(id)
        XCTAssertTrue(FrameSuspects.shared.contains(key), "hidden, minimized or out of its tree: still suspect")

        engine.forgetRememberedSlot(id)
        XCTAssertFalse(FrameSuspects.shared.contains(key), "back after a verified close: a reused id starts clean")

        FrameSuspects.shared.mark(key)
        engine.forgetMinimumSize(windowID: id)
        XCTAssertFalse(FrameSuspects.shared.contains(key), "discovery forgot it")
    }

    func testAReturningSuspectIsConfirmedOnTheWindowServerNotOnTwoAXReads() {
        // after a hide and a return AX says 600 twice. the window server has 500
        let fake = Fake()
        let target = CGRect(x: 0, y: 0, width: 600, height: 400)
        fake.frames[9] = target
        let io = fake.io().withServer { _ in CGRect(x: 0, y: 0, width: 500, height: 400) }
        io.suspects.mark(.init(pid: 0, windowID: 9))
        let attempt = FrameSizingAttempt(io: io)
        let capture = attempt.captureFrames(windowIDs: [9], generation: 1)
        XCTAssertNil(attempt.alreadyApplied(targets: [.init(windowID: 9, frame: target)],
                                            originalFrames: capture.actualFrames,
                                            usableFrame: CGRect(x: 0, y: 0, width: 800, height: 800),
                                            gap: 8, generation: 1))
    }

    func testOneSuspectWindowDoesNotCostItsNeighboursTheInPlaceShortcut() {
        // both already on target. the suspect one is confirmed on the window
        // server, the other through AX, and nothing is written
        let fake = Fake()
        let left = CGRect(x: 0, y: 0, width: 400, height: 800)
        let right = CGRect(x: 408, y: 0, width: 400, height: 800)
        fake.frames[2] = CGRect(x: 0, y: 0, width: 999, height: 800) // AX is wrong about 2
        fake.frames[1] = right
        let io = fake.io().withServer { $0 == 2 ? left : nil }
        io.suspects.mark(.init(pid: 0, windowID: 2))
        let attempt = FrameSizingAttempt(io: io)
        let targets: [FrameSizingAttempt.Target] = [.init(windowID: 2, frame: left), .init(windowID: 1, frame: right)]
        let capture = attempt.captureFrames(windowIDs: [2, 1], generation: 1)
        let inPlace = attempt.alreadyApplied(targets: targets, originalFrames: capture.actualFrames,
                                             usableFrame: CGRect(x: 0, y: 0, width: 816, height: 800),
                                             gap: 8, generation: 1)
        XCTAssertEqual(inPlace?.verdict, .accepted)
        XCTAssertFalse(fake.operations.contains { $0.hasPrefix("size:") || $0.hasPrefix("position:") },
                       "zero setters")

        // and a suspect window that is off target on the server is not taken as in place
        let moved = fake.io().withServer { $0 == 2 ? CGRect(x: 0, y: 0, width: 500, height: 800) : nil }
        moved.suspects.mark(.init(pid: 0, windowID: 2))
        fake.frames[2] = left // AX says it is fine
        let stale = FrameSizingAttempt(io: moved).captureFrames(windowIDs: [2, 1], generation: 1)
        XCTAssertNil(FrameSizingAttempt(io: moved).alreadyApplied(
            targets: targets, originalFrames: stale.actualFrames,
            usableFrame: CGRect(x: 0, y: 0, width: 816, height: 800), gap: 8, generation: 1))
    }

    func testAWindowThatClosesDuringASetterIsUnavailableNotAWriteFailure() {
        let fake = Fake()
        fake.frames[9] = CGRect(x: 0, y: 0, width: 100, height: 100)
        fake.writeErrors = [.invalidUIElement]
        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: 9, frame: CGRect(x: 0, y: 0, width: 200, height: 200))],
            usableFrame: CGRect(x: 0, y: 0, width: 800, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.windowUnavailable(9)))
    }

    func testARefusedCandidateRollsBackAndTheRollbackIsJudgedTheSameWay() {
        let fake = Fake()
        let original = CGRect(x: 0, y: 0, width: 500, height: 800)
        let candidate = CGRect(x: 0, y: 0, width: 300, height: 800)
        fake.frames[14] = original
        // candidate: both sizes answered -25205. rollback: the same.
        // the window never moved: the window server has the original throughout
        fake.writeErrors = [.attributeUnsupported, .success, .attributeUnsupported,
                            .attributeUnsupported, .success, .attributeUnsupported]
        var io = fake.io()
        io.serverFrame = { _ in original }
        // already a suspect, so its original is the window server's
        io.suspects.mark(.init(pid: 0, windowID: 14))
        let attempt = FrameSizingAttempt(io: io)
        let capture = attempt.captureFrames(windowIDs: [14], generation: 1)
        let outcome = FrameSizingTransaction(attempt: attempt).apply(
            targets: [.init(windowID: 14, frame: candidate)], originalFrames: capture.actualFrames,
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(outcome.outcome, .rejectedRestored(reason: .writeFailed(14, .attributeUnsupported),
                                                          actualFrames: [14: original]))
    }

    func testACannotCompleteIsNeverLeftToTheWindowServer() {
        // a messaging timeout: the recovery retries it as a timeout
        let fake = Fake()
        fake.frames[9] = CGRect(x: 0, y: 0, width: 200, height: 200)
        fake.writeErrors = [.cannotComplete]
        var io = fake.io()
        io.serverFrame = { _ in CGRect(x: 0, y: 0, width: 200, height: 200) }
        let result = FrameSizingAttempt(io: io).apply(
            targets: [.init(windowID: 9, frame: CGRect(x: 0, y: 0, width: 200, height: 200))],
            usableFrame: CGRect(x: 0, y: 0, width: 800, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .rejected(.writeFailed(9, .cannotComplete)))
        XCTAssertTrue(result.progress.serverJudged.isEmpty)
    }

    func testFailedReadIsUnknownAndNeverSynthesizesTarget() {
        let fake = Fake()
        fake.frames[10] = CGRect(x: 0, y: 0, width: 100, height: 100)
        fake.reads[10] = [(.cannotComplete, nil)]
        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: 10, frame: CGRect(x: 0, y: 0, width: 200, height: 200))],
            usableFrame: CGRect(x: 0, y: 0, width: 800, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.readFailed(10, .cannotComplete)))
        XCTAssertTrue(result.actualFrames.isEmpty)
    }

    func testReadbackTimeoutSetupFailureIsUnknownReadFailure() {
        let fake = Fake()
        let id: CGWindowID = 41
        fake.frames[id] = CGRect(x: 0, y: 0, width: 100, height: 100)
        fake.timeoutErrors = [.success, .success, .success, .cannotComplete]
        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: id,
                            frame: CGRect(x: 0, y: 0, width: 200, height: 200))],
            usableFrame: CGRect(x: 0, y: 0, width: 800, height: 800),
            gap: 8,
            generation: 1
        )
        XCTAssertEqual(result.verdict, .unknown(.readFailed(id, .cannotComplete)))
        XCTAssertEqual(fake.operations, [
            "timeout:41", "size:41",
            "timeout:41", "position:41",
            "timeout:41", "size:41",
            "timeout:41"
        ])
    }

    func testSlowAXCallConsumesRealDeadline() {
        let fake = Fake()
        fake.frames[11] = CGRect(x: 0, y: 0, width: 100, height: 100)
        fake.callAdvance = 0.2
        var config = FrameSizingConfiguration()
        config.deadline = 0.1
        let result = FrameSizingAttempt(io: fake.io(), configuration: config).apply(
            targets: [.init(windowID: 11, frame: CGRect(x: 0, y: 0, width: 200, height: 200))],
            usableFrame: CGRect(x: 0, y: 0, width: 800, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.deadlineExceeded))
        XCTAssertEqual(fake.operations, ["timeout:11"])
    }

    func testFullLayoutRejectsPositionContainmentOverlapAndErasedGap() {
        func verdict(_ frames: [CGWindowID: CGRect], targets: [FrameSizingAttempt.Target], gap: CGFloat,
                     tolerance: CGFloat = 1) -> FrameSizingAttempt.Verdict {
            let fake = Fake()
            fake.frames = frames
            for target in targets {
                let frame = frames[target.windowID]!
                fake.reads[target.windowID] = Array(repeating: (.success, frame), count: 12)
                fake.sizeReads[target.windowID] = Array(repeating: (.success, frame.size), count: 12)
            }
            var config = FrameSizingConfiguration()
            config.positionTolerance = tolerance
            config.sizeTolerance = tolerance
            config.sizeOvershootTolerance = tolerance
            config.sizeUndershootTolerance = tolerance
            return FrameSizingAttempt(io: fake.io(), configuration: config).apply(targets: targets,
                usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: gap, generation: 1).verdict
        }
        let a = FrameSizingAttempt.Target(windowID: 12, frame: CGRect(x: 0, y: 0, width: 496, height: 800))
        let b = FrameSizingAttempt.Target(windowID: 13, frame: CGRect(x: 504, y: 0, width: 496, height: 800))
        XCTAssertEqual(verdict([12: CGRect(x: 2, y: 0, width: 496, height: 800)], targets: [a], gap: 8),
                       .rejected(.geometryMismatch(12)))
        XCTAssertEqual(verdict([12: CGRect(x: -2, y: 0, width: 496, height: 800)], targets: [a], gap: 8),
                       .rejected(.outsideUsableFrame(12)))
        let overlappingB = FrameSizingAttempt.Target(windowID: 13, frame: CGRect(x: 490, y: 0, width: 510, height: 800))
        XCTAssertEqual(verdict([12: a.frame, 13: overlappingB.frame], targets: [a, overlappingB], gap: 8),
                       .rejected(.overlap(12, 13)))
        XCTAssertEqual(verdict([12: CGRect(x: 0, y: 0, width: 499, height: 800), 13: CGRect(x: 502, y: 0, width: 498, height: 800)], targets: [a, b], gap: 8, tolerance: 3),
                       .rejected(.gapViolation(12, 13)))
    }

    func testRejectedCandidateRestoresOriginalFrames() {
        let fake = Fake()
        let original = CGRect(x: 0, y: 0, width: 500, height: 800)
        let candidate = CGRect(x: 0, y: 0, width: 300, height: 800)
        fake.frames[14] = original
        fake.reads[14] = Array(repeating: (.success, candidate), count: 9) + [(.success, original), (.success, original)]
        fake.sizeReads[14] = Array(repeating: (.success, CGSize(width: 400, height: 800)), count: 9) + [
                              (.success, original.size), (.success, original.size)]
        let attempt = FrameSizingAttempt(io: fake.io())
        let outcome = FrameSizingTransaction(attempt: attempt).apply(
            targets: [.init(windowID: 14, frame: candidate)], originalFrames: [14: original],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(outcome.outcome, .rejectedRestored(reason: .geometryMismatch(14), actualFrames: [14: original]))
    }

    // MARK: - a layout that already stands

    private func inPlaceFixture() -> (Fake, CGRect, CGRect, CGRect) {
        let fake = Fake()
        let left = CGRect(x: 8, y: 8, width: 492, height: 784)
        let right = CGRect(x: 508, y: 8, width: 492, height: 784)
        fake.frames[7] = left
        fake.frames[8] = right
        return (fake, left, right, CGRect(x: 0, y: 0, width: 1008, height: 800))
    }

    /// Most retiles are this: the other screen on a workspace switch, a
    /// move's source twice, a poll re-applying a tree. Every one of them
    /// sent three setters per window and waited a settle and a stable
    /// readback of frames that never moved.
    func testALayoutAlreadyInPlaceIsAcceptedFromTheCaptureWithoutAWriteOrAWait() throws {
        let (fake, left, right, usable) = inPlaceFixture()
        let result = try XCTUnwrap(FrameSizingAttempt(io: fake.io()).alreadyApplied(
            targets: [.init(windowID: 7, frame: left), .init(windowID: 8, frame: right)],
            originalFrames: [7: left, 8: right], usableFrame: usable, gap: 8, generation: 1))

        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertEqual(result.actualFrames, [7: left, 8: right])
        XCTAssertTrue(fake.operations.isEmpty, "the capture was the readback: \(fake.operations)")
        XCTAssertEqual(fake.time, 0, "no settle is waited for")
        XCTAssertTrue(result.progress.verifiedInPlace)
        XCTAssertTrue(result.progress.readbackComplete)
        XCTAssertTrue(FrameSizingProgressReport(candidate: result.progress).candidateVerified,
                      "a layout that stood counts as written, so it publishes")
    }

    func testAnOriginalWithinTheVerdictsToleranceIsInPlaceToo() {
        let (fake, left, right, usable) = inPlaceFixture()
        // a point off in position, as the verdict would accept after a write
        let sat = left.offsetBy(dx: 1, dy: 0)
        let result = FrameSizingAttempt(io: fake.io()).alreadyApplied(
            targets: [.init(windowID: 7, frame: left), .init(windowID: 8, frame: right)],
            originalFrames: [7: sat, 8: right], usableFrame: usable, gap: 8, generation: 1)

        XCTAssertEqual(result?.actualFrames, [7: sat, 8: right])
    }

    /// the cell of rounding the verdict allows after a write is not room
    /// to stand in: a window two points short of its slot has not been
    /// asked yet, and is written
    func testAnOriginalTwoPointsOffIsNotInPlace() {
        let (fake, left, right, usable) = inPlaceFixture()
        let narrow = CGRect(x: left.minX, y: left.minY, width: left.width - 2, height: left.height)
        XCTAssertNil(FrameSizingAttempt(io: fake.io()).alreadyApplied(
            targets: [.init(windowID: 7, frame: left), .init(windowID: 8, frame: right)],
            originalFrames: [7: narrow, 8: right], usableFrame: usable, gap: 8, generation: 1))
        let shifted = left.offsetBy(dx: 2, dy: 0)
        XCTAssertNil(FrameSizingAttempt(io: fake.io()).alreadyApplied(
            targets: [.init(windowID: 7, frame: left), .init(windowID: 8, frame: right)],
            originalFrames: [7: shifted, 8: right], usableFrame: usable, gap: 8, generation: 1))
    }

    func testOneWindowOffItsTargetIsNotInPlace() {
        let (fake, left, right, usable) = inPlaceFixture()
        let elsewhere = CGRect(x: 508, y: 8, width: 400, height: 784)
        XCTAssertNil(FrameSizingAttempt(io: fake.io()).alreadyApplied(
            targets: [.init(windowID: 7, frame: left), .init(windowID: 8, frame: right)],
            originalFrames: [7: left, 8: elsewhere], usableFrame: usable, gap: 8, generation: 1))
    }

    func testInPlaceFramesThatFailTogetherAreNotTakenAsALayout() {
        // both windows stand exactly on their targets, but the targets
        // overlap: standing there proves nothing about the layout
        let (fake, left, _, usable) = inPlaceFixture()
        let overlapping = CGRect(x: 400, y: 8, width: 492, height: 784)
        XCTAssertNil(FrameSizingAttempt(io: fake.io()).alreadyApplied(
            targets: [.init(windowID: 7, frame: left), .init(windowID: 8, frame: overlapping)],
            originalFrames: [7: left, 8: overlapping], usableFrame: usable, gap: 8, generation: 1))
    }

    func testASupersededInPlaceLayoutIsNotAccepted() {
        let (fake, left, right, usable) = inPlaceFixture()
        fake.generation = 2
        XCTAssertNil(FrameSizingAttempt(io: fake.io()).alreadyApplied(
            targets: [.init(windowID: 7, frame: left), .init(windowID: 8, frame: right)],
            originalFrames: [7: left, 8: right], usableFrame: usable, gap: 8, generation: 1))
    }

    /// The tiled drop is the transaction's one caller, and its originals are
    /// the press-time capture: a drop that rebuilds the layout the drag
    /// started from must still write the dragged window back, so the
    /// transaction never takes the standing layout.
    func testTheTransactionAlwaysWritesEvenWhenTheOriginalsMatchTheTargets() {
        let (fake, left, right, usable) = inPlaceFixture()
        let report = FrameSizingTransaction(attempt: FrameSizingAttempt(io: fake.io())).apply(
            targets: [.init(windowID: 7, frame: left), .init(windowID: 8, frame: right)],
            originalFrames: [7: left, 8: right], usableFrame: usable, gap: 8, generation: 1)

        XCTAssertEqual(report.outcome, .accepted(actualFrames: [7: left, 8: right]))
        XCTAssertTrue(fake.operations.contains("size:7") && fake.operations.contains("size:8"))
        XCTAssertTrue(report.progress.candidateVerified)
    }

    func testSupersededAttemptNeverRollsBack() {
        let fake = Fake()
        fake.frames[15] = CGRect(x: 0, y: 0, width: 500, height: 800)
        fake.callAdvance = 0
        var first = true
        let base = fake.io()
        let io = FrameSizingIO(setMessagingTimeout: base.setMessagingTimeout, writeSize: { id, size, timeout in
            let result = base.writeSize(id, size, timeout)
            if first { first = false; fake.generation = 2 }
            return result
        }, writePosition: base.writePosition, readPosition: base.readPosition, readSize: base.readSize,
           now: base.now, sleep: base.sleep, currentGeneration: base.currentGeneration)
        let outcome = FrameSizingTransaction(attempt: FrameSizingAttempt(io: io)).apply(
            targets: [.init(windowID: 15, frame: CGRect(x: 0, y: 0, width: 300, height: 800))],
            originalFrames: [15: CGRect(x: 0, y: 0, width: 500, height: 800)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(outcome.outcome, .degraded(candidateReason: .superseded,
                                          restorationReason: nil, actualFrames: [:]))
        XCTAssertEqual(fake.operations, ["timeout:15", "size:15"])
    }

    func testStableMismatchWaitsForMinimumSettleBeforeRejecting() {
        let fake = Fake()
        let id: CGWindowID = 16
        let target = CGRect(x: 0, y: 0, width: 300, height: 800)
        let refused = CGRect(x: 0, y: 0, width: 400, height: 800)
        fake.frames[id] = target
        fake.reads[id] = [(.success, refused), (.success, refused), (.success, target), (.success, target)]
        fake.sizeReads[id] = [(.success, refused.size), (.success, refused.size),
                              (.success, target.size), (.success, target.size)]
        var config = FrameSizingConfiguration()
        config.pollInterval = 0.04
        config.minimumMismatchSettle = 0.12
        let result = FrameSizingAttempt(io: fake.io(), configuration: config).apply(
            targets: [.init(windowID: id, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertEqual(fake.operations.filter { $0 == "position-read:16" }.count, 4)
    }

    func testCumulativeDriftDoesNotCountAsStable() {
        let fake = Fake()
        let id: CGWindowID = 17
        let target = CGRect(x: 0, y: 0, width: 300, height: 800)
        fake.frames[id] = target
        let samples = [0.0, 0.6, 1.2, 1.8].map { CGRect(x: $0, y: 0, width: 300, height: 800) }
        fake.reads[id] = samples.map { (.success, Optional($0)) }
        fake.sizeReads[id] = samples.map { (.success, Optional($0.size)) }
        var config = FrameSizingConfiguration()
        config.maximumAttempts = 4
        config.requiredStableSamples = 3
        config.positionTolerance = 2
        config.stableTolerance = 1
        let result = FrameSizingAttempt(io: fake.io(), configuration: config).apply(
            targets: [.init(windowID: id, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.attemptsExhausted))
    }

    func testInvalidAndDuplicateTargetsFailBeforeAXWrites() {
        let fake = Fake()
        let attempt = FrameSizingAttempt(io: fake.io())
        let usable = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let duplicate = attempt.apply(targets: [
            .init(windowID: 18, frame: CGRect(x: 0, y: 0, width: 300, height: 800)),
            .init(windowID: 18, frame: CGRect(x: 308, y: 0, width: 300, height: 800))
        ], usableFrame: usable, gap: 8, generation: 1)
        XCTAssertEqual(duplicate.verdict, .rejected(.duplicateWindowID(18)))
        XCTAssertTrue(fake.operations.isEmpty)

        let invalid = attempt.apply(targets: [
            .init(windowID: 19, frame: CGRect(x: CGFloat.nan, y: 0, width: 300, height: 800))
        ], usableFrame: usable, gap: 8, generation: 1)
        XCTAssertEqual(invalid.verdict, .rejected(.invalidFrame(19)))
        XCTAssertTrue(fake.operations.isEmpty)
    }

    func testPersistentRefusalRejectsOnlyAfterSettleFloor() {
        let fake = Fake()
        let target = CGRect(x: 0, y: 0, width: 300, height: 800)
        let refused = CGRect(x: 0, y: 0, width: 400, height: 800)
        fake.frames[20] = refused
        fake.reads[20] = Array(repeating: (.success, refused), count: 12)
        fake.sizeReads[20] = Array(repeating: (.success, refused.size), count: 12)
        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: 20, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .rejected(.geometryMismatch(20)))
        XCTAssertGreaterThanOrEqual(fake.time, 0.24)
    }

    func testCaptureRequiresCompleteReadableFrames() {
        let fake = Fake()
        fake.frames[21] = CGRect(x: 1, y: 2, width: 300, height: 400)
        let success = FrameSizingAttempt(io: fake.io()).captureFrames(windowIDs: [21], generation: 1)
        XCTAssertEqual(success.verdict, .accepted)
        XCTAssertEqual(success.actualFrames[21], fake.frames[21])

        let missing = FrameSizingAttempt(io: fake.io()).captureFrames(windowIDs: [21, 22], generation: 1)
        XCTAssertEqual(missing.verdict, .unknown(.windowUnavailable(22)))
        XCTAssertEqual(missing.actualFrames, [21: fake.frames[21]!])
    }

    func testUnavailableWindowIsUnknownRatherThanExplicitRejection() {
        let fake = Fake()
        fake.timeoutErrors = [.invalidUIElement]
        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: 23, frame: CGRect(x: 0, y: 0, width: 300, height: 400))],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.windowUnavailable(23)))
    }

    func testInvalidActualFrameIsUnknown() {
        let fake = Fake()
        fake.frames[24] = CGRect(x: 0, y: 0, width: 300, height: 400)
        let invalid = CGRect(x: CGFloat.nan, y: 0, width: 300, height: 400)
        fake.reads[24] = [(.success, invalid), (.success, invalid)]
        fake.sizeReads[24] = [(.success, invalid.size), (.success, invalid.size)]
        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: 24, frame: fake.frames[24]!)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.invalidFrame(24)))
    }

    func testRestorationFailureRetainsCandidateAndRestoreReasons() {
        let fake = Fake()
        let original = CGRect(x: 0, y: 0, width: 500, height: 800)
        let target = CGRect(x: 0, y: 0, width: 300, height: 800)
        let candidateRefusal = CGRect(x: 0, y: 0, width: 400, height: 800)
        let restoreRefusal = CGRect(x: 0, y: 0, width: 600, height: 800)
        fake.frames[25] = original
        fake.reads[25] = Array(repeating: (.success, candidateRefusal), count: 9)
            + Array(repeating: (.success, restoreRefusal), count: 9)
        fake.sizeReads[25] = Array(repeating: (.success, candidateRefusal.size), count: 9)
            + Array(repeating: (.success, restoreRefusal.size), count: 9)
        let outcome = FrameSizingTransaction(attempt: FrameSizingAttempt(io: fake.io())).apply(
            targets: [.init(windowID: 25, frame: target)], originalFrames: [25: original],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(outcome.outcome, .degraded(candidateReason: .geometryMismatch(25),
                                          restorationReason: .geometryMismatch(25),
                                          actualFrames: [25: restoreRefusal]))
    }

    func testPersistentGrowRefusalRejectsSmallerActualFrame() {
        let fake = Fake()
        let target = CGRect(x: 0, y: 0, width: 500, height: 800)
        let refused = CGRect(x: 0, y: 0, width: 400, height: 800)
        fake.frames[26] = target
        fake.reads[26] = Array(repeating: (.success, refused), count: 9)
        fake.sizeReads[26] = Array(repeating: (.success, refused.size), count: 9)
        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: 26, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .rejected(.geometryMismatch(26)))
    }

    func testPositionWriteFailureStopsBeforeSecondSizeWrite() {
        let fake = Fake()
        fake.frames[27] = CGRect(x: 0, y: 0, width: 300, height: 400)
        fake.writeErrors = [.success, .cannotComplete]
        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: 27, frame: CGRect(x: 20, y: 20, width: 300, height: 400))],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .rejected(.writeFailed(27, .cannotComplete)))
        XCTAssertEqual(fake.operations.filter { $0 == "size:27" }.count, 1)
        XCTAssertEqual(fake.operations.filter { $0 == "position:27" }.count, 1)
    }

    func testClampedPositionRejectsWithCorrectSize() {
        let fake = Fake()
        let target = CGRect(x: 100, y: 0, width: 300, height: 400)
        let clamped = CGRect(x: 80, y: 0, width: 300, height: 400)
        fake.frames[28] = target
        fake.reads[28] = Array(repeating: (.success, clamped), count: 9)
        fake.sizeReads[28] = Array(repeating: (.success, target.size), count: 9)
        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: 28, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .rejected(.geometryMismatch(28)))
    }

    func testSizeReadFailureAndIntermittentFailureRemainUnknown() {
        let target = CGRect(x: 0, y: 0, width: 300, height: 400)
        let first = Fake()
        first.frames[29] = target
        first.sizeReads[29] = [(.cannotComplete, nil)]
        let failed = FrameSizingAttempt(io: first.io()).apply(
            targets: [.init(windowID: 29, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(failed.verdict, .unknown(.readFailed(29, .cannotComplete)))
        XCTAssertTrue(failed.actualFrames.isEmpty)

        let second = Fake()
        second.frames[30] = target
        second.reads[30] = [(.success, target), (.cannotComplete, nil)]
        second.sizeReads[30] = [(.success, target.size)]
        let intermittent = FrameSizingAttempt(io: second.io()).apply(
            targets: [.init(windowID: 30, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(intermittent.verdict, .unknown(.readFailed(30, .cannotComplete)))
        XCTAssertEqual(intermittent.actualFrames, [30: target])
    }

    func testNeverSettledStopsAtMonotonicDeadline() {
        let fake = Fake()
        let target = CGRect(x: 0, y: 0, width: 300, height: 400)
        fake.frames[31] = target
        let samples = (0..<12).map { CGRect(x: CGFloat($0 * 3), y: 0, width: 300, height: 400) }
        fake.reads[31] = samples.map { (.success, Optional($0)) }
        fake.sizeReads[31] = samples.map { (.success, Optional($0.size)) }
        var config = FrameSizingConfiguration()
        config.deadline = 0.1
        config.pollInterval = 0.03
        let result = FrameSizingAttempt(io: fake.io(), configuration: config).apply(
            targets: [.init(windowID: 31, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.deadlineExceeded))
        XCTAssertGreaterThanOrEqual(fake.time, 0.1)
    }

    // a position-first write whose position never reads back on target used
    // to poll out the whole deadline with no size written. the settle has a
    // budget: past it the size goes out anyway and the readback judges
    func testPositionSettleIsBoundedAndSizesBeforeTheDeadline() {
        let fake = Fake()
        let id: CGWindowID = 40
        let target = CGRect(x: 8, y: 41, width: 1496, height: 841)
        fake.frames[id] = CGRect(x: 2600, y: -450, width: 3424, height: 1391)
        // the window keeps reading back 30 points below where it was sent
        let landed = CGRect(x: 8, y: 71, width: 1496, height: 841)
        fake.reads[id] = Array(repeating: (.success, Optional(landed)), count: 60)
        var config = FrameSizingConfiguration()
        config.positionSettleWindowIDs = [id]

        let result = FrameSizingAttempt(io: fake.io(), configuration: config).apply(
            targets: [.init(windowID: id, frame: target)],
            usableFrame: CGRect(x: 0, y: 33, width: 1512, height: 900), gap: 8, generation: 1)

        XCTAssertEqual(fake.operations.filter { $0.hasPrefix("size:") || $0.hasPrefix("position:") },
                       ["position:40", "size:40", "size:40"])
        let firstSize = fake.sizeWriteTimes.first ?? .infinity
        XCTAssertLessThan(firstSize, config.deadline, "a size went out inside the deadline")
        XCTAssertLessThanOrEqual(firstSize, config.positionSettleBudget + config.pollInterval)
        XCTAssertEqual(result.verdict, .rejected(.geometryMismatch(id)),
                       "the readback judged the landed frame")
        XCTAssertEqual(result.progress.writesCompleted, [id])
    }

    func testPositionSettleBudgetGrowsWithTheScaleChangeDeadline() {
        let ordinary = FrameSizingConfiguration()
        XCTAssertLessThan(ordinary.positionSettleBudget, ordinary.deadline / 2)
        XCTAssertGreaterThan(ordinary.withScaleChangeBudget.positionSettleBudget,
                             ordinary.positionSettleBudget)
    }

    func testDefaultToleranceRejectsGapErosionBeyondOneCellAndAcceptsSafeShift() {
        func run(_ actualA: CGRect, _ actualB: CGRect) -> FrameSizingAttempt.Verdict {
            let fake = Fake()
            let a = CGRect(x: 0, y: 0, width: 496, height: 800)
            let b = CGRect(x: 504, y: 0, width: 496, height: 800)
            fake.frames = [32: a, 33: b]
            fake.reads[32] = [(.success, actualA), (.success, actualA)]
            fake.reads[33] = [(.success, actualB), (.success, actualB)]
            fake.sizeReads[32] = [(.success, actualA.size), (.success, actualA.size)]
            fake.sizeReads[33] = [(.success, actualB.size), (.success, actualB.size)]
            return FrameSizingAttempt(io: fake.io()).apply(
                targets: [.init(windowID: 32, frame: a), .init(windowID: 33, frame: b)],
                usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1).verdict
        }
        // a rounded-up window that runs 14 pt into its neighbour is a real
        // overlap, and the overlap check is the one that names it
        XCTAssertEqual(run(CGRect(x: 1, y: 0, width: 516, height: 800),
                           CGRect(x: 503, y: 0, width: 496, height: 800)),
                       .rejected(.overlap(32, 33)))
        // eaten down to contact, without overlapping: the gap check
        XCTAssertEqual(run(CGRect(x: 0, y: 0, width: 503, height: 800),
                           CGRect(x: 503, y: 0, width: 497, height: 800)),
                       .rejected(.gapViolation(32, 33)))
        // a single rounded-up point eats into the gap and is still allowed
        XCTAssertEqual(run(CGRect(x: 0, y: 0, width: 497, height: 800),
                           CGRect(x: 503, y: 0, width: 497, height: 800)), .accepted)
        XCTAssertEqual(run(CGRect(x: 1, y: 0, width: 496, height: 800),
                           CGRect(x: 505, y: 0, width: 495, height: 800)), .accepted)
    }

    func testSmallCellQuantizedUndershootIsAcceptedWithObservedFrame() {
        let fake = Fake()
        let id: CGWindowID = 61
        let target = CGRect(x: 20, y: 20, width: 812, height: 1044)
        let quantized = CGRect(x: 20, y: 20, width: 806, height: 1040)
        fake.frames[id] = target
        fake.reads[id] = Array(repeating: (.success, quantized), count: 12)
        fake.sizeReads[id] = Array(repeating: (.success, quantized.size), count: 12)

        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: id, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1200, height: 1200),
            gap: 8,
            generation: 1
        )

        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertEqual(result.actualFrames[id], quantized)
    }

    func testCellQuantizedOvershootIsAcceptedWithObservedFrame() {
        let fake = Fake()
        let id: CGWindowID = 66
        // terminal rounds a full-workspace target up to whole character cells
        let target = CGRect(x: 8, y: 8, width: 3424, height: 1301)
        let quantized = CGRect(x: 8, y: 8, width: 3425, height: 1309)
        fake.frames[id] = target
        fake.reads[id] = Array(repeating: (.success, quantized), count: 12)
        fake.sizeReads[id] = Array(repeating: (.success, quantized.size), count: 12)

        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: id, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 3440, height: 1400),
            gap: 8,
            generation: 1
        )

        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertEqual(result.actualFrames[id], quantized)
    }

    func testOvershootBeyondOneCellIsStillRejected() {
        let fake = Fake()
        let id: CGWindowID = 67
        let target = CGRect(x: 8, y: 8, width: 3424, height: 1301)
        let oversize = CGRect(x: 8, y: 8, width: 3449, height: 1301)
        fake.frames[id] = target
        fake.reads[id] = Array(repeating: (.success, oversize), count: 12)
        fake.sizeReads[id] = Array(repeating: (.success, oversize.size), count: 12)

        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: id, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 3600, height: 1400),
            gap: 8,
            generation: 1
        )

        XCTAssertEqual(result.verdict, .rejected(.geometryMismatch(id)))
    }

    func testQuantizationAllowanceRejectsOvershootLargeUndershootAndPositionDrift() {
        let target = FrameSizingAttempt.Target(
            windowID: 62,
            frame: CGRect(x: 20, y: 20, width: 812, height: 700)
        )
        let attempt = FrameSizingAttempt(io: Fake().io())
        let usable = CGRect(x: 0, y: 0, width: 1200, height: 900)

        for actual in [
            CGRect(x: 20, y: 20, width: 833, height: 700),
            CGRect(x: 20, y: 20, width: 791, height: 700),
            CGRect(x: 22, y: 20, width: 806, height: 700)
        ] {
            let result = attempt.validateFrames(
                targets: [target], actualFrames: [62: actual],
                usableFrame: usable, gap: 8
            )
            XCTAssertEqual(result.verdict, .rejected(.geometryMismatch(62)), "\(actual)")
        }
    }

    func testEdgeOvershootMayFillThePaddingButNotEscapeTheScreen() {
        let attempt = FrameSizingAttempt(io: Fake().io())
        // 8 pt of outer padding, so the slot stops 8 pt short of the screen
        // edge and a window that rounds up runs into that padding
        let usable = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let target = FrameSizingAttempt.Target(
            windowID: 70,
            frame: CGRect(x: 8, y: 8, width: 984, height: 684)
        )
        func verdict(_ actual: CGRect) -> FrameSizingAttempt.Verdict {
            attempt.validateFrames(targets: [target], actualFrames: [70: actual],
                                   usableFrame: usable, gap: 8).verdict
        }

        // rounding up into the padding, stopping flush with the screen edge
        XCTAssertEqual(verdict(CGRect(x: 8, y: 8, width: 984, height: 692)), .accepted)
        // one point past it is comparison slack
        XCTAssertEqual(verdict(CGRect(x: 8, y: 8, width: 984, height: 693)), .accepted)
        // 4 pt past it is a window off the screen, whatever its size match says
        XCTAssertEqual(verdict(CGRect(x: 8, y: 8, width: 984, height: 696)),
                       .rejected(.outsideUsableFrame(70)))
        XCTAssertEqual(verdict(CGRect(x: 8, y: 8, width: 984, height: 704)),
                       .rejected(.outsideUsableFrame(70)))
        // the origin keeps the same one point it always had
        XCTAssertEqual(verdict(CGRect(x: 8, y: -2, width: 984, height: 684)),
                       .rejected(.outsideUsableFrame(70)))
    }

    func testRestorationContainmentStaysTightAtOnePoint() {
        var strict = FrameSizingConfiguration()
        strict.sizeOvershootTolerance = strict.sizeTolerance
        strict.sizeUndershootTolerance = strict.sizeTolerance
        let attempt = FrameSizingAttempt(io: Fake().io(), configuration: strict)
        let usable = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let target = FrameSizingAttempt.Target(
            windowID: 71,
            frame: CGRect(x: 8, y: 8, width: 984, height: 684)
        )
        XCTAssertEqual(attempt.validateFrames(
            targets: [target], actualFrames: [71: CGRect(x: 8, y: 8, width: 984, height: 696)],
            usableFrame: usable, gap: 8
        ).verdict, .rejected(.outsideUsableFrame(71)))
    }

    func testQuantizedDeviationBoundsContainmentAndGapErosion() {
        let attempt = FrameSizingAttempt(io: Fake().io())
        let targets = [
            FrameSizingAttempt.Target(windowID: 63, frame: CGRect(x: 0, y: 0, width: 496, height: 800)),
            FrameSizingAttempt.Target(windowID: 64, frame: CGRect(x: 504, y: 0, width: 496, height: 800))
        ]
        let usable = CGRect(x: 0, y: 0, width: 1000, height: 800)

        XCTAssertEqual(attempt.validateFrames(
            targets: targets,
            actualFrames: [
                63: CGRect(x: 0, y: 0, width: 490, height: 800),
                64: CGRect(x: 504, y: 0, width: 490, height: 800)
            ], usableFrame: usable, gap: 8
        ).verdict, .accepted)
        // a rounded-up point may eat into the gap
        XCTAssertEqual(attempt.validateFrames(
            targets: targets,
            actualFrames: [63: CGRect(x: 0, y: 0, width: 497, height: 800), 64: targets[1].frame],
            usableFrame: usable, gap: 8
        ).verdict, .accepted)
        // erosion all the way through the gap is a real overlap
        XCTAssertEqual(attempt.validateFrames(
            targets: targets,
            actualFrames: [63: CGRect(x: 1, y: 0, width: 516, height: 800),
                           64: CGRect(x: 503, y: 0, width: 496, height: 800)],
            usableFrame: usable, gap: 8
        ).verdict, .rejected(.overlap(63, 64)))
        let wideGapTargets = [
            FrameSizingAttempt.Target(windowID: 63, frame: CGRect(x: 0, y: 0, width: 485, height: 800)),
            FrameSizingAttempt.Target(windowID: 64, frame: CGRect(x: 515, y: 0, width: 485, height: 800))
        ]
        XCTAssertEqual(attempt.validateFrames(
            targets: wideGapTargets,
            actualFrames: [63: CGRect(x: 0, y: 0, width: 505, height: 800),
                           64: CGRect(x: 514, y: 0, width: 485, height: 800)],
            usableFrame: usable, gap: 30
        ).verdict, .rejected(.gapViolation(63, 64)))
        // the origin is allowed one point of drift, no more
        XCTAssertEqual(attempt.validateFrames(
            targets: [targets[0]],
            actualFrames: [63: CGRect(x: -2, y: 0, width: 490, height: 800)],
            usableFrame: usable, gap: 8
        ).verdict, .rejected(.outsideUsableFrame(63)))
    }

    func testBoundedOvershootEatsTheGapButNeverTheNeighbour() {
        let attempt = FrameSizingAttempt(io: Fake().io())
        // stacked windows, 8 pt gap; the top one rounds taller and eats the
        // gap down to one point, which is as far as it gets
        let stacked = [
            FrameSizingAttempt.Target(windowID: 68, frame: CGRect(x: 0, y: 0, width: 500, height: 300)),
            FrameSizingAttempt.Target(windowID: 69, frame: CGRect(x: 0, y: 308, width: 500, height: 300))
        ]
        XCTAssertEqual(attempt.validateFrames(
            targets: stacked,
            actualFrames: [68: CGRect(x: 0, y: 0, width: 500, height: 307), 69: stacked[1].frame],
            usableFrame: CGRect(x: 0, y: 0, width: 600, height: 700), gap: 8
        ).verdict, .accepted)

        // 15 pt taller puts it 7 pt into its neighbour along y and the full
        // width along x, which is a window on top of another window
        XCTAssertEqual(attempt.validateFrames(
            targets: stacked,
            actualFrames: [68: CGRect(x: 0, y: 0, width: 500, height: 315), 69: stacked[1].frame],
            usableFrame: CGRect(x: 0, y: 0, width: 600, height: 700), gap: 8
        ).verdict, .rejected(.overlap(68, 69)))

        // two windows genuinely on top of each other, sharing 200x200
        let piled = [
            FrameSizingAttempt.Target(windowID: 68, frame: CGRect(x: 0, y: 0, width: 600, height: 600)),
            FrameSizingAttempt.Target(windowID: 69, frame: CGRect(x: 400, y: 400, width: 600, height: 600))
        ]
        XCTAssertEqual(attempt.validateFrames(
            targets: piled,
            actualFrames: [68: piled[0].frame, 69: piled[1].frame],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000), gap: 8
        ).verdict, .rejected(.overlap(68, 69)))
    }

    func testAggregateOverlapRejectsBeyondTheSlackOnBothAxes() {
        let attempt = FrameSizingAttempt(io: Fake().io())
        let usable = CGRect(x: 0, y: 0, width: 300, height: 200)
        // no gap, so the gap rule asks for nothing and the overlap rule is
        // the only pairwise judge. every actual size here matches its target
        // inside the per-window allowance, so nothing but aggregate safety
        // can reject these
        func verdict(firstWidth: CGFloat, secondY: CGFloat = 0) -> FrameSizingAttempt.Verdict {
            let targets = [
                FrameSizingAttempt.Target(windowID: 74, frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
                FrameSizingAttempt.Target(windowID: 75, frame: CGRect(x: 100, y: secondY, width: 100, height: 100))
            ]
            let actual: [CGWindowID: CGRect] = [
                74: CGRect(x: 0, y: 0, width: firstWidth, height: 100),
                75: targets[1].frame
            ]
            return attempt.validateFrames(targets: targets, actualFrames: actual,
                                          usableFrame: usable, gap: 0).verdict
        }

        XCTAssertEqual(verdict(firstWidth: 100), .accepted)
        // half a point of rounding is comparison slack, not an overlap
        XCTAssertEqual(verdict(firstWidth: 100.5), .accepted)
        XCTAssertEqual(verdict(firstWidth: 101), .accepted)
        XCTAssertEqual(verdict(firstWidth: 102), .rejected(.overlap(74, 75)))
        XCTAssertEqual(verdict(firstWidth: 112), .rejected(.overlap(74, 75)))
        // 12 pt along x, but the y overlap is within the slack, and a
        // rejection needs both axes past it
        XCTAssertEqual(verdict(firstWidth: 112, secondY: 99), .accepted)
    }

    func testGapErosionKeepsOnePointOfSeparationAtAnyPositiveGap() {
        let attempt = FrameSizingAttempt(io: Fake().io())
        let usable = CGRect(x: 0, y: 0, width: 300, height: 100)
        func verdict(gap: CGFloat, firstWidth: CGFloat, secondX: CGFloat? = nil) -> FrameSizingAttempt.Verdict {
            let targets = [
                FrameSizingAttempt.Target(windowID: 76, frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
                FrameSizingAttempt.Target(windowID: 77, frame: CGRect(x: 100 + gap, y: 0, width: 100, height: 100))
            ]
            let actual: [CGWindowID: CGRect] = [
                76: CGRect(x: 0, y: 0, width: firstWidth, height: 100),
                77: CGRect(x: secondX ?? (100 + gap), y: 0, width: 100, height: 100)
            ]
            return attempt.validateFrames(targets: targets, actualFrames: actual,
                                          usableFrame: usable, gap: gap).verdict
        }

        // the shipping gap: erosion down to one point of separation is fine,
        // contact is not, and overlap is an overlap
        XCTAssertEqual(verdict(gap: 8, firstWidth: 107), .accepted)
        XCTAssertEqual(verdict(gap: 8, firstWidth: 108), .rejected(.gapViolation(76, 77)))
        XCTAssertEqual(verdict(gap: 8, firstWidth: 110), .rejected(.overlap(76, 77)))
        // a 2 pt gap has one point to give
        XCTAssertEqual(verdict(gap: 2, firstWidth: 101), .accepted)
        XCTAssertEqual(verdict(gap: 2, firstWidth: 102), .rejected(.gapViolation(76, 77)))
        // a gap wider than the cell allowance keeps the rest of itself
        XCTAssertEqual(verdict(gap: 30, firstWidth: 119, secondX: 129), .accepted)
        XCTAssertEqual(verdict(gap: 30, firstWidth: 120, secondX: 129),
                       .rejected(.gapViolation(76, 77)))
        // a zero gap asks for no separation at all
        XCTAssertEqual(verdict(gap: 0, firstWidth: 100), .accepted)
        XCTAssertEqual(verdict(gap: 0, firstWidth: 100.5), .accepted)
        XCTAssertEqual(verdict(gap: 0, firstWidth: 102), .rejected(.overlap(76, 77)))
    }

    // issue #19, claim 1: a keyboard resize on the DELL (gap 8, padding 8)
    // was refused as gapViolation(115, 74) when each window was within a
    // point of its own target. a pair the per-window check accepts at that
    // precision must not fail the gap check.
    func testAPointOffPerWindowNeverFailsTheGapCheckAtTheShippingGap() {
        let attempt = FrameSizingAttempt(io: Fake().io())
        let usable = CGRect(x: 0, y: 30, width: 3440, height: 1410)
        let splits: [(left: CGRect, right: CGRect)] = [
            (CGRect(x: 8, y: 38, width: 2050, height: 1394), CGRect(x: 2066, y: 38, width: 1366, height: 1394)),
            (CGRect(x: 8, y: 38, width: 1708, height: 1394), CGRect(x: 1724, y: 38, width: 1708, height: 1394))
        ]
        func verdict(_ left: CGRect, _ right: CGRect, _ actualLeft: CGRect, _ actualRight: CGRect)
            -> FrameSizingAttempt.Verdict {
            attempt.validateFrames(
                targets: [FrameSizingAttempt.Target(windowID: 115, frame: left),
                          FrameSizingAttempt.Target(windowID: 74, frame: right)],
                actualFrames: [115: actualLeft, 74: actualRight],
                usableFrame: usable, gap: 8).verdict
        }

        // the two frames quoted in the issue
        let (left, right) = splits[0]
        XCTAssertEqual(verdict(left, right, CGRect(x: 8, y: 38, width: 2051, height: 1394), right), .accepted)
        XCTAssertEqual(verdict(left, right, CGRect(x: 8, y: 38, width: 2051, height: 1394),
                               CGRect(x: 2065, y: 38, width: 1366, height: 1394)), .accepted)

        // every combination of a point off in x and width on both windows
        let offsets: [CGFloat] = [-1, 0, 1]
        for (left, right) in splits {
            for lx in offsets { for lw in offsets { for rx in offsets { for rw in offsets {
                let actualLeft = CGRect(x: left.minX + lx, y: left.minY, width: left.width + lw, height: left.height)
                let actualRight = CGRect(x: right.minX + rx, y: right.minY, width: right.width + rw, height: right.height)
                XCTAssertEqual(verdict(left, right, actualLeft, actualRight), .accepted,
                               "left \(actualLeft) right \(actualRight)")
            } } } }
        }
    }

    func testHalfPointTargetsPassAggregateSafetyOnIntegerReadback() {
        let attempt = FrameSizingAttempt(io: Fake().io())
        // a dwindle split lands on the half point and both windows answer on
        // the integer, which must not read as gap erosion or escape
        let targets = [
            FrameSizingAttempt.Target(windowID: 78, frame: CGRect(x: 8, y: 41, width: 744, height: 416.5)),
            FrameSizingAttempt.Target(windowID: 79, frame: CGRect(x: 8, y: 465.5, width: 744, height: 416.5))
        ]
        XCTAssertEqual(attempt.validateFrames(
            targets: targets,
            actualFrames: [78: CGRect(x: 8, y: 41, width: 744, height: 416),
                           79: CGRect(x: 8, y: 465, width: 744, height: 417)],
            usableFrame: CGRect(x: 0, y: 0, width: 760, height: 890), gap: 8
        ).verdict, .accepted)
    }

    func testRestorationAggregateRulesAreUnchangedByTheSlack() {
        var strict = FrameSizingConfiguration()
        strict.sizeOvershootTolerance = strict.sizeTolerance
        strict.sizeUndershootTolerance = strict.sizeTolerance
        strict.correspondenceOnly = true
        let attempt = FrameSizingAttempt(io: Fake().io(), configuration: strict)
        let usable = CGRect(x: 0, y: 0, width: 1000, height: 700)

        // originals that sat on top of each other go back on top of each
        // other, and that is still correspondence rather than a verdict
        let stacked = CGRect(x: 40, y: 40, width: 400, height: 300)
        let result = attempt.validateFrames(
            targets: [.init(windowID: 80, frame: stacked), .init(windowID: 81, frame: stacked)],
            actualFrames: [80: stacked, 81: stacked], usableFrame: usable, gap: 8
        )
        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertEqual(result.overlaps, [FrameSizingOverlap(first: 80, second: 81)])

        // containment is not correspondence: an original 2 pt off the screen
        // is still off the screen
        let escaping = CGRect(x: 8, y: 8, width: 984, height: 694)
        XCTAssertEqual(attempt.validateFrames(
            targets: [.init(windowID: 82, frame: escaping)],
            actualFrames: [82: escaping], usableFrame: usable, gap: 8
        ).verdict, .rejected(.outsideUsableFrame(82)))

        // and the strictness is the rollback's own, not the caller's: a
        // candidate slack of 12 would swallow those 2 pt, and both rollback
        // paths build their configuration from sizeTolerance instead
        var loose = FrameSizingConfiguration()
        loose.aggregateSafetySlack = 12
        let fake = Fake()
        fake.frames[83] = escaping
        let rolledBack = FrameSizingTransaction(
            attempt: FrameSizingAttempt(io: fake.io(), configuration: loose)
        ).restore(originalFrames: [83: escaping], usableFrame: usable, gap: 8, generation: 1)
        XCTAssertEqual(rolledBack.verdict, .rejected(.outsideUsableFrame(83)))

        let window = makeWindow(id: 84)
        var pollerTime: TimeInterval = 0
        let pollerIO = FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { _, _, _ in .success },
            writePosition: { _, _, _ in .success },
            readPosition: { _, _ in (.success, escaping.origin) },
            readSize: { _, _ in (.success, escaping.size) },
            now: { pollerTime }, sleep: { pollerTime += $0 }, currentGeneration: { 1 }
        )
        let polled = FrameReadbackPoller(configuration: loose, generation: { 1 },
                                         ioFactory: { _, _ in pollerIO })
            .applyRestoration([(window, escaping)], usableFrame: usable, gap: 8, generation: 1)
        XCTAssertEqual(polled.verdict, .rejected(.outsideUsableFrame(84)))
    }

    func testRestorationRequiresExactSizeDespiteCandidateQuantizationAllowance() {
        let id: CGWindowID = 65
        func restore(reading restored: CGRect) -> FrameSizingTransaction.Outcome {
            let fake = Fake()
            let original = CGRect(x: 20, y: 20, width: 812, height: 700)
            fake.frames[id] = original
            fake.writeErrors = [.cannotComplete]
            fake.reads[id] = Array(repeating: (.success, restored), count: 12)
            fake.sizeReads[id] = Array(repeating: (.success, restored.size), count: 12)
            return FrameSizingTransaction(attempt: FrameSizingAttempt(io: fake.io())).apply(
                targets: [.init(windowID: id, frame: CGRect(x: 20, y: 20, width: 600, height: 700))],
                originalFrames: [id: original],
                usableFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
                gap: 8,
                generation: 1
            ).outcome
        }

        // both directions the candidate pass would have accepted
        for restored in [CGRect(x: 20, y: 20, width: 806, height: 700),
                         CGRect(x: 20, y: 20, width: 814, height: 700)] {
            XCTAssertEqual(restore(reading: restored), .degraded(
                candidateReason: .writeFailed(id, .cannotComplete),
                restorationReason: .geometryMismatch(id),
                actualFrames: [id: restored]
            ), "\(restored)")
        }
    }

    func testCaptureStopsWhenSizeTimeoutSetupCrossesDeadline() {
        let fake = Fake()
        fake.frames[34] = CGRect(x: 0, y: 0, width: 300, height: 400)
        fake.timeoutAdvances = [0, 0.2]
        var config = FrameSizingConfiguration()
        config.deadline = 0.1
        let result = FrameSizingAttempt(io: fake.io(), configuration: config)
            .captureFrames(windowIDs: [34], generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.deadlineExceeded))
        XCTAssertFalse(fake.operations.contains("size-read:34"))
    }

    func testCaptureRejectsDuplicateAndInvalidFrames() {
        let fake = Fake()
        fake.frames[35] = CGRect(x: 0, y: 0, width: 300, height: 400)
        let duplicate = FrameSizingAttempt(io: fake.io()).captureFrames(windowIDs: [35, 35], generation: 1)
        XCTAssertEqual(duplicate.verdict, .unknown(.duplicateWindowID(35)))

        let invalid = CGRect(x: CGFloat.nan, y: 0, width: 300, height: 400)
        fake.reads[35] = [(.success, invalid)]
        fake.sizeReads[35] = [(.success, invalid.size)]
        let invalidResult = FrameSizingAttempt(io: fake.io()).captureFrames(windowIDs: [35], generation: 1)
        XCTAssertEqual(invalidResult.verdict, .unknown(.invalidFrame(35)))
    }

    func testEmptyOperationsStillHonorSupersession() {
        let fake = Fake()
        fake.generation = 2
        let attempt = FrameSizingAttempt(io: fake.io())
        XCTAssertEqual(attempt.apply(targets: [], usableFrame: .zero, gap: 8, generation: 1).verdict,
                       .unknown(.superseded))
        XCTAssertEqual(attempt.captureFrames(windowIDs: [], generation: 1).verdict,
                       .unknown(.superseded))
    }

    func testNegativeRawTargetSizeRejectsBeforeWrites() {
        let fake = Fake()
        let raw = CGRect(origin: .zero, size: CGSize(width: -300, height: 400))
        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: 36, frame: raw)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .rejected(.invalidFrame(36)))
        XCTAssertTrue(fake.operations.isEmpty)
    }

    func testFrameWriteUsesOneBracketAroundResizeMoveResize() {
        let fake = Fake()
        let id: CGWindowID = 39
        let target = CGRect(x: 8, y: 8, width: 492, height: 784)
        fake.frames[id] = target
        let base = fake.io()
        let token = AXFrameWriteBatch.Token.noop(windowID: id)
        let io = FrameSizingIO(
            setMessagingTimeout: base.setMessagingTimeout,
            writeSize: base.writeSize,
            writePosition: base.writePosition,
            readPosition: base.readPosition,
            readSize: base.readSize,
            now: base.now,
            sleep: base.sleep,
            currentGeneration: base.currentGeneration,
            beginFrameWrite: { [unowned fake] windowID, _, _ in
                fake.operations.append("begin:\(windowID)")
                return .ready(token)
            },
            endFrameWrite: { [unowned fake] _, _, _ in
                fake.operations.append("end")
                return .restored
            }
        )

        XCTAssertEqual(FrameSizingAttempt(io: io).apply(
            targets: [.init(windowID: id, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            gap: 8, generation: 1).verdict, .accepted)
        let writes = fake.operations.filter { operation in
            operation == "begin:39" || operation == "size:39"
                || operation == "position:39" || operation == "end"
        }
        XCTAssertEqual(writes, ["begin:39", "size:39", "position:39", "size:39", "end"])
    }

    func testFrameWriteFailureStillEndsBracket() {
        for failingWrite in 0..<3 {
            let fake = Fake()
            let id = CGWindowID(40 + failingWrite)
            fake.frames[id] = CGRect(x: 0, y: 0, width: 500, height: 500)
            fake.writeErrors = (0..<3).map { $0 == failingWrite ? .cannotComplete : .success }
            let base = fake.io()
            let io = FrameSizingIO(
                setMessagingTimeout: base.setMessagingTimeout,
                writeSize: base.writeSize,
                writePosition: base.writePosition,
                readPosition: base.readPosition,
                readSize: base.readSize,
                now: base.now,
                sleep: base.sleep,
                currentGeneration: base.currentGeneration,
                beginFrameWrite: { _, _, _ in .ready(.noop(windowID: id)) },
                endFrameWrite: { [unowned fake] _, _, _ in
                    fake.operations.append("end")
                    return .restored
                }
            )
            _ = FrameSizingAttempt(io: io).apply(
                targets: [.init(windowID: id, frame: CGRect(x: 0, y: 0, width: 300, height: 300))],
                usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
            XCTAssertEqual(fake.operations.filter { $0 == "end" }.count, 1,
                           "write index \(failingWrite) did not clean up")
        }
    }

    func testUnimplementedEnhancedUIDisableStillUsesAuthoritativeFrameResults() {
        func io(_ fake: Fake) -> FrameSizingIO {
            let base = fake.io()
            let batch = AXFrameWriteBatch(raw: .init(
                makeApplication: { _ in AXFrameWriteBatch.Application() },
                setApplicationTimeout: { _, _ in .success },
                copyEnhancedUI: { _ in (.success, kCFBooleanTrue) },
                setEnhancedUI: { _, enabled in enabled ? .success : .notImplemented }
            ))
            return FrameSizingIO(
                setMessagingTimeout: base.setMessagingTimeout,
                writeSize: base.writeSize,
                writePosition: base.writePosition,
                readPosition: base.readPosition,
                readSize: base.readSize,
                now: base.now,
                sleep: base.sleep,
                currentGeneration: base.currentGeneration,
                beginFrameWrite: { id, timeout, checkpoint in
                    batch.begin(ownerPID: pid_t(id), timeout: timeout, checkpoint: checkpoint)
                },
                endFrameWrite: { token, timeout, checkpoint in
                    batch.end(token, timeout: timeout, checkpoint: checkpoint)
                }
            )
        }

        let target = CGRect(x: 8, y: 8, width: 492, height: 784)
        let accepted = Fake()
        accepted.frames[71] = CGRect(x: 20, y: 20, width: 800, height: 700)
        let acceptedResult = FrameSizingAttempt(io: io(accepted)).apply(
            targets: [.init(windowID: 71, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            gap: 8, generation: 1)
        XCTAssertEqual(acceptedResult.verdict, .accepted)
        XCTAssertEqual(acceptedResult.actualFrames[71], target)
        XCTAssertEqual(acceptedResult.progress.writesCompleted, [71])
        XCTAssertTrue(acceptedResult.progress.readbackComplete)
        XCTAssertTrue(acceptedResult.progress.readbackStable)
        XCTAssertEqual(accepted.operations.filter {
            $0 == "size:71" || $0 == "position:71"
                || $0 == "position-read:71" || $0 == "size-read:71"
        }, ["size:71", "position:71", "size:71",
            "position-read:71", "size-read:71", "position-read:71", "size-read:71"])

        let mismatched = Fake()
        let refused = CGRect(x: 8, y: 8, width: 400, height: 784)
        mismatched.frames[72] = refused
        mismatched.reads[72] = Array(repeating: (.success, refused), count: 12)
        mismatched.sizeReads[72] = Array(repeating: (.success, refused.size), count: 12)
        XCTAssertEqual(FrameSizingAttempt(io: io(mismatched)).apply(
            targets: [.init(windowID: 72, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            gap: 8, generation: 1).verdict, .rejected(.geometryMismatch(72)))

        let failed = Fake()
        failed.frames[73] = target
        failed.writeErrors = [.cannotComplete]
        XCTAssertEqual(FrameSizingAttempt(io: io(failed)).apply(
            targets: [.init(windowID: 73, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            gap: 8, generation: 1).verdict, .rejected(.writeFailed(73, .cannotComplete)))
    }

    func testInterruptionDuringBeginCleansUpWithoutGeometryWrites() {
        let fake = Fake()
        let id: CGWindowID = 43
        fake.frames[id] = CGRect(x: 0, y: 0, width: 500, height: 500)
        let base = fake.io()
        let token = AXFrameWriteBatch.Token.noop(windowID: id)
        let io = FrameSizingIO(
            setMessagingTimeout: base.setMessagingTimeout,
            writeSize: base.writeSize,
            writePosition: base.writePosition,
            readPosition: base.readPosition,
            readSize: base.readSize,
            now: base.now,
            sleep: base.sleep,
            currentGeneration: base.currentGeneration,
            beginFrameWrite: { _, _, _ in .interruptedAfterBegin(token, .superseded) },
            endFrameWrite: { [unowned fake] _, _, _ in
                fake.operations.append("end")
                return .restored
            }
        )

        let result = FrameSizingAttempt(io: io).apply(
            targets: [.init(windowID: id, frame: CGRect(x: 0, y: 0, width: 300, height: 300))],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.superseded))
        XCTAssertEqual(fake.operations, ["end"])
    }

    func testDiagonalWindowsCannotErodeBothAxisGaps() {
        let fake = Fake()
        // a 30 pt gap less the 20 pt cell allowance leaves a 10 pt floor on
        // each axis, and both axes fall under it
        let targetA = CGRect(x: 0, y: 0, width: 485, height: 385)
        let targetB = CGRect(x: 515, y: 415, width: 485, height: 385)
        let actualA = CGRect(x: 0, y: 0, width: 505, height: 405)
        let actualB = CGRect(x: 514, y: 414, width: 485, height: 385)
        fake.frames = [37: targetA, 38: targetB]
        fake.reads[37] = [(.success, actualA), (.success, actualA)]
        fake.reads[38] = [(.success, actualB), (.success, actualB)]
        fake.sizeReads[37] = [(.success, actualA.size), (.success, actualA.size)]
        fake.sizeReads[38] = [(.success, actualB.size), (.success, actualB.size)]
        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: 37, frame: targetA), .init(windowID: 38, frame: targetB)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 30, generation: 1)
        XCTAssertEqual(result.verdict, .rejected(.gapViolation(37, 38)))
    }

    func testDefaultStabilityDoesNotAcceptContinuousSubpointMotion() {
        let fake = Fake()
        let target = CGRect(x: 0, y: 0, width: 300, height: 400)
        fake.frames[50] = target
        let samples = (0..<12).map { CGRect(x: CGFloat($0) * 0.5, y: 0, width: 300, height: 400) }
        fake.reads[50] = samples.map { (.success, Optional($0)) }
        fake.sizeReads[50] = samples.map { (.success, Optional($0.size)) }
        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: 50, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(result.verdict, .unknown(.attemptsExhausted))
    }

    func testSlowGeometryWriteAndReadConsumeDeadline() {
        let target = CGRect(x: 0, y: 0, width: 300, height: 400)
        let writeFake = Fake()
        writeFake.frames[51] = target
        writeFake.writeAdvances = [0.2]
        var config = FrameSizingConfiguration()
        config.deadline = 0.1
        let writeResult = FrameSizingAttempt(io: writeFake.io(), configuration: config).apply(
            targets: [.init(windowID: 51, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(writeResult.verdict, .unknown(.deadlineExceeded))
        XCTAssertFalse(writeFake.operations.contains("position:51"))

        let readFake = Fake()
        readFake.frames[52] = target
        readFake.sizeReadAdvances = [0.2]
        let readResult = FrameSizingAttempt(io: readFake.io(), configuration: config).apply(
            targets: [.init(windowID: 52, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(readResult.verdict, .unknown(.deadlineExceeded))
        XCTAssertEqual(readFake.operations.filter { $0 == "size-read:52" }.count, 1)
    }

    func testUnreadableRestorationRetainsBothReasons() {
        let fake = Fake()
        let original = CGRect(x: 0, y: 0, width: 500, height: 400)
        fake.frames[53] = original
        fake.writeErrors = [.cannotComplete]
        fake.reads[53] = [(.cannotComplete, nil)]
        let outcome = FrameSizingTransaction(attempt: FrameSizingAttempt(io: fake.io())).apply(
            targets: [.init(windowID: 53, frame: CGRect(x: 0, y: 0, width: 300, height: 400))],
            originalFrames: [53: original],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(outcome.outcome, .degraded(candidateReason: .writeFailed(53, .cannotComplete),
                                          restorationReason: .readFailed(53, .cannotComplete),
                                          actualFrames: [:]))
    }

    func testCleanupFailurePreservesWindowAndPrimaryReason() {
        func makeIO(_ fake: Fake, endError: AXError,
                    write: @escaping (CGWindowID, CGSize, TimeInterval) -> AXError) -> FrameSizingIO {
            let base = fake.io()
            return FrameSizingIO(
                setMessagingTimeout: base.setMessagingTimeout, writeSize: write,
                writePosition: base.writePosition, readPosition: base.readPosition,
                readSize: base.readSize, now: base.now, sleep: base.sleep,
                currentGeneration: base.currentGeneration,
                beginFrameWrite: { id, _, _ in .ready(.noop(windowID: id)) },
                endFrameWrite: { _, _, _ in .failed(endError) })
        }
        let target = CGRect(x: 0, y: 0, width: 300, height: 400)

        let successFake = Fake()
        successFake.frames[54] = target
        let successBase = successFake.io()
        let success = FrameSizingAttempt(io: makeIO(successFake, endError: .cannotComplete,
                                                     write: successBase.writeSize)).apply(
            targets: [.init(windowID: 54, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(success.verdict,
                       .unknown(.cleanupFailed(54, primary: nil, error: .cannotComplete)))

        let failureFake = Fake()
        failureFake.frames[55] = target
        let failureBase = failureFake.io()
        var failed = false
        let failure = FrameSizingAttempt(io: makeIO(failureFake, endError: .cannotComplete) { id, size, timeout in
            if !failed { failed = true; return .illegalArgument }
            return failureBase.writeSize(id, size, timeout)
        }).apply(targets: [.init(windowID: 55, frame: target)],
                 usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(failure.verdict,
                       .unknown(.cleanupFailed(55, primary: .writeFailed(55, .illegalArgument),
                                               error: .cannotComplete)))

        let supersededFake = Fake()
        supersededFake.frames[56] = target
        let supersededBase = supersededFake.io()
        let superseded = FrameSizingAttempt(io: makeIO(supersededFake, endError: .cannotComplete) { id, size, timeout in
            let result = supersededBase.writeSize(id, size, timeout)
            supersededFake.generation = 2
            return result
        }).apply(targets: [.init(windowID: 56, frame: target)],
                 usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(superseded.verdict,
                       .unknown(.cleanupFailed(56, primary: .superseded, error: .cannotComplete)))
    }

    func testCleanupWrappedSupersessionNeverRollsBack() {
        let fake = Fake()
        let id: CGWindowID = 57
        let original = CGRect(x: 0, y: 0, width: 500, height: 400)
        fake.frames[id] = original
        let base = fake.io()
        let io = FrameSizingIO(
            setMessagingTimeout: base.setMessagingTimeout,
            writeSize: { windowID, size, timeout in
                let result = base.writeSize(windowID, size, timeout)
                fake.generation = 2
                return result
            },
            writePosition: base.writePosition, readPosition: base.readPosition,
            readSize: base.readSize, now: base.now, sleep: base.sleep,
            currentGeneration: base.currentGeneration,
            beginFrameWrite: { windowID, _, _ in .ready(.noop(windowID: windowID)) },
            endFrameWrite: { _, _, _ in .failed(.cannotComplete) }
        )
        let outcome = FrameSizingTransaction(attempt: FrameSizingAttempt(io: io)).apply(
            targets: [.init(windowID: id, frame: CGRect(x: 0, y: 0, width: 300, height: 400))],
            originalFrames: [id: original],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(outcome.outcome, .degraded(
            candidateReason: .cleanupFailed(id, primary: .superseded, error: .cannotComplete),
            restorationReason: nil, actualFrames: [:]))
        XCTAssertEqual(fake.operations.filter { $0 == "size:57" }.count, 1)
        XCTAssertFalse(fake.operations.contains("position:57"))
    }

    func testSupersessionDuringRestorationStopsRemainingWrites() {
        let fake = Fake()
        let first: CGWindowID = 58
        let second: CGWindowID = 59
        let originalA = CGRect(x: 0, y: 0, width: 496, height: 400)
        let originalB = CGRect(x: 504, y: 0, width: 496, height: 400)
        // targets well off the originals, or the layout stands and nothing
        // is written at all
        let targetA = CGRect(x: 0, y: 0, width: 400, height: 400)
        let targetB = CGRect(x: 504, y: 0, width: 400, height: 400)
        fake.frames = [first: originalA, second: originalB]
        let base = fake.io()
        var sizeCalls = 0
        let io = FrameSizingIO(
            setMessagingTimeout: base.setMessagingTimeout,
            writeSize: { id, size, timeout in
                sizeCalls += 1
                if sizeCalls == 1 { return .cannotComplete }
                let result = base.writeSize(id, size, timeout)
                fake.generation = 2
                return result
            },
            writePosition: base.writePosition, readPosition: base.readPosition,
            readSize: base.readSize, now: base.now, sleep: base.sleep,
            currentGeneration: base.currentGeneration
        )
        let transaction = FrameSizingTransaction(attempt: FrameSizingAttempt(io: io))
        let outcome = transaction.apply(
            targets: [.init(windowID: first, frame: targetA), .init(windowID: second, frame: targetB)],
            originalFrames: [first: originalA, second: originalB],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(outcome.outcome, .degraded(candidateReason: .writeFailed(first, .cannotComplete),
                                          restorationReason: .superseded, actualFrames: [:]))
        XCTAssertEqual(sizeCalls, 2)
        XCTAssertFalse(fake.operations.contains("position:58"))
        XCTAssertFalse(fake.operations.contains("size:59"))
    }

    func testNeverSettledRestorationIsDegraded() {
        let fake = Fake()
        let id: CGWindowID = 60
        let original = CGRect(x: 0, y: 0, width: 500, height: 400)
        fake.frames[id] = original
        fake.writeErrors = [.cannotComplete]
        let unsettled = (0..<12).map { CGRect(x: CGFloat($0 * 3), y: 0, width: 500, height: 400) }
        fake.reads[id] = unsettled.map { (.success, Optional($0)) }
        fake.sizeReads[id] = unsettled.map { (.success, Optional($0.size)) }
        let outcome = FrameSizingTransaction(attempt: FrameSizingAttempt(io: fake.io())).apply(
            targets: [.init(windowID: id, frame: CGRect(x: 0, y: 0, width: 300, height: 400))],
            originalFrames: [id: original],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)
        XCTAssertEqual(outcome.outcome, .degraded(candidateReason: .writeFailed(id, .cannotComplete),
                                          restorationReason: .attemptsExhausted,
                                          actualFrames: [id: unsettled.last!]))
    }

    // MARK: - phase, progress and the half-point floor

    func testHalfPointTargetIsAcceptedBeforeTheMismatchFloor() {
        let fake = Fake()
        let id: CGWindowID = 60
        // a dwindle split lands on the half point; the app answers on the
        // integer, which the tolerant matcher takes
        let target = CGRect(x: 8, y: 41, width: 744, height: 416.5)
        let integer = CGRect(x: 8, y: 41, width: 744, height: 416)
        fake.frames[id] = integer
        fake.callAdvance = 0.001
        fake.reads[id] = Array(repeating: (.success, integer), count: 4)
        fake.sizeReads[id] = Array(repeating: (.success, integer.size), count: 4)
        let config = FrameSizingConfiguration()

        let result = FrameSizingAttempt(io: fake.io(), configuration: config).apply(
            targets: [.init(windowID: id, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 900), gap: 8, generation: 1)

        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertEqual(result.actualFrames[id], integer)
        XCTAssertLessThan(fake.time, config.minimumMismatchSettle)
        XCTAssertEqual(fake.operations.filter { $0 == "position-read:60" }.count, 2)
    }

    func testAttemptCarriesPhaseGenerationAndTargets() {
        let fake = Fake()
        fake.generation = 4
        let target = CGRect(x: 0, y: 0, width: 300, height: 300)
        fake.frames[61] = target
        fake.frames[62] = target.offsetBy(dx: 400, dy: 0)

        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: 61, frame: target),
                      .init(windowID: 62, frame: target.offsetBy(dx: 400, dy: 0))],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8,
            generation: 4, phase: .adjusted)

        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertEqual(result.progress.phase, .adjusted)
        XCTAssertEqual(result.progress.generation, 4)
        XCTAssertEqual(result.progress.targetIDs, [61, 62])
        XCTAssertEqual(result.progress.possiblyWritten, [61, 62])
        XCTAssertEqual(result.progress.writesCompleted, [61, 62])
        XCTAssertTrue(result.progress.readbackComplete)
        XCTAssertTrue(result.progress.readbackStable)
    }

    func testCaptureReportsItsOwnPhaseAndWritesNothing() {
        let fake = Fake()
        fake.frames[63] = CGRect(x: 0, y: 0, width: 300, height: 300)

        let result = FrameSizingAttempt(io: fake.io()).captureFrames(windowIDs: [63], generation: 1)

        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertEqual(result.progress.phase, .capture)
        XCTAssertEqual(result.progress.targetIDs, [63])
        XCTAssertTrue(result.progress.possiblyWritten.isEmpty)
        XCTAssertTrue(result.progress.writesCompleted.isEmpty)
        XCTAssertTrue(result.progress.readbackComplete)
    }

    func testRestorationReportsTheRestorationPhase() {
        let fake = Fake()
        let id: CGWindowID = 64
        let original = CGRect(x: 40, y: 40, width: 500, height: 500)
        fake.frames[id] = original

        let restored = FrameSizingTransaction(attempt: FrameSizingAttempt(io: fake.io()))
            .restore(originalFrames: [id: original],
                     usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                     gap: 8, generation: 1)

        XCTAssertEqual(restored.verdict, .accepted)
        XCTAssertEqual(restored.progress.phase, .restoration)
        XCTAssertEqual(restored.progress.writesCompleted, [id])
    }

    func testInterruptedWriteMarksPossibleMutationWithoutCompletion() {
        for failingWrite in 0..<3 {
            let fake = Fake()
            let id = CGWindowID(70 + failingWrite)
            fake.frames[id] = CGRect(x: 0, y: 0, width: 500, height: 500)
            fake.writeErrors = (0...failingWrite).map {
                $0 == failingWrite ? .cannotComplete : .success
            }

            let result = FrameSizingAttempt(io: fake.io()).apply(
                targets: [.init(windowID: id, frame: CGRect(x: 0, y: 0, width: 300, height: 300))],
                usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)

            XCTAssertEqual(result.verdict, .rejected(.writeFailed(id, .cannotComplete)),
                           "write index \(failingWrite)")
            XCTAssertEqual(result.progress.possiblyWritten, [id],
                           "write index \(failingWrite) lost the possible mutation")
            XCTAssertTrue(result.progress.writesCompleted.isEmpty,
                          "write index \(failingWrite) claimed a completed setter")
            XCTAssertFalse(result.progress.readbackComplete, "write index \(failingWrite)")
        }
    }

    func testFailureOnTheFirstTargetLeavesTheSecondUnwritten() {
        let fake = Fake()
        fake.frames[80] = CGRect(x: 0, y: 0, width: 500, height: 500)
        fake.frames[81] = CGRect(x: 600, y: 0, width: 300, height: 500)
        fake.writeErrors = [.cannotComplete]

        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: 80, frame: CGRect(x: 0, y: 0, width: 300, height: 300)),
                      .init(windowID: 81, frame: CGRect(x: 400, y: 0, width: 300, height: 300))],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)

        XCTAssertEqual(result.verdict, .rejected(.writeFailed(80, .cannotComplete)))
        XCTAssertEqual(result.progress.possiblyWritten, [80])
        XCTAssertEqual(result.progress.targetIDs, [80, 81])
        XCTAssertTrue(result.progress.writesCompleted.isEmpty)
    }

    func testCleanupFailureKeepsTheCompletedSetterProgress() {
        let fake = Fake()
        let id: CGWindowID = 82
        let target = CGRect(x: 0, y: 0, width: 300, height: 300)
        fake.frames[id] = target
        let base = fake.io()
        let io = FrameSizingIO(
            setMessagingTimeout: base.setMessagingTimeout,
            writeSize: base.writeSize,
            writePosition: base.writePosition,
            readPosition: base.readPosition,
            readSize: base.readSize,
            now: base.now,
            sleep: base.sleep,
            currentGeneration: base.currentGeneration,
            beginFrameWrite: { _, _, _ in .ready(.noop(windowID: id)) },
            endFrameWrite: { _, _, _ in .failed(.cannotComplete) }
        )

        let result = FrameSizingAttempt(io: io).apply(
            targets: [.init(windowID: id, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)

        XCTAssertEqual(result.verdict,
                       .unknown(.cleanupFailed(id, primary: nil, error: .cannotComplete)))
        XCTAssertEqual(result.progress.possiblyWritten, [id])
        XCTAssertEqual(result.progress.writesCompleted, [id])
    }

    func testPartialReadbackIsReportedAsIncompleteWithBothTargetsWritten() {
        let fake = Fake()
        fake.frames[90] = CGRect(x: 0, y: 0, width: 300, height: 300)
        fake.frames[91] = CGRect(x: 400, y: 0, width: 300, height: 300)
        fake.reads[91] = [(.cannotComplete, nil)]

        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: 90, frame: CGRect(x: 0, y: 0, width: 300, height: 300)),
                      .init(windowID: 91, frame: CGRect(x: 400, y: 0, width: 300, height: 300))],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)

        XCTAssertEqual(result.verdict, .unknown(.readFailed(91, .cannotComplete)))
        XCTAssertEqual(result.progress.possiblyWritten, [90, 91])
        XCTAssertEqual(result.progress.writesCompleted, [90, 91])
        XCTAssertNotNil(result.actualFrames[90])
        XCTAssertNil(result.actualFrames[91])
        XCTAssertFalse(result.progress.readbackComplete)
    }

    func testProgressSurvivesAGeometryRejection() {
        let fake = Fake()
        let target = CGRect(x: 0, y: 0, width: 300, height: 800)
        let refused = CGRect(x: 0, y: 0, width: 400, height: 800)
        fake.frames[92] = refused
        fake.reads[92] = Array(repeating: (.success, refused), count: 12)
        fake.sizeReads[92] = Array(repeating: (.success, refused.size), count: 12)

        let result = FrameSizingAttempt(io: fake.io()).apply(
            targets: [.init(windowID: 92, frame: target)],
            usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 8, generation: 1)

        XCTAssertEqual(result.verdict, .rejected(.geometryMismatch(92)))
        XCTAssertEqual(result.progress.phase, .candidate)
        XCTAssertEqual(result.progress.targetIDs, [92])
        XCTAssertEqual(result.progress.possiblyWritten, [92])
        XCTAssertEqual(result.progress.writesCompleted, [92])
        XCTAssertTrue(result.progress.readbackComplete)
        XCTAssertTrue(result.progress.readbackStable)
    }

    // the one predicate behind every publication decision — the tiling trees
    // and the drag commit both ask it, so they cannot drift apart
    func testCandidateVerifiedNeedsEveryTargetWrittenAndACompleteStableReadback() {
        var report = FrameSizingProgressReport()
        XCTAssertTrue(report.candidateVerified,
                      "a layout with no targets wrote nothing and has nothing to verify")

        report.candidate.targetIDs = [1, 2]
        report.candidate.writesCompleted = [1]
        report.candidate.readbackComplete = true
        report.candidate.readbackStable = true
        XCTAssertFalse(report.candidateVerified, "one target never finished its setters")

        report.candidate.writesCompleted = [1, 2]
        XCTAssertTrue(report.candidateVerified)

        report.candidate.readbackComplete = false
        XCTAssertFalse(report.candidateVerified)
        report.candidate.readbackComplete = true
        report.candidate.readbackStable = false
        XCTAssertFalse(report.candidateVerified)
    }
}

/// Dia reports the size it was last asked for, not the size its window has,
/// and refuses a write equal to that with -25205 without resizing. Seen live
/// 2026-10-30: AX 1496x839 while the window server had 688x446.
final class RefusedSizeResendTests: XCTestCase {

    /// A window whose AX size is the last size requested. A write equal to it
    /// is refused; any other lands.
    private final class StaleSizeWindow {
        var reported: CGSize
        var real: CGSize
        var writes: [CGSize] = []
        init(reported: CGSize, real: CGSize) { self.reported = reported; self.real = real }
        func write(_ size: CGSize) -> AXError {
            writes.append(size)
            guard size != reported else { return .attributeUnsupported }
            reported = size
            real = size
            return .success
        }
    }

    func testARefusedSizeIsSentAgainAfterAOnePointNudge() {
        let window = StaleSizeWindow(reported: CGSize(width: 1496, height: 839),
                                     real: CGSize(width: 688, height: 446))
        let target = CGSize(width: 1496, height: 839)

        let first = window.write(target)
        let error = HyprWindow.resendRefusedSize(target, write: window.write)

        XCTAssertEqual(first, .attributeUnsupported)
        XCTAssertEqual(error, .success)
        XCTAssertEqual(window.real, target, "the window took the size it refused")
        XCTAssertEqual(window.writes.dropFirst(), [CGSize(width: 1495, height: 839), target])
    }

    func testAResendThatIsRefusedAgainReportsTheRefusal() {
        let error = HyprWindow.resendRefusedSize(CGSize(width: 744, height: 839)) { _ in .attributeUnsupported }
        XCTAssertEqual(error, .attributeUnsupported)
    }

    func testANudgeThatFailsIsNotFollowedByTheTarget() {
        var writes: [CGSize] = []
        let error = HyprWindow.resendRefusedSize(CGSize(width: 744, height: 839)) { size in
            writes.append(size)
            return .cannotComplete
        }
        XCTAssertEqual(error, .cannotComplete)
        XCTAssertEqual(writes, [CGSize(width: 743, height: 839)])
    }
}

private extension FrameSizingIO {
    func withServer(_ frame: @escaping (CGWindowID) -> CGRect?) -> FrameSizingIO {
        var io = self
        io.serverFrame = frame
        return io
    }
}

private final class SuspectTestScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 1512, height: 982) }
    override var visibleFrame: NSRect { NSRect(x: 0, y: 0, width: 1512, height: 851) }
}
