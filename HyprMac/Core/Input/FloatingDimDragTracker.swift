// Keeps the dim's bright carve on a floater while it is dragged, instead of
// trailing behind on the discovery poll.

import Cocoa

final class FloatingDimDragTracker {
    /// The window's live values. A title-bar drag only ever reads `position`,
    /// and only until the move is confirmed.
    struct Probe {
        let size: () -> CGSize?
        let position: () -> CGPoint?
        let frame: () -> CGRect?
    }

    // startFrame + downPointCG are the tracking anchor and MUST be a
    // consistent pair, both sampled at mouse-down (frame from the
    // mouse-down enumeration, point from the event). during a title-bar
    // drag the OS keeps windowOrigin == startOrigin + (cursor − downPoint)
    // exactly, so delta math off this pair is lag-free. never re-anchor
    // to an AX position read mid-drag — those lag a fast drag, and pairing
    // a stale origin with a live cursor bakes the lag in as a permanent
    // carve offset for the rest of the drag.
    private struct State {
        let id: CGWindowID
        let probe: Probe
        let startFrame: CGRect       // CG top-left frame at mouse-down
        let downPointCG: CGPoint     // click point from the mouse-down event
        var confirmed = false        // an AX read saw the window actually moving
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

    func arm(id: CGWindowID, probe: Probe, startFrame: CGRect, downPointCG: CGPoint) {
        drag = State(id: id, probe: probe, startFrame: startFrame, downPointCG: downPointCG)
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
    /// Confirmation gate: the carve holds still until an AX read sees the
    /// window's origin actually moving under this press. Content drags (text
    /// selection, scrollbar, a click on a window merely overlapping this
    /// floater's frame) never move the window, so they never confirm and the
    /// cursor can't pull the carve off a stationary window.
    ///
    /// Once confirmed, tracking is pure delta math off the MOUSE-DOWN anchor
    /// pair (`startFrame` + `downPointCG`) — not the position that confirmed.
    /// The confirming AX read lags a fast drag; the down-event pair is exact,
    /// so the carve lands on the window's true position regardless of how far
    /// the flick outran AX. No AX reads remain in the confirmed-move hot path.
    /// A throttled size probe flips to live-frame reads once a resize is
    /// detected (delta math can't model resizes).
    func update(cursorCG: CGPoint) {
        guard var drag else { return }

        // resize probe (~10Hz) runs confirmed or not: a left/top-edge resize
        // moves the origin too and would otherwise confirm as a move and
        // delta-track with a frozen size.
        if !drag.resizing {
            let time = now()
            if time - drag.lastSizeCheck > 0.1 {
                drag.lastSizeCheck = time
                if let sz = drag.probe.size(),
                   abs(sz.width - drag.startFrame.width) > 2 ||
                   abs(sz.height - drag.startFrame.height) > 2 {
                    drag.resizing = true
                    drag.confirmed = true
                }
            }
        }

        if !drag.confirmed {
            // per-event position probe until confirmed — a real drag confirms
            // within the first couple events, a content drag keeps the carve
            // parked. 3px guard clears AX position noise so a stationary
            // window never false-confirms.
            if let pos = drag.probe.position(),
               hypot(pos.x - drag.startFrame.origin.x, pos.y - drag.startFrame.origin.y) > 3 {
                drag.confirmed = true
            } else {
                // window hasn't moved: the carve stays where the last full
                // update painted it (on the window). nothing to stamp.
                self.drag = drag
                return
            }
        }

        let liveRect: CGRect
        if drag.resizing {
            liveRect = drag.probe.frame() ?? drag.startFrame
        } else {
            liveRect = drag.startFrame.offsetBy(dx: cursorCG.x - drag.downPointCG.x,
                                                dy: cursorCG.y - drag.downPointCG.y)
        }
        self.drag = drag
        // match floatingFrames(expandedBy: 2): negative inset enlarges
        setCarve(drag.id, liveRect.insetBy(dx: -2, dy: -2))
    }
}
