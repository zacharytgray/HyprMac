import Cocoa

// single source of truth for window-keyed lifecycle and classification state.
// fields migrate in over Phase 2 — one dict per commit.
//
// what lives here (per §3.3):
//   - knownWindowIDs       — windows we've seen since launch
//   - floatingWindowIDs    — windows excluded from tiling
//   - originalFrames       — pre-tile frames for float-toggle restore
//   - windowOwners         — wid → pid for close-vs-hide detection
//   - hiddenWindowIDs      — disappeared but app still alive
//   - tiledPositions       — expected tiled frames (drag detection, FFM)
//   - cachedWindows        — last poll's HyprWindow snapshots
//
// what does NOT live here:
//   - workspace assignment (WorkspaceManager)
//   - BSP membership / knownMinSizes (TilingEngine / MinSizeMemory)
//   - pendingInsertedWindowIDs (TilingEngine — tiling-layer concern)
//   - floating-border panels (FocusBorder)
//
// main-thread is a precondition. no synchronization beyond that.
final class WindowStateCache {

    // last poll's HyprWindow snapshots, keyed by wid. populated by pollWindowChanges
    // and read by FFM, drag detection, focus-border refresh, raise-floaters, etc.
    var cachedWindows: [CGWindowID: HyprWindow] = [:]

    // expected tiled frames keyed by wid — drag detection compares mouseDown
    // frame against these to classify drag-vs-resize, and FFM uses them as
    // hit-rects so it can match windows without an AX poll.
    var tiledPositions: [CGWindowID: CGRect] = [:]

    // remove this window from every tracked dict.
    // used when a window is permanently gone (closed, app exited).
    func forget(_ id: CGWindowID) {
        cachedWindows.removeValue(forKey: id)
        tiledPositions.removeValue(forKey: id)
    }
}
