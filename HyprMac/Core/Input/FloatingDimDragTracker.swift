// Keeps the dim's bright carve and the floater outline on a floater while it
// is dragged, instead of trailing behind on the discovery poll.

import Cocoa

/// What follows a floater while it is dragged. The dim's bright carve
/// follows in normal dim mode only; the scrim of an open scratchpad has no
/// carve to move. The outline follows whenever floaters are marked.
struct FloaterDragFollow: Equatable {
    var carve: Bool
    var outline: Bool

    var arms: Bool { carve || outline }

    static func resolve(dimInactive: Bool, scratchpadVisible: Bool,
                        marks: FloaterMarkStyle) -> Self {
        Self(carve: dimInactive && !scratchpadVisible, outline: marks != .none)
    }
}

final class FloatingDimDragTracker {
    // startFrame + downPointCG, both sampled at mouse-down (frame from the
    // window list, point from the event), are the fallback anchor when a
    // list read misses: the window would be at startOrigin + (cursor −
    // downPoint). never re-anchor to a frame read mid-drag — pairing an older
    // origin with a live cursor bakes the gap in as a permanent offset.
    private struct State {
        let id: CGWindowID
        let readFrame: () -> CGRect?  // the window list's frame, not AX
        let startFrame: CGRect        // CG top-left frame at mouse-down
        let baseline: CGRect          // first window list read, what a move is measured from
        let downPointCG: CGPoint      // click point from the mouse-down event
        var confirmed = false         // the window list saw the window actually moving
    }

    private var drag: State?
    private let setCarve: (CGWindowID, CGRect) -> Void
    private let setLiveFrame: (CGWindowID, CGRect) -> Void
    private let clearCarve: () -> Void

    /// `setCarve` gets the live frame grown by the dim's 2 pt carve margin,
    /// `setLiveFrame` the live frame itself, for the outline.
    init(setCarve: @escaping (CGWindowID, CGRect) -> Void,
         setLiveFrame: @escaping (CGWindowID, CGRect) -> Void = { _, _ in },
         clearCarve: @escaping () -> Void) {
        self.setCarve = setCarve
        self.setLiveFrame = setLiveFrame
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
    /// window's origin or size actually change under this press. Content drags
    /// (text selection, scrollbar, a click on a window merely overlapping this
    /// floater's frame) never move the window, so they never confirm and the
    /// cursor can't pull the carve off a stationary window.
    ///
    /// Once confirmed, every event reads the window list: one window, about a
    /// tenth of a millisecond. Not AX, which reports a dragged window's move
    /// about 100 ms late (measured on macOS 27). Not the cursor delta alone:
    /// the window server holds a dragged window under the menu bar and above
    /// the Dock, and an app that drags its own window lags the cursor, so
    /// the delta ran ahead of the window there. A resize needs the list too.
    /// The delta off the mouse-down pair stands in when a read misses.
    func update(cursorCG: CGPoint) {
        guard var drag else { return }
        let frame = drag.readFrame()

        if !drag.confirmed, let frame {
            let base = drag.baseline
            // 3px guard: a stationary window never false-confirms
            if abs(frame.width - base.width) > 2 || abs(frame.height - base.height) > 2
                || hypot(frame.minX - base.minX, frame.minY - base.minY) > 3 {
                drag.confirmed = true
            }
        }
        self.drag = drag
        // window hasn't moved: the carve stays where the last full update
        // painted it (on the window). nothing to stamp.
        guard drag.confirmed else { return }

        let liveRect = frame ?? drag.startFrame.offsetBy(dx: cursorCG.x - drag.downPointCG.x,
                                                         dy: cursorCG.y - drag.downPointCG.y)
        // match floatingFrames(expandedBy: 2): negative inset enlarges
        setCarve(drag.id, liveRect.insetBy(dx: -2, dy: -2))
        setLiveFrame(drag.id, liveRect)
    }
}
