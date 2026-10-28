// Whether a focus change has to rescan the desktop, or landed on a window
// discovery already manages.

import CoreGraphics

/// a focus change needs no discovery poll when it lands on a window the
/// walks already know, that is not hidden, and whose workspace is on screen.
/// every focus HyprMac makes itself (FFM, a switch) is such a window, and a
/// full walk per hover cost ~15% CPU. an unread or unknown focus keeps the
/// poll: some windows announce themselves only through focus. a hidden-ws
/// focus keeps it too, so park repair still sees a window pulled on screen.
enum FocusPollGate {
    static func needsPoll(focusedID: CGWindowID?,
                          known: Set<CGWindowID>,
                          hidden: Set<CGWindowID>,
                          onVisibleWorkspace: (CGWindowID) -> Bool) -> Bool {
        guard let id = focusedID else { return true }
        return !known.contains(id) || hidden.contains(id) || !onVisibleWorkspace(id)
    }
}
