import Cocoa

struct WindowMove {
    let window: HyprWindow
    let from: CGRect
    let to: CGRect
}

struct WindowMoveAnimation: Equatable {
    var duration: TimeInterval
    var style: WindowAnimationStyle

    init(duration: TimeInterval, style: WindowAnimationStyle) {
        self.duration = duration
        self.style = style
    }

    init(config: UserConfig) {
        self.init(duration: TimeInterval(UserConfig.clampedAnimationDuration(config.windowAnimationDurationMs)) / 1000,
                  style: config.windowAnimationStyle)
    }
}

enum WindowMoveAnimator {
    static let frameInterval: TimeInterval = 1.0 / 60.0

    static func eased(_ progress: Double, style: WindowAnimationStyle = .smooth) -> Double {
        let t = min(max(progress, 0), 1)
        switch style {
        case .smooth: return 1 - pow(1 - t, 3)
        case .snappy: return 1 - pow(1 - t, 5)
        case .gentle: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .linear: return t
        }
    }

    static func frame(from: CGRect, to: CGRect, progress: Double,
                      style: WindowAnimationStyle = .smooth) -> CGRect {
        let p = CGFloat(eased(progress, style: style))
        return CGRect(x: from.minX + (to.minX - from.minX) * p,
                      y: from.minY + (to.minY - from.minY) * p,
                      width: from.width + (to.width - from.width) * p,
                      height: from.height + (to.height - from.height) * p)
    }

    static func run(_ moves: [WindowMove], animation: WindowMoveAnimation) {
        let duration = animation.duration
        guard !moves.isEmpty, duration > 0,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        guarded(moves[...]) {
            let start = CFAbsoluteTimeGetCurrent()
            while true {
                let progress = (CFAbsoluteTimeGetCurrent() - start) / duration
                if progress >= 1 { break }
                let tickStart = CFAbsoluteTimeGetCurrent()
                for move in moves {
                    move.window.animationStep(to: frame(from: move.from, to: move.to, progress: progress,
                                                               style: animation.style))
                }
                let spent = CFAbsoluteTimeGetCurrent() - tickStart
                if spent < frameInterval { usleep(useconds_t((frameInterval - spent) * 1_000_000)) }
            }
        }
    }

    private static func guarded(_ moves: ArraySlice<WindowMove>, _ body: () -> Void) {
        guard let first = moves.first else { body(); return }
        first.window.withEnhancedUIDisabled { guarded(moves.dropFirst(), body) }
    }
}
