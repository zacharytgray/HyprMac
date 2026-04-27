import Cocoa

class WindowAnimator {
    private(set) var isAnimating = false
    private var timer: DispatchSourceTimer?
    private var activeProxies: [ProxyWindow] = []
    // stash transitions so cancelAndSnap can finalize
    private var activeTransitions: [FrameTransition] = []

    struct FrameTransition {
        let window: HyprWindow
        let from: CGRect
        let to: CGRect
        var needsResize: Bool { abs(from.width - to.width) > 1 || abs(from.height - to.height) > 1 }
    }

    func animate(_ transitions: [FrameTransition], duration: TimeInterval, completion: @escaping () -> Void) {
        mainThreadOnly()
        guard !transitions.isEmpty else { completion(); return }
        cancelAndSnap()

        // proxy path — animate screenshot overlays, no app re-renders
        if let proxies = createProxies(for: transitions) {
            animateWithProxies(transitions, proxies: proxies, duration: duration, completion: completion)
        } else {
            animateWithAX(transitions, duration: duration, completion: completion)
        }
    }

    func cancelAndSnap() {
        mainThreadOnly()
        timer?.cancel()
        timer = nil
        for proxy in activeProxies { proxy.close() }
        activeProxies.removeAll()
        for tr in activeTransitions { tr.window.setFrame(tr.to) }
        activeTransitions.removeAll()
        isAnimating = false
    }

    // MARK: - proxy animation (screenshot overlay, no app re-renders)

    // borderless overlay showing a captured screenshot.
    // animating its frame is cheap — just GPU image scaling, no app re-render.
    private class ProxyWindow {
        let window: NSWindow

        init?(captureWindowID: CGWindowID, frame: CGRect, primaryScreenHeight: CGFloat) {
            guard let image = CGWindowListCreateImage(
                .null, .optionIncludingWindow, captureWindowID,
                [.boundsIgnoreFraming, .bestResolution]
            ) else { return nil }

            // CG (top-left) -> NS (bottom-left)
            let nsFrame = NSRect(
                x: frame.origin.x,
                y: primaryScreenHeight - frame.origin.y - frame.height,
                width: frame.width, height: frame.height
            )

            let win = NSWindow(contentRect: nsFrame, styleMask: .borderless, backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false  // ARC manages lifetime, not close()
            win.isOpaque = true
            win.backgroundColor = .black
            win.level = .statusBar
            win.ignoresMouseEvents = true
            // proxy carries a system shadow so the moving content looks like a
            // real window. real window is parked off-screen during animation
            // (see animateWithProxies) so its shadow doesn't trail at the
            // source position.
            win.hasShadow = true
            win.animationBehavior = .none

            let iv = NSImageView(frame: NSRect(origin: .zero, size: nsFrame.size))
            iv.image = NSImage(cgImage: image, size: nsFrame.size)
            iv.imageScaling = .scaleAxesIndependently
            iv.autoresizingMask = [.width, .height]
            win.contentView = iv

            self.window = win
        }

        func setVisualFrame(_ cgRect: CGRect, primaryScreenHeight: CGFloat) {
            let nsFrame = NSRect(
                x: cgRect.origin.x,
                y: primaryScreenHeight - cgRect.origin.y - cgRect.height,
                width: cgRect.width, height: cgRect.height
            )
            window.setFrame(nsFrame, display: false, animate: false)
        }

        func show() { window.orderFront(nil) }
        func close() { window.close() }
    }

    private func createProxies(for transitions: [FrameTransition]) -> [ProxyWindow]? {
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        var proxies: [ProxyWindow] = []

        for tr in transitions {
            guard let proxy = ProxyWindow(
                captureWindowID: tr.window.windowID,
                frame: tr.from,
                primaryScreenHeight: screenH
            ) else {
                proxies.forEach { $0.close() }
                return nil
            }
            proxies.append(proxy)
        }
        return proxies
    }

    // far enough off-screen that the parked window's shadow can't bleed
    // back onto any monitor in any reasonable multi-display setup.
    private static let proxyParkPosition = CGPoint(x: -50_000, y: -50_000)

    private func animateWithProxies(_ transitions: [FrameTransition], proxies: [ProxyWindow],
                                    duration: TimeInterval, completion: @escaping () -> Void) {
        isAnimating = true
        activeProxies = proxies
        activeTransitions = transitions
        let screenH = NSScreen.screens.first?.frame.height ?? 0

        // show proxies covering real windows at `from`. ordering matters:
        // the proxy must be visible BEFORE we park the real window, so the
        // off-screen AX move below is visually masked.
        for proxy in proxies { proxy.show() }

        // park real windows off-screen so their system shadows don't trail
        // at `from` while the proxy slides. position-only write — size stays,
        // so when we restore to `to` at the end we don't need a full
        // resize-move-resize cycle (just position back to to.origin).
        for tr in transitions { tr.window.position = Self.proxyParkPosition }

        let start = CACurrentMediaTime()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        self.timer = timer

        timer.setEventHandler { [weak self] in
            guard let self else { return }

            let elapsed = CACurrentMediaTime() - start
            let progress = min(elapsed / duration, 1.0)
            let t = Self.easeOutCubic(progress)

            if progress >= 1.0 {
                // restore real windows BEFORE closing proxies. the proxy
                // sits at `to` at this point, so the AX restore is hidden
                // behind it; closing first would briefly expose the parked
                // (off-screen → empty) area before setFrame completes.
                for tr in transitions { tr.window.setFrame(tr.to) }
                for proxy in proxies { proxy.close() }
                self.activeProxies.removeAll()
                self.activeTransitions.removeAll()
                self.finish()
                completion()
            } else {
                for (i, proxy) in proxies.enumerated() {
                    let tr = transitions[i]
                    let vx = tr.from.origin.x + (tr.to.origin.x - tr.from.origin.x) * t
                    let vy = tr.from.origin.y + (tr.to.origin.y - tr.from.origin.y) * t
                    let vw = tr.from.width + (tr.to.width - tr.from.width) * t
                    let vh = tr.from.height + (tr.to.height - tr.from.height) * t
                    proxy.setVisualFrame(CGRect(x: vx, y: vy, width: vw, height: vh), primaryScreenHeight: screenH)
                }
            }
        }

        timer.resume()
    }

    // MARK: - AX animation fallback (original approach)

    // position interpolation with deferred progressive resize.
    // used when proxy creation fails (e.g. no Screen Recording permission).
    private func animateWithAX(_ transitions: [FrameTransition], duration: TimeInterval, completion: @escaping () -> Void) {
        isAnimating = true
        activeTransitions = transitions
        let start = CACurrentMediaTime()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        self.timer = timer

        timer.setEventHandler { [weak self] in
            guard let self else { return }

            let elapsed = CACurrentMediaTime() - start
            let progress = min(elapsed / duration, 1.0)

            // position: easeOutCubic across full duration
            let posT = Self.easeOutCubic(progress)

            // size: linear ramp starting at 60% progress
            let sizeT = CGFloat(max(0.0, (progress - 0.6) / 0.4))

            if progress >= 1.0 {
                for tr in transitions {
                    tr.window.setFrame(tr.to)
                }
                self.activeTransitions.removeAll()
                self.finish()
                completion()
            } else {
                for tr in transitions {
                    let vx = tr.from.origin.x + (tr.to.origin.x - tr.from.origin.x) * posT
                    let vy = tr.from.origin.y + (tr.to.origin.y - tr.from.origin.y) * posT
                    tr.window.position = CGPoint(x: vx, y: vy)

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

    private func finish() {
        timer?.cancel()
        timer = nil
        isAnimating = false
    }

    private static func easeOutCubic(_ t: Double) -> CGFloat {
        CGFloat(1.0 - pow(1.0 - t, 3))
    }
}
