import Cocoa

struct FrameReadbackPoller {
    struct Conflict {
        let window: HyprWindow
        let allocated: CGRect
        let actual: CGSize
    }

    /// One window's evidence that it refused to shrink. Only produced when
    /// every guard in `learningRefusal` is satisfied, so a consumer may
    /// treat it as a constraint the app actually imposed.
    struct Observation {
        let window: HyprWindow
        let target: CGSize
        let actual: CGSize
        let widthConflict: Bool
        let heightConflict: Bool
    }

    /// Why a window's apparent oversize teaches nothing. Each case is a
    /// reason the readback cannot be read as "this app refused to be that
    /// small", whatever the numbers say.
    enum LearningRefusal: String {
        /// a rollback to the original frames is not a tiling target
        case restorationPhase
        /// accepted geometry, or an attempt that gave up before a verdict
        case notRejected
        /// a write, cleanup or read error, or any other failure that is not
        /// a geometric refusal: the frames say nothing about size
        case ioFailure
        /// not all three setters returned success for this window
        case writesIncomplete
        /// a target went unread, or nothing settled
        case readbackIncomplete
        /// the window is not where it was told to go, so its size is stale
        case originMismatch
    }

    struct Result {
        let verdict: FrameSizingAttempt.Verdict
        let actualFrames: [CGWindowID: CGRect]
        let conflicts: [Conflict]
        let observations: [Observation]
        let accepted: [(HyprWindow, CGSize)]
        var progress = FrameSizingAttempt.Progress()
        /// restored originals that overlap each other. restoration only,
        /// and a diagnostic rather than a failure — see
        /// `FrameSizingConfiguration.correspondenceOnly`.
        var overlaps: [FrameSizingOverlap] = []
    }

    private let configuration: FrameSizingConfiguration
    private let generation: () -> UInt64
    private let ioFactory: ([CGWindowID: HyprWindow], @escaping () -> UInt64) -> FrameSizingIO

    init(configuration: FrameSizingConfiguration = FrameSizingConfiguration(),
         generation: @escaping () -> UInt64 = { 0 },
         ioFactory: @escaping ([CGWindowID: HyprWindow], @escaping () -> UInt64) -> FrameSizingIO = FrameSizingIO.accessibility) {
        self.configuration = configuration
        self.generation = generation
        self.ioFactory = ioFactory
    }

    /// The same poller with the scale-change budget, for a pass that moves a
    /// window onto a screen with a different backing scale factor.
    func withScaleChangeBudget() -> FrameReadbackPoller {
        FrameReadbackPoller(configuration: configuration.withScaleChangeBudget,
                            generation: generation, ioFactory: ioFactory)
    }

    var deadline: TimeInterval { configuration.deadline }

    func applyLayout(_ layouts: [(HyprWindow, CGRect)], usableFrame: CGRect,
                     gap: CGFloat, generation requestedGeneration: UInt64) -> Result {
        applyLayout(layouts, usableFrame: usableFrame, gap: gap,
                    generation: requestedGeneration, configuration: configuration,
                    phase: .candidate)
    }

    func applyWorkspaceReveal(_ layouts: [(HyprWindow, CGRect)], parkedWindowIDs: Set<CGWindowID>,
                              usableFrame: CGRect, gap: CGFloat,
                              generation requestedGeneration: UInt64) -> Result {
        var revealConfiguration = configuration
        revealConfiguration.positionSettleWindowIDs = parkedWindowIDs
        return applyLayout(layouts, usableFrame: usableFrame, gap: gap,
                           generation: requestedGeneration, configuration: revealConfiguration,
                           phase: .candidate)
    }

    func applyRestoration(_ layouts: [(HyprWindow, CGRect)], usableFrame: CGRect,
                          gap: CGFloat, generation requestedGeneration: UInt64) -> Result {
        var strictConfiguration = configuration
        strictConfiguration.sizeOvershootTolerance = strictConfiguration.sizeTolerance
        strictConfiguration.sizeUndershootTolerance = strictConfiguration.sizeTolerance
        strictConfiguration.aggregateSafetySlack = strictConfiguration.sizeTolerance
        strictConfiguration.correspondenceOnly = true
        return applyLayout(layouts, usableFrame: usableFrame, gap: gap,
                           generation: requestedGeneration, configuration: strictConfiguration,
                           phase: .restoration)
    }

    private func applyLayout(_ layouts: [(HyprWindow, CGRect)], usableFrame: CGRect,
                             gap: CGFloat, generation requestedGeneration: UInt64,
                             configuration: FrameSizingConfiguration,
                             phase: FrameSizingPhase) -> Result {
        let ids = layouts.map { $0.0.windowID }
        let unstarted = FrameSizingAttempt.Progress(phase: phase, generation: requestedGeneration,
                                                    targetIDs: ids)
        guard generation() == requestedGeneration else {
            return Result(verdict: .unknown(.superseded), actualFrames: [:],
                          conflicts: [], observations: [], accepted: [], progress: unstarted)
        }
        guard !layouts.isEmpty else {
            return Result(verdict: .accepted, actualFrames: [:], conflicts: [],
                          observations: [], accepted: [], progress: unstarted)
        }
        if let duplicate = ids.first(where: { id in ids.filter { $0 == id }.count > 1 }) {
            return Result(verdict: .rejected(.duplicateWindowID(duplicate)),
                          actualFrames: [:], conflicts: [],
                          observations: [], accepted: [], progress: unstarted)
        }
        let windows = Dictionary(uniqueKeysWithValues: layouts.map { ($0.0.windowID, $0.0) })
        if generation() == requestedGeneration {
            for (window, _) in layouts { window.cachedFrame = nil }
        }
        let attempt = FrameSizingAttempt(
            io: ioFactory(windows, generation),
            configuration: configuration
        )
        let raw = attempt.apply(
            targets: layouts.map { .init(windowID: $0.0.windowID, frame: $0.1) },
            usableFrame: usableFrame, gap: gap, generation: requestedGeneration,
            phase: phase
        )
        return classify(raw, layouts: layouts, configuration: configuration)
    }

    func captureFrames(_ windows: [HyprWindow], generation requestedGeneration: UInt64) -> FrameSizingAttempt.Result {
        var seen = Set<CGWindowID>()
        for window in windows where !seen.insert(window.windowID).inserted {
            return FrameSizingAttempt.Result(verdict: .unknown(.duplicateWindowID(window.windowID)),
                                             actualFrames: [:])
        }
        let windowMap = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        return FrameSizingAttempt(io: ioFactory(windowMap, generation), configuration: configuration)
            .captureFrames(windowIDs: windows.map(\.windowID), generation: requestedGeneration)
    }

    @discardableResult
    func applyFinal(_ layouts: [(HyprWindow, CGRect)], usableFrame: CGRect,
                    gap: CGFloat, generation requestedGeneration: UInt64) -> Result {
        applyLayout(layouts, usableFrame: usableFrame, gap: gap,
                    generation: requestedGeneration, configuration: configuration,
                    phase: .adjusted)
    }

    private func classify(_ raw: FrameSizingAttempt.Result,
                          layouts: [(HyprWindow, CGRect)],
                          configuration: FrameSizingConfiguration) -> Result {
        var conflicts: [Conflict] = []
        var observations: [Observation] = []
        var accepted: [(HyprWindow, CGSize)] = []
        let phase = raw.progress.phase
        for (window, target) in layouts {
            guard let actual = raw.actualFrames[window.windowID] else { continue }
            if case .unknown = raw.verdict { continue }
            window.cachedFrame = actual
            // a rollback writes the frames the windows already had, so
            // nothing it reads back is evidence about a tiling target
            if phase == .restoration { continue }
            // cell rounding is not a min-size floor, so it must not teach
            // one. the boundary is the candidate overshoot tolerance
            // whatever configuration this pass ran under.
            let widthConflict = actual.width > target.width + self.configuration.sizeOvershootTolerance
            let heightConflict = actual.height > target.height + self.configuration.sizeOvershootTolerance
            if widthConflict || heightConflict, case .rejected = raw.verdict {
                let refusal = Self.learningRefusal(windowID: window.windowID,
                                                   target: target, actual: actual,
                                                   verdict: raw.verdict, progress: raw.progress,
                                                   positionTolerance: configuration.positionTolerance)
                if refusal == nil {
                    conflicts.append(Conflict(window: window, allocated: target, actual: actual.size))
                    observations.append(Observation(window: window, target: target.size,
                                                    actual: actual.size,
                                                    widthConflict: widthConflict,
                                                    heightConflict: heightConflict))
                }
                hyprLog(.debug, .tiling, "min evidence: wid=\(window.windowID) "
                        + "phase=\(phase.rawValue) "
                        + "target=\(Self.size(target.size)) actual=\(Self.size(actual.size)) "
                        + "axis=\(Self.axis(width: widthConflict, height: heightConflict)) "
                        + "written=\(raw.progress.possiblyWritten.contains(window.windowID)) "
                        + "complete=\(raw.progress.writesCompleted.contains(window.windowID)) "
                        + "stable=\(raw.progress.readbackStable) "
                        + "learn=\(refusal == nil) refused=\(refusal?.rawValue ?? "none") "
                        + "source=readback")
            } else if raw.verdict == .accepted {
                accepted.append((window, actual.size))
            }
        }
        return Result(verdict: raw.verdict, actualFrames: raw.actualFrames,
                      conflicts: conflicts, observations: observations,
                      accepted: accepted, progress: raw.progress, overlaps: raw.overlaps)
    }

    /// Whether this window's oversize may teach a minimum, and if not, why
    /// not. Nil means the evidence is good: this window's three setters all
    /// returned success, every target read back and settled, the window is
    /// at the origin it was given, and the attempt ended in a geometric
    /// refusal rather than an I/O error.
    ///
    /// The verdict is judged per window. An aggregate rejection names one
    /// id, but another window in the same pass can still have refused its
    /// own size, and a window whose own evidence fails a guard is skipped
    /// without silencing the rest.
    static func learningRefusal(windowID: CGWindowID, target: CGRect, actual: CGRect,
                                verdict: FrameSizingAttempt.Verdict,
                                progress: FrameSizingAttempt.Progress,
                                positionTolerance: CGFloat) -> LearningRefusal? {
        if progress.phase == .restoration { return .restorationPhase }
        guard case let .rejected(failure) = verdict else { return .notRejected }
        switch failure {
        case .noFittingSlot, .writeFailed, .readFailed, .cleanupFailed, .windowUnavailable,
             .duplicateWindowID, .invalidFrame, .superseded, .deadlineExceeded,
             .attemptsExhausted:
            return .ioFailure
        case .geometryMismatch, .outsideUsableFrame, .overlap, .gapViolation:
            break
        }
        guard progress.writesCompleted.contains(windowID) else { return .writesIncomplete }
        guard progress.readbackComplete, progress.readbackStable else { return .readbackIncomplete }
        guard abs(actual.minX - target.minX) <= positionTolerance,
              abs(actual.minY - target.minY) <= positionTolerance else { return .originMismatch }
        return nil
    }

    static func axis(width: Bool, height: Bool) -> String {
        switch (width, height) {
        case (true, true): return "width+height"
        case (true, false): return "width"
        case (false, true): return "height"
        case (false, false): return "none"
        }
    }

    private static func size(_ size: CGSize) -> String {
        String(format: "%gx%g", Double(size.width), Double(size.height))
    }

}
