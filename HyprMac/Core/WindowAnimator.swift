import Cocoa

class WindowAnimator {
    private(set) var isAnimating = false
    private var timer: DispatchSourceTimer?

    struct FrameTransition {
        let window: HyprWindow
        let from: CGRect
        let to: CGRect
    }

    // animate windows from current to target positions.
    // during interpolation uses position+size (2 IPC calls) instead of
    // resize-move-resize (3 calls) since same-screen swaps don't need the clamp.
    // final frame uses setFrame() for correctness.
    func animate(_ transitions: [FrameTransition], duration: TimeInterval, completion: @escaping () -> Void) {
        guard !transitions.isEmpty else { completion(); return }

        cancelAndSnap()

        isAnimating = true
        let start = CACurrentMediaTime()
        let queue = DispatchQueue.main

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        self.timer = timer

        timer.setEventHandler { [weak self] in
            guard let self else { return }

            let elapsed = CACurrentMediaTime() - start
            let progress = min(elapsed / duration, 1.0)
            let t = Self.easeOutCubic(progress)

            for tr in transitions {
                let x = tr.from.origin.x + (tr.to.origin.x - tr.from.origin.x) * t
                let y = tr.from.origin.y + (tr.to.origin.y - tr.from.origin.y) * t
                let w = tr.from.width + (tr.to.width - tr.from.width) * t
                let h = tr.from.height + (tr.to.height - tr.from.height) * t

                if progress >= 1.0 {
                    // final frame — use full setFrame for correctness
                    tr.window.setFrame(tr.to)
                } else {
                    // intermediate — skip resize-move-resize, just set directly
                    tr.window.size = CGSize(width: w, height: h)
                    tr.window.position = CGPoint(x: x, y: y)
                }
            }

            if progress >= 1.0 {
                self.finish()
                completion()
            }
        }

        timer.resume()
    }

    // immediately snap all in-flight windows to final positions
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
