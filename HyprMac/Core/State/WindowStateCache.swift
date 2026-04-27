// Single source of truth for window-keyed lifecycle and classification state.
// Holds the seven dicts that orchestration code reads on every focus, drag,
// tile, and discovery cycle.

import Cocoa

/// Window-keyed state cache shared across the orchestration layer.
///
/// Owns the dicts that classify a window's lifecycle (known? hidden?
/// gone?), behavior (floating?), and last-known geometry. Other subsystems
/// hold a reference to this cache and read it directly; mutation goes
/// through the cache as well, so each dict has exactly one owner.
///
/// What lives here:
/// - `knownWindowIDs` — every window seen since launch
/// - `floatingWindowIDs` — windows excluded from tiling
/// - `originalFrames` — pre-tile frames captured for float-toggle restore
/// - `windowOwners` — `wid → pid`, used to distinguish closed-vs-hidden
/// - `hiddenWindowIDs` — windows whose AX element is gone but pid is alive
/// - `tiledPositions` — expected tiled frames (drag detection, FFM)
/// - `cachedWindows` — last poll's `HyprWindow` snapshots
///
/// What does not live here: workspace assignment (in `WorkspaceManager`),
/// BSP membership and per-window min sizes (in `TilingEngine` /
/// `MinSizeMemory`), pending-insert IDs (in `TilingEngine`), floating
/// border panels (in `FocusBorder`).
///
/// Threading: main-thread only. No synchronization.
final class WindowStateCache {

    /// Last poll's `HyprWindow` snapshots, keyed by window ID. Populated
    /// by `WindowDiscoveryService`'s apply-loop and read by FFM, drag
    /// detection, focus-border refresh, and the floater raise path.
    var cachedWindows: [CGWindowID: HyprWindow] = [:]

    /// Expected tiled frames keyed by window ID. Drag detection compares
    /// the mouseDown frame against these to classify drag-vs-resize; FFM
    /// uses them as hit rects to match windows without an AX poll.
    var tiledPositions: [CGWindowID: CGRect] = [:]

    /// Windows whose owning app is alive but whose `AXUIElement` is gone
    /// (minimized, hidden, on another macOS Space). Kept out of tiling so
    /// the tree does not try to re-insert them; the rest of their state
    /// is retained so they can re-tile cleanly when they return.
    var hiddenWindowIDs: Set<CGWindowID> = []

    /// Pre-tile frames captured the first time each window is seen. Used
    /// to restore the user-chosen size on float-toggle and on workspace
    /// eviction (when a window leaves the BSP tree, it pops back to this
    /// frame).
    var originalFrames: [CGWindowID: CGRect] = [:]

    /// Window ID → owning process ID. Used to distinguish "window closed"
    /// from "app still running but window hid": if the pid is alive when
    /// the window disappears, mark hidden and keep state; if dead, forget.
    var windowOwners: [CGWindowID: pid_t] = [:]

    /// Windows excluded from tiling. User-toggled via `Hypr+Shift+T` or
    /// auto-floated by depth, min-size, or excluded-app rules. BSP
    /// membership is computed; floating membership is the negation.
    var floatingWindowIDs: Set<CGWindowID> = []

    /// Every window ID seen since launch. Populated by discovery, pruned
    /// by `forget`. Hidden windows stay in the set so they do not
    /// re-enter as "new" when the user un-hides them — without this, the
    /// returning window would be reassigned to a different workspace.
    var knownWindowIDs: Set<CGWindowID> = []

    /// Remove `id` from every tracked dict. Used when a window is
    /// permanently gone (closed, app exited).
    func forget(_ id: CGWindowID) {
        cachedWindows.removeValue(forKey: id)
        tiledPositions.removeValue(forKey: id)
        hiddenWindowIDs.remove(id)
        originalFrames.removeValue(forKey: id)
        windowOwners.removeValue(forKey: id)
        floatingWindowIDs.remove(id)
        knownWindowIDs.remove(id)
    }
}
