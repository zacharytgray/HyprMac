import Cocoa

// FrameReadbackPoller — pass-2 layout settle/conflict detection.
//
// after the engine writes target frames via setFrame, AX returns asynchronously
// — apps that won't shrink (Spotify, Messages) or are clamped by a screen-edge
// race (cross-monitor moves) report different actual sizes than requested.
// this type drives the readback loop:
//
//   1. sleep `readbackPollInterval`, snapshot all readings
//   2. while any reading exceeds or undershoots tolerance and we haven't hit
//      `readbackMaxWait`, sleep again and re-read
//      - undershoots get re-applied (re-issued setFrame against the cross-screen race)
//      - oversized readings need `readbackStableSamples` consecutive matching
//        reads after a `readbackMinConflictSettle` floor before they count as
//        a real min-size conflict (transient AX sizes don't inflate ratios)
//   3. classify final readings into conflicts (settled oversize), accepted
//      (within tolerance), and observations (oversize per-axis flags for the
//      engine's min-size memory)
//
// pure with respect to tiling state — the engine owns the min-size memory and
// applies these results after the call returns.
struct FrameReadbackPoller {

    struct Conflict {
        let window: HyprWindow
        let allocated: CGRect
        let actual: CGSize
    }

    // an observed oversize reading. engine uses this to update its
    // recordObservedMinimumSize memory.
    struct Observation {
        let window: HyprWindow
        let actual: CGSize
        let widthConflict: Bool
        let heightConflict: Bool
    }

    struct Result {
        let conflicts: [Conflict]
        let observations: [Observation]
        // windows whose actual size came back smaller-or-equal to the request —
        // engine uses these to potentially relax a previously-recorded min-size
        // bound (lowerMinimumSizeIfAccepted).
        let accepted: [(HyprWindow, CGSize)]
    }

    /// Apply target frames and poll until the AX readbacks settle or
    /// `TilingConfig.readbackMaxWait` elapses. Returns classified outcomes for
    /// the engine to reconcile against its min-size memory.
    func applyLayout(_ layouts: [(HyprWindow, CGRect)]) -> Result {
        guard !layouts.isEmpty else {
            return Result(conflicts: [], observations: [], accepted: [])
        }

        // diagnostic: previous frames let us log how much a window actually moved.
        var prev: [CGWindowID: CGRect] = [:]
        for (w, _) in layouts {
            if let cached = w.cachedFrame { prev[w.windowID] = cached }
        }

        for (window, frame) in layouts {
            window.setFrame(frame)
        }

        struct Reading {
            let window: HyprWindow
            let frame: CGRect
            var actual: CGRect
            var stableSamples: Int
            var elapsed: TimeInterval
        }

        func read(_ window: HyprWindow, target: CGRect) -> CGRect {
            let actualSize = window.size ?? target.size
            let actualPos = window.position ?? target.origin
            return CGRect(origin: actualPos, size: actualSize)
        }

        func exceeds(_ actual: CGRect, _ target: CGRect) -> Bool {
            actual.width > target.width + TilingConfig.frameToleranceXPx
                || actual.height > target.height + TilingConfig.frameToleranceXPx
        }

        func undershoots(_ actual: CGRect, _ target: CGRect) -> Bool {
            actual.width < target.width - TilingConfig.frameToleranceXPx
                || actual.height < target.height - TilingConfig.frameToleranceXPx
        }

        let interval = TilingConfig.readbackPollInterval
        let maxWait = TilingConfig.readbackMaxWait
        let minConflictSettle = TilingConfig.readbackMinConflictSettle
        let stableTolerance = TilingConfig.readbackStableTolerancePx
        var elapsed: TimeInterval = 0
        var readings: [Reading] = []

        Thread.sleep(forTimeInterval: interval)
        elapsed += interval
        for (window, frame) in layouts {
            readings.append(Reading(window: window, frame: frame,
                                    actual: read(window, target: frame),
                                    stableSamples: 0,
                                    elapsed: elapsed))
        }

        // accepted layouts exit fast. over-target readings must settle for two
        // consecutive samples after a longer floor before they can adjust ratios.
        // under-target readings are usually a cross-screen clamp/race; reapply
        // until the destination screen accepts the requested size.
        while readings.contains(where: { exceeds($0.actual, $0.frame) || undershoots($0.actual, $0.frame) }) && elapsed < maxWait {
            Thread.sleep(forTimeInterval: interval)
            elapsed += interval

            var anyUnsettledConflict = false
            var anyUndersizedFrame = false
            for i in readings.indices {
                let next = read(readings[i].window, target: readings[i].frame)
                let stable = abs(next.width - readings[i].actual.width) <= stableTolerance
                    && abs(next.height - readings[i].actual.height) <= stableTolerance
                readings[i].actual = next
                readings[i].elapsed = elapsed
                readings[i].stableSamples = stable ? readings[i].stableSamples + 1 : 0

                if undershoots(next, readings[i].frame) {
                    readings[i].window.setFrame(readings[i].frame)
                    anyUndersizedFrame = true
                    continue
                }

                if exceeds(next, readings[i].frame),
                   elapsed < minConflictSettle || readings[i].stableSamples < TilingConfig.readbackStableSamples {
                    anyUnsettledConflict = true
                }
            }

            if !anyUnsettledConflict && !anyUndersizedFrame { break }
        }

        var conflicts: [Conflict] = []
        var observations: [Observation] = []
        var accepted: [(HyprWindow, CGSize)] = []

        for r in readings {
            let widthConflict = r.actual.width > r.frame.width + TilingConfig.frameToleranceXPx
            let heightConflict = r.actual.height > r.frame.height + TilingConfig.frameToleranceXPx
            let widthUndershot = r.actual.width < r.frame.width - TilingConfig.frameToleranceXPx
            let heightUndershot = r.actual.height < r.frame.height - TilingConfig.frameToleranceXPx

            if widthConflict || heightConflict {
                let settled = r.elapsed >= minConflictSettle && r.stableSamples >= TilingConfig.readbackStableSamples
                if !settled {
                    hyprLog(.debug, .lifecycle, "unsettled readback ignored: '\(r.window.title ?? "?")' wanted \(Int(r.frame.width))x\(Int(r.frame.height)), saw \(Int(r.actual.width))x\(Int(r.actual.height)) after \(Int(r.elapsed * 1000))ms")
                    r.window.cachedFrame = r.frame
                    continue
                }

                hyprLog(.debug, .lifecycle, "min-size conflict: '\(r.window.title ?? "?")' wanted \(Int(r.frame.width))x\(Int(r.frame.height)), got \(Int(r.actual.width))x\(Int(r.actual.height))")
                conflicts.append(Conflict(window: r.window, allocated: r.frame, actual: r.actual.size))
                observations.append(Observation(window: r.window, actual: r.actual.size,
                                                widthConflict: widthConflict, heightConflict: heightConflict))
            } else if widthUndershot || heightUndershot {
                hyprLog(.debug, .lifecycle, "undersized readback: '\(r.window.title ?? "?")' wanted \(Int(r.frame.width))x\(Int(r.frame.height)), saw \(Int(r.actual.width))x\(Int(r.actual.height)) after \(Int(r.elapsed * 1000))ms")
                r.window.setFrame(r.frame)
                r.window.cachedFrame = r.frame
                continue
            } else {
                accepted.append((r.window, r.actual.size))
            }
            r.window.cachedFrame = r.actual

            if let previous = prev[r.window.windowID], widthConflict || heightConflict {
                let deltaW = abs(r.actual.width - previous.width)
                let deltaH = abs(r.actual.height - previous.height)
                hyprLog(.debug, .lifecycle, "readback settled in \(Int(r.elapsed * 1000))ms for '\(r.window.title ?? "?")' (delta \(Int(deltaW))x\(Int(deltaH)))")
            }
        }

        return Result(conflicts: conflicts, observations: observations, accepted: accepted)
    }

    /// Apply the final pass-2 layout once ratios are settled. Plain setFrame —
    /// no readback needed since the layout has already been validated.
    func applyFinal(_ layouts: [(HyprWindow, CGRect)]) {
        for (window, frame) in layouts {
            window.setFrame(frame)
        }
    }
}
