import Cocoa

// canonical focus state. owns the "last window we wanted focused" id that was
// previously scattered between WindowManager (writes) and MouseTrackingManager
// (reads + FFM internal writes).
//
// per §3.3 of the refactor plan, this is where focusedWindowID, borderTrackedID,
// and mouseFocusedID live together. in this Phase 2 step the storage migration
// covers mouseFocusedID (formerly mouseTracker.lastMouseFocusedID).
// borderTrackedID stays inside FocusBorder (already private(set), only writable
// via show/hide); the controller exposes it as a passthrough getter.
//
// every focus-id transition logs at .debug under .focus category, so the
// transition history is grep-able from Console.app for support sessions.
//
// main-thread is a precondition. no synchronization beyond that.
final class FocusStateController {
    let focusBorder: FocusBorder

    // last window we asked to be focused (programmatic focus or FFM).
    // 0 means "no specific intent" — used as a sentinel when initial state
    // hasn't been established or focus was explicitly cleared.
    private(set) var lastFocusedID: CGWindowID = 0

    // passthrough — FocusBorder owns the panel lifecycle and the trackedWindowID
    // is set as a side effect of show/hide. exposed here so callers don't need
    // to know about FocusBorder directly.
    var borderTrackedID: CGWindowID? { focusBorder.trackedWindowID }

    init(focusBorder: FocusBorder) {
        self.focusBorder = focusBorder
    }

    // record focus intent. no AX call, no border side effect — just updates the
    // canonical id and logs the transition. callers do the AX/border work
    // themselves and call recordFocus afterward (matches existing pattern of
    // "focus the window then record the intent").
    func recordFocus(_ id: CGWindowID, reason: String) {
        guard lastFocusedID != id else { return }
        let prev = lastFocusedID
        lastFocusedID = id
        hyprLog(.debug, .focus, "focus \(prev) → \(id) (\(reason))")
    }
}
