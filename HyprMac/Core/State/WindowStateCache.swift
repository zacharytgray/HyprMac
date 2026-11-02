// Single source of truth for window-keyed lifecycle and classification state.
// Holds the dicts that orchestration code reads on every focus, drag,
// tile, and discovery cycle.

import Cocoa

/// Window-keyed state cache shared across the orchestration layer.
///
/// Owns the dicts that classify a window's lifecycle (known? hidden?
/// gone?), behavior (floating?), and last-known geometry. Other subsystems
/// hold a reference to this cache and read and write its stores directly,
/// on the main thread. `forget` is the only method.
///
/// What lives here:
/// - `knownWindowIDs` — windows present in the last full cycle
/// - `floatingWindowIDs` — windows excluded from tiling
/// - `originalFrames` — pre-tile frames captured for float-toggle restore
/// - `windowOwners` — `wid → pid`, used to distinguish closed-vs-hidden
/// - `hiddenWindowIDs` — windows whose AX element is gone but pid is alive
/// - `reservedHiddenWindowIDs` — hidden windows that still hold a tile slot
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

    /// `HyprWindow` snapshots keyed by window ID. Written by
    /// `WindowManager.updatePositionCache`, which keeps only visible windows,
    /// and by classification, floating and workspace paths. Read by FFM, drag
    /// detection, focus-border refresh, and the floater raise path.
    var cachedWindows: [CGWindowID: HyprWindow] = [:]

    /// Last read frames of visible non-floating windows, keyed by window ID.
    /// Not the layout's intent, and it can include newcomers not yet in a
    /// tree. Drag detection compares
    /// the mouseDown frame against these to classify drag-vs-resize; FFM
    /// uses them as hit rects to match windows without an AX poll.
    var tiledPositions: [CGWindowID: CGRect] = [:]

    /// Windows whose owning app is alive but whose `AXUIElement` is gone
    /// (minimized, hidden, on another macOS Space, or closed while the app
    /// runs). Kept out of tiling so
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

    /// Windows excluded from tiling. User-toggled via `Hypr+T` or
    /// auto-floated by depth, min-size, or excluded-app rules.
    var floatingWindowIDs: Set<CGWindowID> = []

    /// Subset of `hiddenWindowIDs` that can return on their own
    /// (minimized, app hidden via Cmd-H, still listed by the app because
    /// it sits on another Space or in full-screen, or AX unreadable when
    /// they vanished). These keep their workspace slot reserved;
    /// verified-closed windows do not.
    var reservedHiddenWindowIDs: Set<CGWindowID> = []

    /// Windows present in the last full cycle. Populated by discovery, pruned
    /// by `forget` and when a window hides. The returned pass re-adds a hidden
    /// window before the new pass looks, so it does not re-enter as "new".
    var knownWindowIDs: Set<CGWindowID> = []

    /// Remove `id` from every tracked dict. Used when a window is
    /// permanently gone (closed, app exited).
    func forget(_ id: CGWindowID) {
        cachedWindows.removeValue(forKey: id)
        tiledPositions.removeValue(forKey: id)
        hiddenWindowIDs.remove(id)
        reservedHiddenWindowIDs.remove(id)
        originalFrames.removeValue(forKey: id)
        windowOwners.removeValue(forKey: id)
        floatingWindowIDs.remove(id)
        knownWindowIDs.remove(id)
    }
}
