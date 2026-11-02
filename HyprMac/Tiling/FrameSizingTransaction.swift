import Cocoa

/// Two windows that sit on top of each other. Only the restoration phase
/// produces these, as a diagnostic: restored originals are never published
/// as a tiled layout, so an overlap between them is a fact about where the
/// windows were, not a verdict.
struct FrameSizingOverlap: Equatable {
    let first: CGWindowID
    let second: CGWindowID
}

/// Which pass produced a sizing result. `capture` only reads; `candidate`
/// is the first try at a layout, `adjusted` the retry after min-size ratio
/// adjustment, `restoration` the rollback to captured original frames.
enum FrameSizingPhase: String, Equatable {
    case capture, candidate, adjusted, restoration
}

struct FrameSizingAttempt {
    struct Target: Equatable {
        let windowID: CGWindowID
        let frame: CGRect
    }

    enum Verdict: Equatable {
        case accepted
        case rejected(FrameSizingFailure)
        case unknown(FrameSizingFailure)

        var failure: FrameSizingFailure? {
            switch self {
            case .accepted: nil
            case .rejected(let reason), .unknown(let reason): reason
            }
        }
    }

    /// What an attempt is known to have done, carried on every result so a
    /// caller can tell "nothing went out" from "three setters went out and
    /// we never read them back".
    ///
    /// `possiblyWritten` records that a setter was issued — it is evidence
    /// of a possible mutation, never proof the app applied the frame.
    /// `writesCompleted` means every frame setter returned success for
    /// that window; the cleanup that follows carries its own error.
    struct Progress: Equatable {
        var phase: FrameSizingPhase = .candidate
        var generation: UInt64 = 0
        var targetIDs: [CGWindowID] = []
        var possiblyWritten: Set<CGWindowID> = []
        var writesCompleted: Set<CGWindowID> = []
        /// A setter, a frame read or the enhanced-UI read before a window's
        /// writes returned `cannotComplete` after consuming nearly all of its
        /// configured messaging timeout.
        var timeoutShapedCannotComplete = false
        /// every target produced a readable frame
        var readbackComplete = false
        /// every target reached the configured stable sample count
        var readbackStable = false
        /// the layout already stood: every target was where its window was
        /// at the capture, so nothing was written and the capture was the
        /// readback. Counts as written for publication.
        var verifiedInPlace = false
    }

    /// Phase durations for the attempt trace. Not part of the typed
    /// result — nothing decides on these, they only get logged.
    struct Timings {
        var write: TimeInterval = 0
        var read: TimeInterval = 0
        var settle: TimeInterval = 0
        /// per window, every setter with its raw AX code and duration
        var steps: [String] = []
        /// per window, its frame before the writes and after each setter,
        /// when the IO carries `traceFrame`
        var stepFrames: [CGWindowID: String] = [:]
        /// readback samples taken, and the slowest single-window read
        var samples = 0
        var slowestRead: TimeInterval = 0
    }

    struct Result: Equatable {
        let verdict: Verdict
        let actualFrames: [CGWindowID: CGRect]
        var progress = Progress()
        /// restored originals that overlap each other. diagnostic only —
        /// see `FrameSizingConfiguration.correspondenceOnly`.
        var overlaps: [FrameSizingOverlap] = []
    }

    let io: FrameSizingIO
    var configuration = FrameSizingConfiguration()

    /// The layout as it already stands. Every target is where its window
    /// is, within a point, and the frames pass the aggregate checks as they
    /// are, so there is nothing to write: the capture that produced
    /// `originalFrames` is the first readback, and the caller takes a
    /// second one before it accepts. Nil when any window is off its target,
    /// or the frames do not pass together, and the ordinary pass runs.
    ///
    /// Most retiles are this. A workspace switch retiles the other screen,
    /// a move retiles its source twice, a poll re-applies a tree nothing
    /// changed; every one of them sent three setters per window and then
    /// waited for a settle and a stable readback of frames that never moved.
    /// `FrameReadbackPoller` asks before a candidate pass whose caller
    /// captured the originals it hands over. A tiled drop never asks: it
    /// always changes the layout, and its originals are the press-time
    /// capture, not where the windows stand at the release.
    func alreadyApplied(targets: [Target], originalFrames: [CGWindowID: CGRect],
                        usableFrame: CGRect, gap: CGFloat, generation: UInt64) -> Result? {
        guard !targets.isEmpty, io.currentGeneration() == generation else { return nil }
        var actual: [CGWindowID: CGRect] = [:]
        for target in targets {
            guard actual[target.windowID] == nil, valid(target.frame),
                  let original = originalFrames[target.windowID], valid(original),
                  standsOn(original, target.frame) else { return nil }
            actual[target.windowID] = original
        }
        let validated = validateFrames(targets: targets, actualFrames: actual,
                                       usableFrame: usableFrame, gap: gap)
        guard case .accepted = validated.verdict else { return nil }
        var progress = Progress(phase: .candidate, generation: generation,
                                targetIDs: targets.map(\.windowID))
        progress.readbackComplete = true
        progress.readbackStable = true
        progress.verifiedInPlace = true
        return Result(verdict: .accepted, actualFrames: actual, progress: progress,
                      overlaps: validated.overlaps)
    }

    func captureFrames(windowIDs: [CGWindowID], generation: UInt64) -> Result {
        let started = io.now()
        var frames: [CGWindowID: CGRect] = [:]
        var progress = Progress(phase: .capture, generation: generation,
                                targetIDs: windowIDs.sorted())
        // a capture never writes, so only the readback fields and the
        // timeout shape move
        func out(_ result: Result) -> Result {
            var stamped = progress
            stamped.readbackComplete = windowIDs.allSatisfy { result.actualFrames[$0] != nil }
            return Result(verdict: result.verdict, actualFrames: result.actualFrames,
                          progress: stamped)
        }
        guard io.currentGeneration() == generation else {
            return out(Result(verdict: .unknown(.superseded), actualFrames: frames))
        }
        var seen = Set<CGWindowID>()
        for windowID in windowIDs where !seen.insert(windowID).inserted {
            return out(Result(verdict: .unknown(.duplicateWindowID(windowID)), actualFrames: frames))
        }
        for windowID in windowIDs.sorted() {
            guard io.currentGeneration() == generation else {
                return out(Result(verdict: .unknown(.superseded), actualFrames: frames))
            }
            guard io.now() - started < configuration.deadline else {
                return out(Result(verdict: .unknown(.deadlineExceeded), actualFrames: frames))
            }
            let timeoutError = io.setMessagingTimeout(windowID, configuration.perCallTimeout)
            guard io.currentGeneration() == generation else {
                return out(Result(verdict: .unknown(.superseded), actualFrames: frames))
            }
            guard io.now() - started < configuration.deadline else {
                return out(Result(verdict: .unknown(.deadlineExceeded), actualFrames: frames))
            }
            guard timeoutError == .success else {
                let failure: FrameSizingFailure = timeoutError == .invalidUIElement
                    ? .windowUnavailable(windowID) : .readFailed(windowID, timeoutError)
                return out(Result(verdict: .unknown(failure), actualFrames: frames))
            }
            let positionStarted = io.now()
            let (positionError, position) = io.readPosition(windowID, configuration.perCallTimeout)
            noteTimeoutShape(positionError, started: positionStarted, progress: &progress)
            guard io.currentGeneration() == generation else {
                return out(Result(verdict: .unknown(.superseded), actualFrames: frames))
            }
            guard io.now() - started < configuration.deadline else {
                return out(Result(verdict: .unknown(.deadlineExceeded), actualFrames: frames))
            }
            guard positionError == .success, let position else {
                let failure: FrameSizingFailure = positionError == .invalidUIElement
                    ? .windowUnavailable(windowID) : .readFailed(windowID, positionError)
                return out(Result(verdict: .unknown(failure), actualFrames: frames))
            }
            let sizeTimeoutError = io.setMessagingTimeout(windowID, configuration.perCallTimeout)
            guard io.currentGeneration() == generation else {
                return out(Result(verdict: .unknown(.superseded), actualFrames: frames))
            }
            guard io.now() - started < configuration.deadline else {
                return out(Result(verdict: .unknown(.deadlineExceeded), actualFrames: frames))
            }
            guard sizeTimeoutError == .success else {
                let failure: FrameSizingFailure = sizeTimeoutError == .invalidUIElement
                    ? .windowUnavailable(windowID) : .readFailed(windowID, sizeTimeoutError)
                return out(Result(verdict: .unknown(failure), actualFrames: frames))
            }
            let sizeStarted = io.now()
            let (sizeError, size) = io.readSize(windowID, configuration.perCallTimeout)
            noteTimeoutShape(sizeError, started: sizeStarted, progress: &progress)
            guard io.currentGeneration() == generation else {
                return out(Result(verdict: .unknown(.superseded), actualFrames: frames))
            }
            guard io.now() - started < configuration.deadline else {
                return out(Result(verdict: .unknown(.deadlineExceeded), actualFrames: frames))
            }
            guard sizeError == .success, let size else {
                let failure: FrameSizingFailure = sizeError == .invalidUIElement
                    ? .windowUnavailable(windowID) : .readFailed(windowID, sizeError)
                return out(Result(verdict: .unknown(failure), actualFrames: frames))
            }
            let frame = CGRect(origin: position, size: size)
            guard valid(frame) else {
                return out(Result(verdict: .unknown(.invalidFrame(windowID)), actualFrames: frames))
            }
            frames[windowID] = frame
        }
        return out(Result(verdict: .accepted, actualFrames: frames))
    }

    /// Traced wrapper around the attempt. `.debug` lines are built inside
    /// `hyprLog`'s autoclosure, so they are formatted only when the file log or
    /// the trace tier is on. Timeouts and refusals log at `.notice`.
    func apply(targets: [Target], usableFrame: CGRect, gap: CGFloat,
               generation: UInt64, phase: FrameSizingPhase = .candidate) -> Result {
        let started = io.now()
        let (result, timings) = perform(targets: targets, usableFrame: usableFrame, gap: gap,
                                        generation: generation, phase: phase)
        let elapsed = io.now() - started
        let progress = result.progress
        hyprLog(.debug, .tiling, "frame attempt: phase=\(phase.rawValue) gen=\(generation) "
                + "wids=\(targets.map(\.windowID)) "
                + "verdict=\(traced(result.verdict)) "
                + "written=\(Self.ids(progress.possiblyWritten)) "
                + "complete=\(Self.ids(progress.writesCompleted)) "
                + "readback=\(progress.readbackComplete ? "complete" : "partial")/"
                + "\(progress.readbackStable ? "stable" : "unstable") "
                + "write=\(Self.ms(timings.write)) read=\(Self.ms(timings.read)) "
                + "settle=\(Self.ms(timings.settle)) elapsed=\(Self.ms(elapsed)) "
                + "headroom=\(Self.ms(configuration.deadline - elapsed))")
        // a timeout is the one failure whose cause the notice lines could
        // not show: which call ate the budget. say it where Console keeps it
        switch result.verdict {
        case let .rejected(failure) where failure.isTimeout,
             let .unknown(failure) where failure.isTimeout:
            hyprLog(.notice, .tiling, "frame attempt timed out: phase=\(phase.rawValue) "
                    + "gen=\(generation) wids=\(targets.map(\.windowID)) reason=\(failure) "
                    + "written=\(Self.ids(progress.possiblyWritten)) "
                    + "complete=\(Self.ids(progress.writesCompleted)) "
                    + "read=\(result.actualFrames.keys.sorted()) "
                    + "write=\(Self.ms(timings.write)) readLoop=\(Self.ms(timings.read)) "
                    + "settle=\(Self.ms(timings.settle)) elapsed=\(Self.ms(elapsed)) "
                    + "deadline=\(Self.ms(configuration.deadline)) samples=\(timings.samples) "
                    + "slowestRead=\(Self.ms(timings.slowestRead)) "
                    + "steps=[\(timings.steps.joined(separator: " "))]")
        case let .rejected(failure), let .unknown(failure):
            // issue #43: a window that read back off its target. say where it
            // stood before its writes and after each setter
            for id in failure.namedWindowIDs.sorted() {
                guard let frames = timings.stepFrames[id] else { continue }
                let target = targets.first { $0.windowID == id }.map { traced($0.frame) } ?? "none"
                let read = result.actualFrames[id].map { traced($0) } ?? "unread"
                hyprLog(.notice, .tiling, "frame write trace: wid=\(id) phase=\(phase.rawValue) "
                        + "gen=\(generation) reason=\(failure.trace) target=\(target) "
                        + "frames=[\(frames)] read=\(read) "
                        + "positionFirst=\(configuration.positionSettleWindowIDs.contains(id))")
            }
        default:
            break
        }
        return result
    }

    private func perform(targets: [Target], usableFrame: CGRect, gap: CGFloat,
                         generation: UInt64,
                         phase: FrameSizingPhase) -> (Result, Timings) {
        var progress = Progress(phase: phase, generation: generation,
                                targetIDs: targets.map(\.windowID))
        var stableCounts: [CGWindowID: Int] = [:]
        var timings = Timings()

        // every exit carries the progress and the phase durations as they
        // stand, so a failure is as readable as a success
        func out(_ result: Result) -> (Result, Timings) {
            var stamped = progress
            stamped.readbackComplete = targets.allSatisfy { result.actualFrames[$0.windowID] != nil }
            stamped.readbackStable = targets.allSatisfy {
                stableCounts[$0.windowID, default: 0] >= configuration.requiredStableSamples
            }
            return (Result(verdict: result.verdict, actualFrames: result.actualFrames,
                           progress: stamped, overlaps: result.overlaps), timings)
        }

        guard io.currentGeneration() == generation else {
            return out(Result(verdict: .unknown(.superseded), actualFrames: [:]))
        }
        guard !targets.isEmpty else {
            return out(Result(verdict: .accepted, actualFrames: [:]))
        }
        var seen = Set<CGWindowID>()
        for target in targets {
            guard seen.insert(target.windowID).inserted else {
                return out(Result(verdict: .rejected(.duplicateWindowID(target.windowID)), actualFrames: [:]))
            }
            let frame = target.frame
            guard frame.origin.x.isFinite, frame.origin.y.isFinite,
                  frame.size.width.isFinite, frame.size.height.isFinite,
                  frame.size.width > 0, frame.size.height > 0 else {
                return out(Result(verdict: .rejected(.invalidFrame(target.windowID)), actualFrames: [:]))
            }
        }
        let started = io.now()
        var actualFrames: [CGWindowID: CGRect] = [:]

        func interruption() -> FrameSizingFailure? {
            if io.currentGeneration() != generation { return .superseded }
            if io.now() - started >= configuration.deadline { return .deadlineExceeded }
            return nil
        }

        for target in targets {
            let result = write(target, actualFrames: actualFrames, progress: &progress,
                               timings: &timings, checkpoint: interruption)
            timings.write = io.now() - started
            if let result { return out(result) }
        }
        timings.write = io.now() - started
        let readStarted = io.now()

        var stableAnchors: [CGWindowID: CGRect] = [:]
        for attemptIndex in 0..<configuration.maximumAttempts {
            timings.samples = attemptIndex + 1
            for target in targets {
                let readCallStarted = io.now()
                let failed = read(target, actualFrames: &actualFrames, progress: &progress,
                                  checkpoint: interruption)
                timings.slowestRead = max(timings.slowestRead, io.now() - readCallStarted)
                if let result = failed {
                    timings.read = io.now() - readStarted
                    return out(result)
                }
                guard let frame = actualFrames[target.windowID] else {
                    timings.read = io.now() - readStarted
                    return out(Result(verdict: .unknown(.windowUnavailable(target.windowID)),
                                      actualFrames: actualFrames))
                }
                // only off-target samples are logged, and "off" means not
                // exactly what we asked for. onTarget says whether the
                // verdict's tolerant matcher is happy with that sample —
                // a half-point target read back on the integer is off by
                // 0.5 and on target.
                if frame != target.frame {
                    hyprLog(.debug, .tiling, "frame readback: wid=\(target.windowID) "
                            + "phase=\(phase.rawValue) "
                            + "sample=\(attemptIndex + 1) actual=\(traced(frame)) "
                            + "delta=(\(traced(frame.width - target.frame.width)),"
                            + "\(traced(frame.height - target.frame.height))) "
                            + "dx=\(traced(frame.minX - target.frame.minX)),"
                            + "dy=\(traced(frame.minY - target.frame.minY)) "
                            + "onTarget=\(matches(frame, target.frame)) "
                            + "at=\(Self.ms(io.now() - started))")
                }
                if let anchor = stableAnchors[target.windowID], stable(frame, anchor) {
                    stableCounts[target.windowID, default: 1] += 1
                } else {
                    stableAnchors[target.windowID] = frame
                    stableCounts[target.windowID] = 1
                }
            }
            if targets.allSatisfy({ stableCounts[$0.windowID, default: 0] >= configuration.requiredStableSamples }) {
                let allOnTarget = targets.allSatisfy { target in
                    actualFrames[target.windowID].map { matches($0, target.frame) } ?? false
                }
                if allOnTarget || io.now() - started >= configuration.minimumMismatchSettle {
                    timings.read = io.now() - readStarted
                    return out(validateFrames(targets: targets, actualFrames: actualFrames,
                                              usableFrame: usableFrame, gap: gap))
                }
            }
            if attemptIndex + 1 < configuration.maximumAttempts {
                io.sleep(configuration.pollInterval)
                timings.settle += configuration.pollInterval
                if let failure = interruption() {
                    timings.read = io.now() - readStarted
                    return out(Result(verdict: .unknown(failure), actualFrames: actualFrames))
                }
            }
        }
        timings.read = io.now() - readStarted
        return out(Result(verdict: .unknown(.attemptsExhausted), actualFrames: actualFrames))
    }

    private func prepare(_ windowID: CGWindowID,
                         checkpoint: () -> FrameSizingFailure?) -> FrameSizingFailure? {
        let error = io.setMessagingTimeout(windowID, configuration.perCallTimeout)
        if let failure = checkpoint() { return failure }
        if error == .invalidUIElement { return .windowUnavailable(windowID) }
        return error == .success ? nil : .writeFailed(windowID, error)
    }

    private func prepareRead(_ windowID: CGWindowID,
                             checkpoint: () -> FrameSizingFailure?) -> FrameSizingFailure? {
        guard let failure = prepare(windowID, checkpoint: checkpoint) else { return nil }
        if case let .writeFailed(id, error) = failure { return .readFailed(id, error) }
        return failure
    }

    private func result(for failure: FrameSizingFailure,
                        actualFrames: [CGWindowID: CGRect]) -> Result {
        switch failure {
        case .deadlineExceeded, .superseded, .windowUnavailable:
            return Result(verdict: .unknown(failure), actualFrames: actualFrames)
        default:
            return Result(verdict: .rejected(failure), actualFrames: actualFrames)
        }
    }

    private func write(_ target: Target, actualFrames: [CGWindowID: CGRect],
                       progress: inout Progress, timings: inout Timings,
                       checkpoint: () -> FrameSizingFailure?) -> Result? {
        let phase = progress.phase
        let writeStarted = io.now()
        var steps: [String] = []
        var stepFrames: [String] = []
        // diagnostic: where the window stands now, so a refused attempt can
        // tell a setter the app clamped from one it applied and then undid
        func probe(_ label: String) {
            guard let read = io.traceFrame else { return }
            stepFrames.append("\(label)→" + (read(target.windowID).map { traced($0) } ?? "unread"))
        }
        // one line per window listing every setter that went out, with its
        // raw AX code and how long it took
        func traceSteps(_ complete: Bool) {
            let listed = steps.isEmpty ? "none" : steps.joined(separator: ",")
            // total also covers the enhanced-ui begin and the timeout
            // setup, so total minus the setters is what those cost
            timings.steps.append("\(target.windowID):\(listed)/total=\(Self.ms(io.now() - writeStarted))")
            if !stepFrames.isEmpty {
                timings.stepFrames[target.windowID] = stepFrames.joined(separator: ",")
            }
            hyprLog(.debug, .tiling, "frame write: wid=\(target.windowID) phase=\(phase.rawValue) "
                    + "steps=\(listed) complete=\(complete)"
                    + (stepFrames.isEmpty ? "" : " frames=\(stepFrames.joined(separator: ","))"))
        }
        hyprLog(.debug, .tiling,
                "frame write: wid=\(target.windowID) phase=\(phase.rawValue) "
                + "target=\(traced(target.frame))")
        if let failure = checkpoint() {
            traceSteps(false)
            return Result(verdict: .unknown(failure), actualFrames: actualFrames)
        }
        let token: AXFrameWriteBatch.Token
        let beginStarted = io.now()
        switch io.beginFrameWrite(target.windowID, configuration.perCallTimeout, checkpoint) {
        case let .ready(value): token = value
        case let .failed(error):
            // the enhanced-UI read that opens a window's writes is an AX call
            // like the setters. seen live: Messages refused it at 101 ms
            noteTimeoutShape(error, started: beginStarted, progress: &progress)
            traceSteps(false)
            let failure: FrameSizingFailure = error == .invalidUIElement
                ? .windowUnavailable(target.windowID) : .writeFailed(target.windowID, error)
            return result(for: failure, actualFrames: actualFrames)
        case let .failedAfterCleanup(primary, cleanup):
            traceSteps(false)
            return beginCleanupFailure(target.windowID, primary: primary, cleanup: cleanup,
                                       actualFrames: actualFrames)
        case let .interrupted(reason):
            traceSteps(false)
            return Result(verdict: .unknown(reason), actualFrames: actualFrames)
        case let .interruptedAfterBegin(value, reason):
            traceSteps(false)
            return end(value, windowID: target.windowID,
                       preserving: Result(verdict: .unknown(reason), actualFrames: actualFrames),
                       checkpoint: checkpoint)
        }

        probe("before")
        let settlePositionBeforeSizing = configuration.positionSettleWindowIDs.contains(target.windowID)
        let staging = settlePositionBeforeSizing ? configuration.stagingOrigins[target.windowID] : nil
        // where the position-first write sends the window, and where its
        // settle waits for it
        let firstOrigin = staging ?? target.frame.origin
        let writes: [(String, () -> AXError)] = settlePositionBeforeSizing
            ? [
                ("position", { io.writePosition(target.windowID, firstOrigin, configuration.perCallTimeout) }),
                ("size", { io.writeSize(target.windowID, target.frame.size, configuration.perCallTimeout) })
            ] + (staging == nil ? [] : [
                ("position2", { io.writePosition(target.windowID, target.frame.origin, configuration.perCallTimeout) })
            ]) + [
                ("size2", { io.writeSize(target.windowID, target.frame.size, configuration.perCallTimeout) })
            ]
            : [
                ("size", { io.writeSize(target.windowID, target.frame.size, configuration.perCallTimeout) }),
                ("position", { io.writePosition(target.windowID, target.frame.origin, configuration.perCallTimeout) }),
                ("size2", { io.writeSize(target.windowID, target.frame.size, configuration.perCallTimeout) })
            ]
        for (label, operation) in writes {
            if let failure = prepare(target.windowID, checkpoint: checkpoint) {
                traceSteps(false)
                return end(token, windowID: target.windowID,
                           preserving: result(for: failure, actualFrames: actualFrames),
                           checkpoint: checkpoint)
            }
            // mark possible mutation before the setter runs, error or not:
            // an AX write that comes back with a code may still have landed
            progress.possiblyWritten.insert(target.windowID)
            let startedStep = io.now()
            let error = operation()
            noteTimeoutShape(error, started: startedStep, progress: &progress)
            steps.append("\(label):\(error.rawValue)/\(Self.ms(io.now() - startedStep))")
            let primary: Result
            if let failure = checkpoint() {
                primary = Result(verdict: .unknown(failure), actualFrames: actualFrames)
            } else if error != .success {
                primary = Result(verdict: .rejected(.writeFailed(target.windowID, error)),
                                 actualFrames: actualFrames)
            } else {
                if label == "position", settlePositionBeforeSizing {
                    let settleStarted = io.now()
                    var anchor: CGPoint?
                    var last: CGPoint?
                    var samples = 0
                    var stableCount = 0
                    var settled = false
                    for attempt in 0..<configuration.maximumAttempts {
                        if let failure = prepareRead(target.windowID, checkpoint: checkpoint) {
                            traceSteps(false)
                            return end(token, windowID: target.windowID,
                                       preserving: Result(verdict: .unknown(failure),
                                                          actualFrames: actualFrames),
                                       checkpoint: checkpoint)
                        }
                        let readStarted = io.now()
                        let (readError, position) = io.readPosition(target.windowID,
                                                                    configuration.perCallTimeout)
                        noteTimeoutShape(readError, started: readStarted, progress: &progress)
                        if let failure = checkpoint() {
                            traceSteps(false)
                            return end(token, windowID: target.windowID,
                                       preserving: Result(verdict: .unknown(failure),
                                                          actualFrames: actualFrames),
                                       checkpoint: checkpoint)
                        }
                        guard readError == .success, let position else {
                            let failure: FrameSizingFailure = readError == .invalidUIElement
                                ? .windowUnavailable(target.windowID)
                                : .readFailed(target.windowID, readError)
                            traceSteps(false)
                            return end(token, windowID: target.windowID,
                                       preserving: Result(verdict: .unknown(failure),
                                                          actualFrames: actualFrames),
                                       checkpoint: checkpoint)
                        }
                        guard position.x.isFinite, position.y.isFinite else {
                            traceSteps(false)
                            return end(token, windowID: target.windowID,
                                       preserving: Result(verdict: .unknown(.invalidFrame(target.windowID)),
                                                          actualFrames: actualFrames),
                                       checkpoint: checkpoint)
                        }
                        samples += 1
                        last = position
                        let onTarget = abs(position.x - firstOrigin.x) <= configuration.positionTolerance
                            && abs(position.y - firstOrigin.y) <= configuration.positionTolerance
                        if onTarget, let prior = anchor,
                           abs(position.x - prior.x) <= configuration.stableTolerance,
                           abs(position.y - prior.y) <= configuration.stableTolerance {
                            stableCount += 1
                        } else {
                            anchor = position
                            stableCount = onTarget ? 1 : 0
                        }
                        if stableCount >= configuration.requiredStableSamples {
                            settled = true
                            break
                        }
                        // out of settle budget: size it where it landed
                        if io.now() - settleStarted >= configuration.positionSettleBudget { break }
                        if attempt + 1 < configuration.maximumAttempts {
                            io.sleep(configuration.pollInterval)
                        }
                    }
                    let waited = io.now() - settleStarted
                    steps.append("settle:\(settled ? "ok" : "cut")/\(Self.ms(waited))")
                    if !settled {
                        let landed = last.map { "(\(traced($0.x)),\(traced($0.y)))" } ?? "none"
                        hyprLog(.notice, .tiling, "position settle cut short: wid=\(target.windowID) "
                                + "phase=\(phase.rawValue) after=\(Self.ms(waited)) samples=\(samples) "
                                + "last=\(landed) "
                                + "target=(\(traced(firstOrigin.x)),\(traced(firstOrigin.y))) "
                                + "— writing size anyway")
                    }
                }
                probe(label)
                continue
            }
            traceSteps(false)
            return end(token, windowID: target.windowID, preserving: primary,
                       checkpoint: checkpoint)
        }
        // every setter returned success. record that before cleanup —
        // a cleanup error is its own failure and does not unwrite them.
        progress.writesCompleted.insert(target.windowID)
        traceSteps(true)
        let ended = end(token, windowID: target.windowID,
                        preserving: Result(verdict: .accepted, actualFrames: actualFrames),
                        checkpoint: checkpoint)
        return ended.verdict == .accepted ? nil : ended
    }

    private func read(_ target: Target, actualFrames: inout [CGWindowID: CGRect],
                      progress: inout Progress,
                      checkpoint: () -> FrameSizingFailure?) -> Result? {
        if let failure = prepareRead(target.windowID, checkpoint: checkpoint) {
            return Result(verdict: .unknown(failure), actualFrames: actualFrames)
        }
        let positionStarted = io.now()
        let (positionError, position) = io.readPosition(target.windowID, configuration.perCallTimeout)
        noteTimeoutShape(positionError, started: positionStarted, progress: &progress)
        if let failure = checkpoint() {
            return Result(verdict: .unknown(failure), actualFrames: actualFrames)
        }
        guard positionError == .success, let position else {
            let failure: FrameSizingFailure = positionError == .invalidUIElement
                ? .windowUnavailable(target.windowID) : .readFailed(target.windowID, positionError)
            return Result(verdict: .unknown(failure), actualFrames: actualFrames)
        }
        if let failure = prepareRead(target.windowID, checkpoint: checkpoint) {
            return Result(verdict: .unknown(failure), actualFrames: actualFrames)
        }
        let sizeStarted = io.now()
        let (sizeError, size) = io.readSize(target.windowID, configuration.perCallTimeout)
        noteTimeoutShape(sizeError, started: sizeStarted, progress: &progress)
        if let failure = checkpoint() {
            return Result(verdict: .unknown(failure), actualFrames: actualFrames)
        }
        guard sizeError == .success, let size else {
            let failure: FrameSizingFailure = sizeError == .invalidUIElement
                ? .windowUnavailable(target.windowID) : .readFailed(target.windowID, sizeError)
            return Result(verdict: .unknown(failure), actualFrames: actualFrames)
        }
        let frame = CGRect(origin: position, size: size)
        guard valid(frame) else {
            return Result(verdict: .unknown(.invalidFrame(target.windowID)), actualFrames: actualFrames)
        }
        actualFrames[target.windowID] = frame
        return nil
    }

    private func noteTimeoutShape(_ error: AXError, started: TimeInterval,
                                  progress: inout Progress) {
        guard error == .cannotComplete,
              io.now() - started >= configuration.perCallTimeout * 0.9 else { return }
        progress.timeoutShapedCannotComplete = true
    }

    private func end(_ token: AXFrameWriteBatch.Token, windowID: CGWindowID,
                     preserving result: Result,
                     checkpoint: () -> FrameSizingFailure?) -> Result {
        switch io.endFrameWrite(token, configuration.perCallTimeout, checkpoint) {
        case .restored: return result
        case let .failed(error):
            return cleanupFailure(windowID, primary: result, error: error)
        case let .failedTimeoutAndRestore(timeout, restore):
            let nested = cleanupFailure(windowID, primary: result, error: timeout)
            return cleanupFailure(windowID, primary: nested, error: restore)
        }
    }

    private func cleanupFailure(_ windowID: CGWindowID, primary: Result,
                                error: AXError) -> Result {
        return Result(verdict: .unknown(.cleanupFailed(windowID, primary: primary.verdict.failure, error: error)),
                      actualFrames: primary.actualFrames)
    }

    private func beginCleanupFailure(_ windowID: CGWindowID, primary: AXError,
                                     cleanup: AXFrameWriteBatch.EndResult,
                                     actualFrames: [CGWindowID: CGRect]) -> Result {
        let primaryResult = Result(verdict: .unknown(.writeFailed(windowID, primary)),
                                   actualFrames: actualFrames)
        switch cleanup {
        case .restored: return primaryResult
        case let .failed(error):
            return cleanupFailure(windowID, primary: primaryResult, error: error)
        case let .failedTimeoutAndRestore(timeout, restore):
            let nested = cleanupFailure(windowID, primary: primaryResult, error: timeout)
            return cleanupFailure(windowID, primary: nested, error: restore)
        }
    }

    // compact trace formatting. %g so whole pixels stay short and a
    // sub-pixel value still shows its fraction.
    private func traced(_ value: CGFloat) -> String {
        String(format: "%g", Double(value))
    }

    private static func ms(_ seconds: TimeInterval) -> String {
        String(format: "%.0f", seconds * 1000) + "ms"
    }

    private static func ids(_ set: Set<CGWindowID>) -> String {
        "\(set.sorted())"
    }

    private func traced(_ rect: CGRect) -> String {
        "(\(traced(rect.minX)),\(traced(rect.minY)),\(traced(rect.width)),\(traced(rect.height)))"
    }

    private func traced(_ verdict: Verdict) -> String {
        switch verdict {
        case .accepted: return "accepted"
        case let .rejected(failure): return "rejected(\(failure))"
        case let .unknown(failure): return "unknown(\(failure))"
        }
    }

    private func stable(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= configuration.stableTolerance
            && abs(lhs.minY - rhs.minY) <= configuration.stableTolerance
            && abs(lhs.width - rhs.width) <= configuration.stableTolerance
            && abs(lhs.height - rhs.height) <= configuration.stableTolerance
    }

    private func valid(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.size.width.isFinite && frame.size.height.isFinite
            && frame.width > 0 && frame.height > 0
    }

    /// Whether a window already stands on `target`: a point of position and
    /// a point of size, not the cell of rounding the verdict allows after a
    /// write. That allowance is for an app that rounds what it was asked
    /// for; a window a cell short of its slot has not been asked yet, and
    /// taking it as standing there would never correct it.
    private func standsOn(_ actual: CGRect, _ target: CGRect) -> Bool {
        abs(actual.minX - target.minX) <= configuration.positionTolerance
            && abs(actual.minY - target.minY) <= configuration.positionTolerance
            && abs(actual.width - target.width) <= configuration.sizeTolerance
            && abs(actual.height - target.height) <= configuration.sizeTolerance
    }

    private func matches(_ actual: CGRect, _ target: CGRect) -> Bool {
        abs(actual.minX - target.minX) <= configuration.positionTolerance
            && abs(actual.minY - target.minY) <= configuration.positionTolerance
            && matchesSize(actual.width, target.width)
            && matchesSize(actual.height, target.height)
    }

    /// Containment, on the aggregate slack rather than the size tolerance.
    /// The origin must sit inside the usable frame within `positionTolerance`
    /// and the far edges may run past it by `aggregateSafetySlack`. A
    /// cell-rounded window at the screen edge grows into the outer padding,
    /// which is inside the usable frame and costs nothing; what it may not
    /// do is take a whole cell off the screen because its target already sat
    /// at the edge.
    private func contained(_ actual: CGRect, in usableFrame: CGRect) -> Bool {
        actual.minX >= usableFrame.minX - configuration.positionTolerance
            && actual.minY >= usableFrame.minY - configuration.positionTolerance
            && actual.maxX <= usableFrame.maxX + configuration.aggregateSafetySlack
            && actual.maxY <= usableFrame.maxY + configuration.aggregateSafetySlack
    }

    private func matchesSize(_ actual: CGFloat, _ target: CGFloat) -> Bool {
        actual - target <= configuration.sizeOvershootTolerance
            && target - actual <= configuration.sizeUndershootTolerance
    }

    /// Pairwise checks, on the aggregate slack rather than the size
    /// tolerance. A window that rounds its size up to a whole character cell
    /// may eat the gap, and that is all: two frames that really overlap —
    /// more than `aggregateSafetySlack` on both axes, so positive area
    /// rather than a fractional readback — are rejected however well each
    /// one matched its own target.
    ///
    /// The gap keeps `aggregateSafetySlack` of itself, so erosion is capped
    /// at `min(sizeOvershootTolerance, max(0, gap - aggregateSafetySlack))`
    /// and two tiles never come into contact. A gap no wider than the slack
    /// leaves nothing to erode, and a zero gap asks for no separation at all;
    /// either way the pair is left to the overlap check.
    ///
    /// Under `correspondenceOnly` the pairwise checks stop being verdicts.
    /// A rollback asks each window to go back where it was; whether those
    /// places overlap or sit gap-less is a fact about the originals, not
    /// about the rollback. Overlaps are collected on the result and the
    /// per-window match still decides.
    func validateFrames(targets: [Target], actualFrames: [CGWindowID: CGRect],
                        usableFrame: CGRect, gap: CGFloat) -> Result {
        let slack = configuration.aggregateSafetySlack
        // erosion stops a slack short of contact. a zero gap has nothing to
        // erode, so the overlap check alone judges that pair
        let erosion = min(configuration.sizeOvershootTolerance, max(0, gap - slack))
        for target in targets {
            guard let actual = actualFrames[target.windowID] else {
                return Result(verdict: .unknown(.windowUnavailable(target.windowID)), actualFrames: actualFrames)
            }
            guard contained(actual, in: usableFrame) else {
                return Result(verdict: .rejected(.outsideUsableFrame(target.windowID)), actualFrames: actualFrames)
            }
            if !matches(actual, target.frame) {
                return Result(verdict: .rejected(.geometryMismatch(target.windowID)), actualFrames: actualFrames)
            }
        }
        var overlaps: [FrameSizingOverlap] = []
        for i in targets.indices {
            for j in targets.indices where j > i {
                let first = targets[i]
                let second = targets[j]
                guard let actualA = actualFrames[first.windowID], let actualB = actualFrames[second.windowID] else { continue }
                if actualA.intersection(actualB).width > slack && actualA.intersection(actualB).height > slack {
                    // a rollback put each window back where it was. two
                    // originals that overlapped still overlap, and saying
                    // the rollback failed because of that would be a lie
                    // about correspondence — record it and carry on.
                    if configuration.correspondenceOnly {
                        overlaps.append(FrameSizingOverlap(first: first.windowID,
                                                           second: second.windowID))
                        continue
                    }
                    return Result(verdict: .rejected(.overlap(first.windowID, second.windowID)), actualFrames: actualFrames)
                }
                if configuration.correspondenceOnly || gap <= 0 { continue }
                let xSeparation = max(actualA.minX, actualB.minX) - min(actualA.maxX, actualB.maxX)
                let ySeparation = max(actualA.minY, actualB.minY) - min(actualA.maxY, actualB.maxY)
                if max(xSeparation, ySeparation) + 0.0001 < gap - erosion {
                    return Result(verdict: .rejected(.gapViolation(first.windowID, second.windowID)), actualFrames: actualFrames)
                }
            }
        }
        return Result(verdict: .accepted, actualFrames: actualFrames, overlaps: overlaps)
    }

}

/// What the two attempts behind one transaction are known to have done.
///
/// The candidate's written set and the restoration's are different sets: a
/// restoration writes every captured original, including windows the
/// candidate never reached, and the candidate can have written a window the
/// restoration then failed to reach. A consumer deciding what is still
/// trustworthy needs both, so both travel together.
struct FrameSizingProgressReport: Equatable {
    var candidate = FrameSizingAttempt.Progress()
    /// nil when no rollback ran: it was not needed, or the originals were
    /// not usable targets.
    var restoration: FrameSizingAttempt.Progress?
    /// restored originals that overlap each other. diagnostic only.
    var restorationOverlaps: [FrameSizingOverlap] = []

    /// every id either attempt issued a setter for. evidence of possible
    /// mutation, never proof a frame landed.
    var possiblyWritten: Set<CGWindowID> {
        candidate.possiblyWritten.union(restoration?.possiblyWritten ?? [])
    }

    /// Every target had every setter return success and the final
    /// readback was complete and stable, or the layout already stood and
    /// its capture was the readback. An empty target set satisfies the
    /// write and readback conditions vacuously and is not evidence of
    /// anything, so it does not count as verified.
    var candidateFullyWritten: Bool {
        !candidate.targetIDs.isEmpty
            && (candidate.verifiedInPlace
                || candidate.targetIDs.allSatisfy(candidate.writesCompleted.contains))
            && candidate.readbackComplete && candidate.readbackStable
    }

    /// Whether a candidate may become live geometry.
    ///
    /// One predicate for every publication decision — the tiling trees and
    /// the drag commit both ask this, so an accepted verdict cannot mean
    /// "publish" in one place and "publish if the writes finished" in the
    /// other. A layout with no targets wrote nothing and has nothing to
    /// verify; it publishes because that is how a workspace that lost its
    /// last window empties its tree.
    var candidateVerified: Bool {
        candidate.targetIDs.isEmpty || candidateFullyWritten
    }
}

struct FrameSizingTransaction {
    enum Outcome: Equatable {
        case accepted(actualFrames: [CGWindowID: CGRect])
        case rejectedRestored(reason: FrameSizingFailure, actualFrames: [CGWindowID: CGRect])
        case degraded(candidateReason: FrameSizingFailure,
                      restorationReason: FrameSizingFailure?,
                      actualFrames: [CGWindowID: CGRect])
    }

    /// An outcome plus what the attempts behind it did. Publication and
    /// cache recovery both need the provenance, so `apply` hands back one
    /// value carrying each.
    struct Report: Equatable {
        let outcome: Outcome
        var progress = FrameSizingProgressReport()
    }

    let attempt: FrameSizingAttempt
    /// Give a call AX gave up on at its messaging timeout one more try with
    /// `withTimeoutRecoveryBudget`, the way the verified layout's timeout
    /// recovery does. Off unless the caller asks. The tiled drag asks: an app
    /// that has just crossed displays can take longer than the 100 ms call
    /// timeout to answer (Messages, live: a position write refused at 101 ms,
    /// then the rollback's first read refused at 101 ms too).
    var recoversTimeouts = false
    /// Whether a longer try may still run. A tiled drag spends one budget
    /// across all of its attempts, so this asks the drop, not the attempt.
    var recoveryAllowed: () -> Bool = { true }

    /// A frame read, with its one timeout retry.
    func capture(windowIDs: [CGWindowID], generation: UInt64) -> FrameSizingAttempt.Result {
        let first = attempt.captureFrames(windowIDs: windowIDs, generation: generation)
        return retried(first, phase: .capture, ids: windowIDs, generation: generation) { relaxed in
            relaxed.captureFrames(windowIDs: windowIDs, generation: generation)
        }
    }

    /// A candidate attempt, with its one timeout retry.
    func candidate(targets: [FrameSizingAttempt.Target], usableFrame: CGRect, gap: CGFloat,
                   generation: UInt64,
                   phase: FrameSizingPhase = .candidate) -> FrameSizingAttempt.Result {
        let first = attempt.apply(targets: targets, usableFrame: usableFrame,
                                  gap: gap, generation: generation, phase: phase)
        return retried(first, phase: phase, ids: targets.map(\.windowID),
                       generation: generation) { relaxed in
            relaxed.apply(targets: targets, usableFrame: usableFrame, gap: gap,
                          generation: generation, phase: phase)
        }
    }

    /// A rollback, with its one timeout retry.
    func restore(originalFrames: [CGWindowID: CGRect], usableFrame: CGRect,
                 gap: CGFloat, generation: UInt64) -> FrameSizingAttempt.Result {
        let targets = originalFrames.map { FrameSizingAttempt.Target(windowID: $0.key, frame: $0.value) }
            .sorted { $0.windowID < $1.windowID }
        let first = Self.strict(attempt).apply(targets: targets, usableFrame: usableFrame,
                                               gap: gap, generation: generation, phase: .restoration)
        return retried(first, phase: .restoration, ids: targets.map(\.windowID),
                       generation: generation) { relaxed in
            Self.strict(relaxed).apply(targets: targets, usableFrame: usableFrame, gap: gap,
                                       generation: generation, phase: .restoration)
        }
    }

    private static func strict(_ attempt: FrameSizingAttempt) -> FrameSizingAttempt {
        var strictAttempt = attempt
        strictAttempt.configuration = attempt.configuration.restorationStrict
        return strictAttempt
    }

    /// `first`, or when it ended on an AX messaging timeout and nothing
    /// newer owns the geometry, one more run of `again` with the recovery
    /// budget. A timeout is what the verified layout's recovery asks for: a
    /// direct `cannotComplete` from a call that used up nearly all of its
    /// timeout. One that comes back at once is AX refusing, and restores.
    /// The retry's result stands, carrying every id either run may have
    /// written.
    private func retried(_ first: FrameSizingAttempt.Result, phase: FrameSizingPhase,
                         ids: [CGWindowID], generation: UInt64,
                         _ again: (FrameSizingAttempt) -> FrameSizingAttempt.Result)
        -> FrameSizingAttempt.Result {
        guard recoversTimeouts else { return first }
        guard let reason = first.verdict.failure else { return first }
        guard reason.isDirectCannotComplete, first.progress.timeoutShapedCannotComplete,
              attempt.io.currentGeneration() == generation else { return first }
        guard recoveryAllowed() else {
            hyprLog(.notice, .tiling, "frame attempt AX timeout recovery skipped: phase=\(phase.rawValue) "
                    + "reason=\(reason.trace) ids=\(ids) — the drop's time budget is spent")
            return first
        }
        var relaxed = attempt
        relaxed.configuration = attempt.configuration.withTimeoutRecoveryBudget
        hyprLog(.notice, .tiling, "frame attempt AX timeout recovery: phase=\(phase.rawValue) "
                + "reason=\(reason.trace) ids=\(ids) "
                + "timeout=\(Int((relaxed.configuration.perCallTimeout * 1000).rounded()))ms "
                + "deadline=\(Int((relaxed.configuration.deadline * 1000).rounded()))ms")
        var second = again(relaxed)
        second.progress.possiblyWritten.formUnion(first.progress.possiblyWritten)
        switch second.verdict {
        case .accepted:
            hyprLog(.notice, .tiling, "frame attempt AX timeout recovery accepted: phase=\(phase.rawValue)")
        case let .rejected(failure), let .unknown(failure):
            hyprLog(.notice, .tiling, "frame attempt AX timeout recovery refused: "
                    + "phase=\(phase.rawValue) reason=\(failure.trace)")
        }
        return second
    }

    // restorationUsableFrame: the rollback's rect, when it differs from the candidate's
    func apply(targets: [FrameSizingAttempt.Target], originalFrames: [CGWindowID: CGRect],
               usableFrame: CGRect, restorationUsableFrame: CGRect? = nil,
               gap: CGFloat, generation: UInt64,
               phase: FrameSizingPhase = .candidate) -> Report {
        guard Set(targets.map(\.windowID)) == Set(originalFrames.keys) else {
            return Report(outcome: .degraded(candidateReason: .windowUnavailable(
                targets.first(where: { originalFrames[$0.windowID] == nil })?.windowID ?? 0),
                restorationReason: nil,
                actualFrames: [:]))
        }
        let candidate = self.candidate(targets: targets, usableFrame: usableFrame,
                                       gap: gap, generation: generation, phase: phase)
        let candidateOnly = FrameSizingProgressReport(candidate: candidate.progress)
        func report(_ outcome: Outcome, restored: FrameSizingAttempt.Result? = nil) -> Report {
            var progress = candidateOnly
            progress.restoration = restored?.progress
            progress.restorationOverlaps = restored?.overlaps ?? []
            return Report(outcome: outcome, progress: progress)
        }
        switch candidate.verdict {
        case .accepted:
            return report(.accepted(actualFrames: candidate.actualFrames))
        case .unknown(.superseded):
            return report(.degraded(candidateReason: .superseded, restorationReason: nil,
                                    actualFrames: candidate.actualFrames))
        case let .rejected(reason), let .unknown(reason):
            guard attempt.io.currentGeneration() == generation else {
                return report(.degraded(candidateReason: reason, restorationReason: nil,
                                        actualFrames: candidate.actualFrames))
            }
            let restored = restore(originalFrames: originalFrames,
                                   usableFrame: restorationUsableFrame ?? usableFrame,
                                   gap: gap, generation: generation)
            switch restored.verdict {
            case .accepted:
                return report(.rejectedRestored(reason: reason, actualFrames: restored.actualFrames),
                              restored: restored)
            case let .rejected(restoreReason), let .unknown(restoreReason):
                return report(.degraded(candidateReason: reason, restorationReason: restoreReason,
                                        actualFrames: restored.actualFrames),
                              restored: restored)
            }
        }
    }
}
