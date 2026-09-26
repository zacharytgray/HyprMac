import Cocoa

enum FrameSizingFailure: Equatable {
    indirect case cleanupFailed(CGWindowID, primary: FrameSizingFailure?, error: AXError)
    case writeFailed(CGWindowID, AXError)
    case readFailed(CGWindowID, AXError)
    case deadlineExceeded
    case attemptsExhausted
    case noFittingSlot(CGWindowID)
    case geometryMismatch(CGWindowID)
    case outsideUsableFrame(CGWindowID)
    case overlap(CGWindowID, CGWindowID)
    case gapViolation(CGWindowID, CGWindowID)
    case windowUnavailable(CGWindowID)
    case duplicateWindowID(CGWindowID)
    case invalidFrame(CGWindowID)
    case superseded
}

extension FrameSizingFailure {
    /// The app did not answer in time: the attempt ran out of budget, the
    /// readback never settled, or AX gave up waiting (`cannotComplete` is
    /// what a messaging timeout returns). None of these says the app refused
    /// the frames. Admission recovery retries them instead of floating.
    var isTimeout: Bool {
        switch self {
        case .deadlineExceeded, .attemptsExhausted:
            return true
        case let .writeFailed(_, error), let .readFailed(_, error):
            return error == .cannotComplete
        case let .cleanupFailed(_, primary, error):
            return primary?.isTimeout ?? (error == .cannotComplete)
        default:
            return false
        }
    }
}

struct FrameSizingIO {
    let setMessagingTimeout: (CGWindowID, TimeInterval) -> AXError
    let writeSize: (CGWindowID, CGSize, TimeInterval) -> AXError
    let writePosition: (CGWindowID, CGPoint, TimeInterval) -> AXError
    let readPosition: (CGWindowID, TimeInterval) -> (AXError, CGPoint?)
    let readSize: (CGWindowID, TimeInterval) -> (AXError, CGSize?)
    let now: () -> TimeInterval
    let sleep: (TimeInterval) -> Void
    let currentGeneration: () -> UInt64
    var beginFrameWrite: (CGWindowID, TimeInterval, () -> FrameSizingFailure?) -> AXFrameWriteBatch.BeginResult = {
        windowID, _, _ in .ready(.noop(windowID: windowID))
    }
    var endFrameWrite: (AXFrameWriteBatch.Token, TimeInterval, () -> FrameSizingFailure?) -> AXFrameWriteBatch.EndResult = {
        _, _, _ in .restored
    }
}

extension FrameSizingIO {
    static func accessibility(windows: [CGWindowID: HyprWindow],
                              currentGeneration: @escaping () -> UInt64) -> FrameSizingIO {
        FrameSizingIO(
            setMessagingTimeout: { id, timeout in
                windows[id]?.setMessagingTimeout(timeout) ?? .invalidUIElement
            },
            writeSize: { id, size, _ in windows[id]?.writeSize(size) ?? .invalidUIElement },
            writePosition: { id, position, _ in windows[id]?.writePosition(position) ?? .invalidUIElement },
            readPosition: { id, _ in windows[id]?.readPosition() ?? (.invalidUIElement, nil) },
            readSize: { id, _ in windows[id]?.readSize() ?? (.invalidUIElement, nil) },
            now: { ProcessInfo.processInfo.systemUptime },
            sleep: { Thread.sleep(forTimeInterval: $0) },
            currentGeneration: currentGeneration,
            beginFrameWrite: { id, timeout, checkpoint in
                windows[id]?.beginFrameWrite(timeout: timeout, checkpoint: checkpoint)
                    ?? .failed(.invalidUIElement)
            },
            endFrameWrite: { token, timeout, checkpoint in
                AXFrameWriteBatch.accessibility.end(token, timeout: timeout,
                                                    checkpoint: checkpoint)
            }
        )
    }
}

struct FrameSizingConfiguration {
    var deadline: TimeInterval = 0.36
    var pollInterval: TimeInterval = 0.03
    var maximumAttempts: Int = 12
    var positionTolerance: CGFloat = 1
    var sizeTolerance: CGFloat = 1
    // cell-quantizing apps (terminals) round a target to whole character
    // cells, in either direction. restoration pins both back to sizeTolerance.
    var sizeOvershootTolerance: CGFloat = TilingConfig.frameToleranceXPx
    var sizeUndershootTolerance: CGFloat = TilingConfig.frameToleranceXPx
    /// How far the aggregate checks — actual overlap and escape past the
    /// far edges — bend, which is comparison slack for a readback that
    /// lands a fraction off, not room to round into. It is deliberately
    /// independent of the size tolerances: an app may round its own size to
    /// a whole cell, but two windows still may not sit on top of each other
    /// and no window may leave the screen.
    var aggregateSafetySlack: CGFloat = 1
    var stableTolerance: CGFloat = 0.01
    var requiredStableSamples: Int = 2
    var minimumMismatchSettle: TimeInterval = 0.24
    var perCallTimeout: TimeInterval = 0.1
    /// A parked window can still be constrained by its old display for a
    /// short time after its position changes. Observe the target position
    /// settle before asking that window to take the destination size.
    var positionSettleWindowIDs: Set<CGWindowID> = []
    /// Restoration only. A rollback asks every window to go back where it
    /// was, so the question is per-window correspondence, not whether the
    /// result is a valid tiled arrangement. Originals that overlapped each
    /// other before the candidate ran still overlap after it, and that is
    /// not a failed rollback — the overlap is reported on the result
    /// instead of rejecting it.
    var correspondenceOnly = false
    /// The budget for a pass that moves a window onto a screen with a
    /// different backing scale factor. The app redraws everything at the
    /// new scale while our AX calls wait behind it. On the MacBook's 2x
    /// panel the first write after a hop from a 1x external missed 0.36 s on
    /// every move, and the retry 250 ms later usually verified.
    var scaleChangeDeadline: TimeInterval = 1.0

    /// This configuration with the scale-change budget. The sample limit
    /// grows with the deadline so the settle loop can use the extra time.
    var withScaleChangeBudget: FrameSizingConfiguration {
        var extended = self
        extended.deadline = max(deadline, scaleChangeDeadline)
        extended.maximumAttempts = max(maximumAttempts,
                                       Int((extended.deadline / pollInterval).rounded(.up)))
        return extended
    }
}

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
    }

    /// What an attempt is known to have done, carried on every result so a
    /// caller can tell "nothing went out" from "three setters went out and
    /// we never read them back".
    ///
    /// `possiblyWritten` records that a setter was issued — it is evidence
    /// of a possible mutation, never proof the app applied the frame.
    /// `writesCompleted` means all three frame setters returned success for
    /// that window; the cleanup that follows carries its own error.
    struct Progress: Equatable {
        var phase: FrameSizingPhase = .candidate
        var generation: UInt64 = 0
        var targetIDs: [CGWindowID] = []
        var possiblyWritten: Set<CGWindowID> = []
        var writesCompleted: Set<CGWindowID> = []
        /// A setter or frame read returned `cannotComplete` after consuming
        /// nearly all of its configured messaging timeout.
        var timeoutShapedCannotComplete = false
        /// every target produced a readable frame
        var readbackComplete = false
        /// every target reached the configured stable sample count
        var readbackStable = false
    }

    /// Phase durations for the attempt trace. Not part of the typed
    /// result — nothing decides on these, they only get logged.
    struct Timings {
        var write: TimeInterval = 0
        var read: TimeInterval = 0
        var settle: TimeInterval = 0
        /// per window, every setter with its raw AX code and duration
        var steps: [String] = []
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

    func captureFrames(windowIDs: [CGWindowID], generation: UInt64) -> Result {
        let started = io.now()
        var frames: [CGWindowID: CGRect] = [:]
        let progress = Progress(phase: .capture, generation: generation,
                                targetIDs: windowIDs.sorted())
        // a capture never writes, so only the readback fields move
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
            let (positionError, position) = io.readPosition(windowID, configuration.perCallTimeout)
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
            let (sizeError, size) = io.readSize(windowID, configuration.perCallTimeout)
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

    /// Traced wrapper around the attempt. Every line is `.debug` and built
    /// inside `hyprLog`'s autoclosure, so nothing is formatted unless the
    /// file log or the trace tier is on.
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
        // one line per window listing every setter that went out, with its
        // raw AX code and how long it took
        func traceSteps(_ complete: Bool) {
            let listed = steps.isEmpty ? "none" : steps.joined(separator: ",")
            // total also covers the enhanced-ui begin and the timeout
            // setup, so total minus the setters is what those cost
            timings.steps.append("\(target.windowID):\(listed)/total=\(Self.ms(io.now() - writeStarted))")
            hyprLog(.debug, .tiling, "frame write: wid=\(target.windowID) phase=\(phase.rawValue) "
                    + "steps=\(listed) complete=\(complete)")
        }
        hyprLog(.debug, .tiling,
                "frame write: wid=\(target.windowID) phase=\(phase.rawValue) "
                + "target=\(traced(target.frame))")
        if let failure = checkpoint() {
            traceSteps(false)
            return Result(verdict: .unknown(failure), actualFrames: actualFrames)
        }
        let token: AXFrameWriteBatch.Token
        switch io.beginFrameWrite(target.windowID, configuration.perCallTimeout, checkpoint) {
        case let .ready(value): token = value
        case let .failed(error):
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

        let settlePositionBeforeSizing = configuration.positionSettleWindowIDs.contains(target.windowID)
        let writes: [(String, () -> AXError)] = settlePositionBeforeSizing
            ? [
                ("position", { io.writePosition(target.windowID, target.frame.origin, configuration.perCallTimeout) }),
                ("size", { io.writeSize(target.windowID, target.frame.size, configuration.perCallTimeout) }),
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
                    var anchor: CGPoint?
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
                        let onTarget = abs(position.x - target.frame.minX) <= configuration.positionTolerance
                            && abs(position.y - target.frame.minY) <= configuration.positionTolerance
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
                        if attempt + 1 < configuration.maximumAttempts {
                            io.sleep(configuration.pollInterval)
                        }
                    }
                    guard settled else {
                        traceSteps(false)
                        return end(token, windowID: target.windowID,
                                   preserving: Result(verdict: .unknown(.attemptsExhausted),
                                                      actualFrames: actualFrames),
                                   checkpoint: checkpoint)
                    }
                }
                continue
            }
            traceSteps(false)
            return end(token, windowID: target.windowID, preserving: primary,
                       checkpoint: checkpoint)
        }
        // all three setters returned success. record that before cleanup —
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
        let reason: FrameSizingFailure?
        switch primary.verdict {
        case .accepted: reason = nil
        case let .rejected(failure), let .unknown(failure): reason = failure
        }
        return Result(verdict: .unknown(.cleanupFailed(windowID, primary: reason, error: error)),
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

    /// Every target had all three setters return success and the final
    /// readback was complete and stable. An empty target set satisfies the
    /// write and readback conditions vacuously and is not evidence of
    /// anything, so it does not count as verified.
    var candidateFullyWritten: Bool {
        !candidate.targetIDs.isEmpty
            && candidate.targetIDs.allSatisfy(candidate.writesCompleted.contains)
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

    func restore(originalFrames: [CGWindowID: CGRect], usableFrame: CGRect,
                 gap: CGFloat, generation: UInt64) -> FrameSizingAttempt.Result {
        let targets = originalFrames.map { FrameSizingAttempt.Target(windowID: $0.key, frame: $0.value) }
            .sorted { $0.windowID < $1.windowID }
        var strictAttempt = attempt
        strictAttempt.configuration.sizeOvershootTolerance = strictAttempt.configuration.sizeTolerance
        strictAttempt.configuration.sizeUndershootTolerance = strictAttempt.configuration.sizeTolerance
        strictAttempt.configuration.aggregateSafetySlack = strictAttempt.configuration.sizeTolerance
        strictAttempt.configuration.correspondenceOnly = true
        return strictAttempt.apply(targets: targets, usableFrame: usableFrame,
                                   gap: gap, generation: generation, phase: .restoration)
    }

    func apply(targets: [FrameSizingAttempt.Target], originalFrames: [CGWindowID: CGRect],
               usableFrame: CGRect, gap: CGFloat, generation: UInt64,
               phase: FrameSizingPhase = .candidate) -> Report {
        guard Set(targets.map(\.windowID)) == Set(originalFrames.keys) else {
            return Report(outcome: .degraded(candidateReason: .windowUnavailable(
                targets.first(where: { originalFrames[$0.windowID] == nil })?.windowID ?? 0),
                restorationReason: nil,
                actualFrames: [:]))
        }
        let candidate = attempt.apply(targets: targets, usableFrame: usableFrame,
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
            let restored = restore(originalFrames: originalFrames, usableFrame: usableFrame,
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
