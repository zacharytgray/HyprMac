// How the window an action applies to gets chosen. Pure, apart from the AX read
// in `axFocused`, which only runs when the cached candidates fail.

import CoreGraphics

enum FocusResolution {
    enum Source: Equatable {
        case border, lastFocused, accessibility, scratchpadMember
    }

    struct Resolved {
        let source: Source
        let window: HyprWindow
    }

    /// Border, then last focused, then the AX focused window, then the
    /// scratchpad's most recent member. Each must be selectable right now,
    /// except the member, which the layer already vouches for.
    static func resolve(borderID: CGWindowID?,
                        lastFocusedID: CGWindowID,
                        isSelectable: (CGWindowID) -> Bool,
                        cachedWindow: (CGWindowID) -> HyprWindow?,
                        axFocused: () -> HyprWindow?,
                        scratchpadMember: () -> HyprWindow?) -> Resolved? {
        if let borderID, isSelectable(borderID), let window = cachedWindow(borderID) {
            return Resolved(source: .border, window: window)
        }
        if lastFocusedID != 0, isSelectable(lastFocusedID), let window = cachedWindow(lastFocusedID) {
            return Resolved(source: .lastFocused, window: window)
        }
        if let focused = axFocused(), isSelectable(focused.windowID) {
            return Resolved(source: .accessibility, window: focused)
        }
        if let member = scratchpadMember() {
            return Resolved(source: .scratchpadMember, window: member)
        }
        return nil
    }

    /// `true` when `windowID` is a valid focus target right now. While the
    /// scratchpad is up only its summoned members are, tiled within the layer
    /// or floating; the workspace under the scrim is out. Otherwise: assigned
    /// to the cursor's workspace, or a visible floating window.
    static func isSelectable(_ windowID: CGWindowID,
                             scratchpadVisible: Bool,
                             isSummoned: (CGWindowID) -> Bool,
                             workspaceWindows: Set<CGWindowID>,
                             floatingWindowIDs: Set<CGWindowID>,
                             isWindowVisible: (CGWindowID) -> Bool) -> Bool {
        if scratchpadVisible { return isSummoned(windowID) }
        if workspaceWindows.contains(windowID) { return true }
        return floatingWindowIDs.contains(windowID) && isWindowVisible(windowID)
    }
}
