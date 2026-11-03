// Parks windows by position alone and checks they stay hidden. Sets no
// messaging timeouts of its own.

import CoreGraphics

struct ParkAttempt {
    let io: FrameSizingIO
    let isCurrent: () -> Bool

    func run(windowIDs: [CGWindowID], originals: [CGWindowID: CGRect], at position: CGPoint,
             displayFrames: [CGRect]) -> TilingEngine.SoleWindowParkingResult {
        for windowID in windowIDs {
            guard isCurrent() else { return .degraded(.superseded) }
            let checkpoint = { () -> FrameSizingFailure? in
                isCurrent() ? nil : .superseded
            }
            let token: AXFrameWriteBatch.Token
            switch io.beginFrameWrite(windowID, 0.1, checkpoint) {
            case .ready(let value): token = value
            case .failed(let error): return .degraded(.writeFailed(windowID, error))
            case .failedAfterCleanup(let error, _):
                return .degraded(.writeFailed(windowID, error))
            case .interrupted(let reason): return .degraded(reason)
            case .interruptedAfterBegin(let value, let reason):
                _ = io.endFrameWrite(value, 0.1, checkpoint)
                return .degraded(reason)
            }
            if let reason = checkpoint() {
                _ = io.endFrameWrite(token, 0.1, checkpoint)
                return .degraded(reason)
            }
            let error = io.writePosition(windowID, position, 0.1)
            let cleanup = io.endFrameWrite(token, 0.1, checkpoint)
            guard error == .success else { return .degraded(.writeFailed(windowID, error)) }
            guard cleanup == .restored else {
                let cleanupError: AXError
                switch cleanup {
                case .restored: cleanupError = .success
                case .failed(let error): cleanupError = error
                case .failedTimeoutAndRestore(let timeout, _): cleanupError = timeout
                }
                return .degraded(.cleanupFailed(windowID, primary: nil, error: cleanupError))
            }
        }
        let deadline = io.now() + 0.36
        var stableSamples: [CGWindowID: Int] = [:]
        var lastFrames: [CGWindowID: CGRect] = [:]
        repeat {
            guard isCurrent() else { return .degraded(.superseded) }
            var pending = false
            for windowID in windowIDs {
                guard originals[windowID] != nil else {
                    return .degraded(.windowUnavailable(windowID))
                }
                let positionRead = io.readPosition(windowID, 0.1)
                let sizeRead = io.readSize(windowID, 0.1)
                guard positionRead.0 == .success, sizeRead.0 == .success,
                      let actualPosition = positionRead.1, let actualSize = sizeRead.1 else {
                    return .degraded(.readFailed(
                        windowID,
                        positionRead.0 != .success ? positionRead.0 : sizeRead.0))
                }
                let actual = CGRect(origin: actualPosition, size: actualSize)
                let previous = lastFrames[windowID]
                lastFrames[windowID] = actual
                // no size check: a window taller than the corner screen comes back
                // cut to its height (#54). the next show retiles it, as after a switch
                if Self.isHiddenParkedFrame(actual, on: displayFrames) {
                    // hidden isn't settled: macOS may still be moving it, so a
                    // sample only counts when it matches the one before
                    let unchanged = previous.map { Self.framesMatch($0, actual) } ?? false
                    stableSamples[windowID] = unchanged
                        ? stableSamples[windowID, default: 0] + 1 : 1
                } else {
                    stableSamples[windowID] = 0
                }
                pending = pending || stableSamples[windowID, default: 0] < 2
            }
            if !pending {
                guard isCurrent() else { return .degraded(.superseded) }
                hyprLog(.debug, .workspace, "verified position-only park: ids="
                        + "[\(windowIDs.sorted().map(String.init).joined(separator: ", "))]"
                        + " frames=\(lastFrames) hidden=true")
                return .parked
            }
            io.sleep(0.03)
        } while io.now() < deadline
        let failed = windowIDs.first { stableSamples[$0, default: 0] < 2 }
        hyprLog(.notice, .workspace, "position-only park rejected: frames=\(lastFrames) hidden=false")
        return .degraded(.geometryMismatch(failed ?? 0))
    }

    private static func framesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1
            && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }

    static func isHiddenParkedFrame(_ frame: CGRect, on displayFrames: [CGRect],
                                    maximumVisibleWidth: CGFloat = 1) -> Bool {
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else { return false }
        return !displayFrames.isEmpty && displayFrames.allSatisfy { display in
            let intersection = frame.intersection(display)
            return intersection.isNull || intersection.isEmpty
                || intersection.width <= maximumVisibleWidth
        }
    }
}
