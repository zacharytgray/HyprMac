// Focus for a HyprMac-initiated focus change: hover, Hypr+Arrow, a bare Hypr
// press, the focus invariant. The focused window sits above a floater wherever
// they overlap, and a floater goes back on top once focus leaves. Raising the
// floater first means it never pops over the window taking focus.

import Cocoa

/// Gives a window keyboard focus and keeps floaters in the agreed order.
///
/// Threading: main-thread only.
final class TiledFocusRouter {
    /// What the focus does for this caller. Hover focus adds the synthetic
    /// title-bar click Tahoe needs from a mouse-move context.
    enum Fallback: String {
        case activate
        case activateAndClick = "activate+click"
    }

    var usualFocus: (HyprWindow, Fallback) -> Void = { window, fallback in
        window.focusWithoutRaise()
        if fallback == .activateAndClick { window.focusViaSyntheticClick() }
    }
    /// told before every focus, so the app activation it may cause is
    /// known to be HyprMac's and not the user's
    var noteActivation: (pid_t) -> Void = { _ in }
    /// puts back on top any floater a tile other than `target` covers
    var raiseFloatersBeforeFocus: (HyprWindow) -> Void = { _ in }

    func focus(_ target: HyprWindow, reason: String, fallback: Fallback) {
        hyprLog(.debug, .focus, "router focus: wid=\(target.windowID) reason=\(reason)")
        noteActivation(target.ownerPID)
        raiseFloatersBeforeFocus(target)
        usualFocus(target, fallback)
    }
}
