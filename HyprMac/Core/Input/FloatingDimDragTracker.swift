// Keeps the dim's bright carve on a floater while it is dragged, instead of
// trailing behind on the discovery poll.

import Cocoa

final class FloatingDimDragTracker {
    // startFrame + downPointCG are the tracking anchor and MUST be a
    // consistent pair, both sampled at mouse-down (frame from the
    // mouse-down enumeration, point from the event). during a title-bar
    // drag the OS keeps windowOrigin == startOrigin + (cursor − downPoint)
    // exactly, so delta math off this pair is lag-free. never re-anchor
    // to a frame read mid-drag — pairing an older origin with a live cursor
    // bakes the gap in as a permanent carve offset for the rest of the drag.
    private struct State {
        let id: CGWindowID
        let readFrame: () -> CGRect?  // the window list's frame, not AX
        let startFrame: CGRect        // CG top-left frame at mouse-down
        let baseline: CGRect          // first window list read, what a move is measured from
        let downPointCG: CGPoint      // click point from the mouse-down event
        var confirmed = false         // the window list saw the window actually moving
        var resizing = false         // classified as a resize → track the live frame
        var lastSizeCheck: TimeInterval = 0
    }

    private var drag: State?
    private let now: () -> TimeInterval
    private let setCarve: (CGWindowID, CGRect) -> Void
    private let clearCarve: () -> Void

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         setCarve: @escaping (CGWindowID, CGRect) -> Void,
         clearCarve: @escaping () -> Void) {
        self.now = now
        self.setCarve = setCarve
        self.clearCarve = clearCarve
    }

    var isArmed: Bool { drag != nil }

    func arm(id: CGWindowID, readFrame: @escaping () -> CGRect?,
             startFrame: CGRect, downPointCG: CGPoint) {
        drag = State(id: id, readFrame: readFrame, startFrame: startFrame,
                     baseline: readFrame() ?? startFrame, downPointCG: downPointCG)
    }

    /// Forget the press. The carve override stays with the overlay.
    func disarm() {
        drag = nil
    }

    /// Mouse-up, or teardown mid-drag: drop the override too, or a stale carve
    /// hole survives until the next full update.
    func finish() {
        drag = nil
        clearCarve()
    }

    /// Push the live carve rect for the armed floater.
    ///
    /// Confirmation gate: the carve holds still until the window list sees the
    /// window's origin actually moving under this press. Content drags (text
    /// selection, scrollbar, a click on a window merely overlapping this
    /// floater's frame) never move the window, so they never confirm and the
    /// cursor can't pull the carve off a stationary window.
    ///
    /// The window list, because AX reports a dragged window's move about 100 ms
    /// late (measured on macOS 27). On a fast drag that left the carve well
    /// behind the window until AX caught up.
    ///
    /// Once confirmed, tracking is pure delta math off the mouse-down anchor
    /// pair (`startFrame` + `downPointCG`), not the frame that confirmed. A
    /// throttled size check flips to live-frame reads once a resize is detected
    /// (delta math can't model resizes).
    func update(cursorCG: CGPoint) {
        guard var drag else { return }

        // size is checked with the origin: a left/top-edge resize moves the
        // origin too and would otherwise confirm as a move and delta-track
        // with a frozen size. after confirming, ~10Hz is enough.
        if !drag.resizing, !drag.confirmed || now() - drag.lastSizeCheck > 0.1 {
            drag.lastSizeCheck = now()
            if let frame = drag.readFrame() {
                let base = drag.baseline
                if abs(frame.width - base.width) > 2 || abs(frame.height - base.height) > 2 {
                    drag.resizing = true
                    drag.confirmed = true
                } else if hypot(frame.minX - base.minX, frame.minY - base.minY) > 3 {
                    // 3px guard: a stationary window never false-confirms
                    drag.confirmed = true
                }
            }
        }

        guard drag.confirmed else {
            // window hasn't moved: the carve stays where the last full
            // update painted it (on the window). nothing to stamp.
            self.drag = drag
            return
        }

        let liveRect: CGRect
        if drag.resizing {
            liveRect = drag.readFrame() ?? drag.startFrame
        } else {
            liveRect = drag.startFrame.offsetBy(dx: cursorCG.x - drag.downPointCG.x,
                                                dy: cursorCG.y - drag.downPointCG.y)
        }
        self.drag = drag
        // match floatingFrames(expandedBy: 2): negative inset enlarges
        setCarve(drag.id, liveRect.insetBy(dx: -2, dy: -2))
    }
}
