// Canonical focus state. Holds the last-focused window id and exposes the
// border tracking id through `FocusBorder`, so the rest of the codebase
// reads "what should have keyboard focus" from one place.

import Cocoa

/// Canonical focus state shared across orchestration code.
///
/// Owns the last-focus intent — the id of the window most recently asked
/// to be focused, whether by programmatic action or FFM. The focus border
/// itself owns its tracked id (set as a side effect of `show`/`hide`);
/// this controller exposes that as a pass-through getter so callers do
/// not have to know about `FocusBorder` directly.
///
/// Every transition is logged at `.debug` under the `.focus` category, so
/// the focus history is greppable from Console.
///
/// Threading: main-thread only. No synchronization.
final class FocusStateController {
    let focusBorder: FocusBorder

    /// ID of the window most recently asked to be focused (programmatic
    /// focus or FFM). `0` means "no specific intent" — used as a sentinel
    /// before initial state is established or after focus is cleared.
    private(set) var lastFocusedID: CGWindowID = 0
    private(set) var generation: UInt64 = 0

    /// Pass-through to `FocusBorder.trackedWindowID`. Lets callers read
    /// the bordered window without depending on `FocusBorder` directly.
    var borderTrackedID: CGWindowID? { focusBorder.trackedWindowID }

    /// Fired after every focus transition (the status bar export listens).
    var onChange: () -> Void = {}

    init(focusBorder: FocusBorder) {
        self.focusBorder = focusBorder
    }

    /// Record `id` as the new focus intent and log the transition.
    ///
    /// No-op when the id is already current. Does not call AX or touch
    /// the border. Callers going through `TiledFocusRouter` must record first:
    /// its verify compares the focus generation it captured inside `focus`.
    ///
    /// - Parameter reason: short tag for the log line (e.g.
    ///   `"ensureFocus-tiled"`, `"syncTracker-floating"`). Surfaces in
    ///   Console under category `.focus`.
    func recordFocus(_ id: CGWindowID, reason: String) {
        guard lastFocusedID != id else { return }
        let prev = lastFocusedID
        lastFocusedID = id
        generation &+= 1
        hyprLog(.debug, .focus, "focus \(prev) → \(id) (\(reason))")
        onChange()
    }
}
