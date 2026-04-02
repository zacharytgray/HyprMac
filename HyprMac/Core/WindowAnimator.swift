import Cocoa

class WindowAnimator {
    private(set) var isAnimating = false
    private var timer: DispatchSourceTimer?

    struct FrameTransition {
        let window: HyprWindow
        let from: CGRect
        let to: CGRect
        // precompute whether this window actually needs to resize
        var needsResize: Bool { abs(from.width - to.width) > 1 || abs(from.height - to.height) > 1 }
    }

    // animate windows with smooth position + deferred progressive resize.
    // position interpolates across all frames (smooth movement, no re-render).
    // size interpolates across the last ~40% of frames so the resize happens
    // during motion (perceptually masked) rather than as a single snap at the end.
    func animate(_ transitions: [FrameTransition], duration: TimeInterval, completion: @escaping () -> Void) {
        guard !transitions.isEmpty else { completion(); return }

        cancelAndSnap()

        isAnimating = true
        let start = CACurrentMediaTime()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        self.timer = timer

        timer.setEventHandler { [weak self] in
            guard let self else { return }

            let elapsed = CACurrentMediaTime() - start
            let progress = min(elapsed / duration, 1.0)

            // position: easeOutCubic across full duration (fast start, gentle landing)
            let posT = Self.easeOutCubic(progress)

            // size: linear ramp starting at 60% progress. this spreads the resize
            // across ~4 frames while the window is still visibly moving, so the eye
            // tracks motion rather than focusing on the size change.
            let sizeT = CGFloat(max(0.0, (progress - 0.6) / 0.4))

            if progress >= 1.0 {
                // final frame — full setFrame for correctness (resize-move-resize pattern)
                for tr in transitions {
                    tr.window.setFrame(tr.to)
                }
                self.finish()
                completion()
            } else {
                for tr in transitions {
                    let vx = tr.from.origin.x + (tr.to.origin.x - tr.from.origin.x) * posT
                    let vy = tr.from.origin.y + (tr.to.origin.y - tr.from.origin.y) * posT

                    // always set position — smooth, doesn't trigger content re-render
                    tr.window.position = CGPoint(x: vx, y: vy)

                    // only set size when needed and after the delay threshold
                    if sizeT > 0 && tr.needsResize {
                        let vw = tr.from.width + (tr.to.width - tr.from.width) * sizeT
                        let vh = tr.from.height + (tr.to.height - tr.from.height) * sizeT
                        tr.window.size = CGSize(width: vw, height: vh)
                    }
                }
            }
        }

        timer.resume()
    }

    // cancel in-flight animation
    func cancelAndSnap() {
        timer?.cancel()
        timer = nil
        isAnimating = false
    }

    private func finish() {
        timer?.cancel()
        timer = nil
        isAnimating = false
    }

    // ease-out cubic — fast start, gentle landing
    private static func easeOutCubic(_ t: Double) -> CGFloat {
        CGFloat(1.0 - pow(1.0 - t, 3))
    }
}
