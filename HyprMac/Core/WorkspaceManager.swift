// Virtual workspace bookkeeping. Workspaces are statically anchored to
// monitors via `(N - 1) % enabledMonitorCount` — with 3 monitors,
// ws 1, 4, 7 → Mon1; ws 2, 5, 8 → Mon2; ws 3, 6, 9 → Mon3.

import Cocoa

/// Single source of truth for HyprMac's nine virtual workspaces.
///
/// **Static anchoring**: every workspace has a deterministic home
/// monitor computed as `enabledScreens[(N - 1) % enabledScreens.count]`.
/// Switching to ws N always lands on its home monitor. Workspaces
/// cannot move between monitors.
///
/// Owns:
/// - `monitorWorkspace`: which workspace is currently visible on each
///   screen (keyed by `screenID`). Invariant: any value here must have
///   the keyed screen as its static home.
/// - `windowWorkspaces` (private): window → workspace assignment.
/// - `savedFloatingFrames` (private): per-window floating frames
///   captured before a hide, restored on show.
///
/// Threading: main-thread only.
class WorkspaceManager {
    let displayManager: DisplayManager

    /// Screen → workspace currently shown on that screen.
    private(set) var monitorWorkspace: [Int: Int] = [:]

    /// Window → workspace assignment.
    private var windowWorkspaces: [CGWindowID: Int] = [:]

    /// Reverse index of `windowWorkspaces`. Kept in sync by every
    /// `assignWindow` / `removeWindow` / `moveWindow` call.
    private var workspaceWindowSets: [Int: Set<CGWindowID>] = [:]

    /// Pre-hide frames for floating windows. Restored on the next
    /// reveal so floaters return to their last user-chosen position.
    private var savedFloatingFrames: [CGWindowID: CGRect] = [:]

    /// Localized names of monitors the user has excluded from tiling.
    /// Disabled monitors host floating windows only.
    var disabledMonitors: Set<String> = []

    /// Total number of virtual workspaces (1...9).
    let workspaceCount = 9

    init(displayManager: DisplayManager) {
        self.displayManager = displayManager
    }

    /// Stable per-screen integer key matching the BSP tree's
    /// `TilingKey` derivation. Two screens at the same origin would
    /// collide; in practice macOS prevents that.
    func screenID(for screen: NSScreen) -> Int {
        Int(screen.frame.origin.x * 10000 + screen.frame.origin.y)
    }

    /// `true` when `screen` is in the user's `disabledMonitors` list.
    func isMonitorDisabled(_ screen: NSScreen) -> Bool {
        disabledMonitors.contains(screen.localizedName)
    }

    // screens sorted left-to-right by CG x origin
    private func screensLeftToRight() -> [NSScreen] {
        displayManager.screens.sorted { $0.frame.origin.x < $1.frame.origin.x }
    }

    /// Enabled screens left-to-right. Drives `homeScreenForWorkspace`.
    private func enabledScreensLeftToRight() -> [NSScreen] {
        screensLeftToRight().filter { !isMonitorDisabled($0) }
    }

    /// Workspaces whose static home is `screen`. Useful for choosing a
    /// monitor's default visible workspace and for capacity checks that
    /// need to know which workspaces "live here."
    func workspacesAnchoredTo(_ screen: NSScreen) -> [Int] {
        let enabled = enabledScreensLeftToRight()
        guard let idx = enabled.firstIndex(of: screen) else { return [] }
        let count = enabled.count
        return Array(stride(from: idx + 1, through: workspaceCount, by: count))
    }

    /// Establish or refresh the screen→workspace mapping.
    ///
    /// Each enabled monitor's currently-visible workspace must be one
    /// whose static home is that monitor. If the existing mapping
    /// satisfies that invariant it is preserved; otherwise the monitor
    /// falls back to its lowest-numbered home workspace (its
    /// left-to-right index + 1). Disabled and removed monitors lose
    /// their entries.
    func initializeMonitors() {
        let allScreens = screensLeftToRight()
        let enabled = allScreens.filter { !isMonitorDisabled($0) }

        // remove workspace assignments for disabled monitors
        for screen in allScreens where isMonitorDisabled(screen) {
            let sid = screenID(for: screen)
            if let ws = monitorWorkspace.removeValue(forKey: sid) {
                hyprLog(.debug, .lifecycle, "init: removed ws\(ws) from disabled monitor \(screen.localizedName)")
            }
        }

        // for each enabled screen, ensure its current visible workspace
        // is one whose static home is this screen — otherwise default
        // to that screen's lowest-numbered home workspace.
        for screen in enabled {
            let sid = screenID(for: screen)
            let homeWorkspaces = workspacesAnchoredTo(screen)
            let valid: Set<Int> = Set(homeWorkspaces)
            if let current = monitorWorkspace[sid], valid.contains(current) {
                continue
            }
            monitorWorkspace[sid] = homeWorkspaces.first ?? 1
        }

        // clean up stale entries for screens that no longer exist
        let currentSIDs = Set(allScreens.map { screenID(for: $0) })
        for sid in monitorWorkspace.keys where !currentSIDs.contains(sid) {
            monitorWorkspace.removeValue(forKey: sid)
        }

        hyprLog(.debug, .lifecycle, "init: monitors=\(monitorWorkspace) enabled=\(enabled.count)")
    }

    /// Workspace currently visible on `screen`. Self-heals by calling
    /// `initializeMonitors` and retrying when the screen has no
    /// mapping — that path should not normally fire and logs a warning
    /// when it does.
    func workspaceForScreen(_ screen: NSScreen) -> Int {
        let sid = screenID(for: screen)
        if let ws = monitorWorkspace[sid] {
            return ws
        }
        hyprLog(.debug, .lifecycle, "WARNING: screen \(sid) had no workspace, reinitializing")
        initializeMonitors()
        return monitorWorkspace[sid] ?? 1
    }

    /// Screen currently showing `workspace`, or `nil` when the
    /// workspace is hidden.
    func screenForWorkspace(_ workspace: Int) -> NSScreen? {
        let targetSID = monitorWorkspace.first { $0.value == workspace }?.key
        guard let sid = targetSID else { return nil }
        return displayManager.screens.first { screenID(for: $0) == sid }
    }

    /// Static home screen for `workspace`. Pure function of `workspace`
    /// and the current enabled-screens layout. Indexed by
    /// `(workspace - 1) % enabledScreens.count`. Returns `nil` only
    /// when no enabled screens exist.
    func homeScreenForWorkspace(_ workspace: Int) -> NSScreen? {
        guard workspace >= 1 && workspace <= workspaceCount else { return nil }
        let enabled = enabledScreensLeftToRight()
        guard !enabled.isEmpty else { return nil }
        return enabled[(workspace - 1) % enabled.count]
    }

    /// `true` when `workspace` is currently shown on any screen.
    func isWorkspaceVisible(_ workspace: Int) -> Bool {
        monitorWorkspace.values.contains(workspace)
    }

    /// Assign `windowID` to `workspace`, removing it from any prior
    /// workspace assignment in the same call.
    func assignWindow(_ windowID: CGWindowID, toWorkspace workspace: Int) {
        if let old = windowWorkspaces[windowID] {
            workspaceWindowSets[old]?.remove(windowID)
        }
        windowWorkspaces[windowID] = workspace
        workspaceWindowSets[workspace, default: []].insert(windowID)
    }

    /// Workspace a window is assigned to, or `nil` when no
    /// assignment exists.
    func workspaceFor(_ windowID: CGWindowID) -> Int? {
        windowWorkspaces[windowID]
    }

    /// `true` when `windowID`'s workspace is currently visible (or
    /// when the window has no assignment — floating windows take this
    /// branch).
    func isWindowVisible(_ windowID: CGWindowID) -> Bool {
        guard let ws = windowWorkspaces[windowID] else { return true }
        return isWorkspaceVisible(ws)
    }

    /// Every window assigned to `workspace`. Includes hidden windows.
    func windowIDs(onWorkspace workspace: Int) -> Set<CGWindowID> {
        workspaceWindowSets[workspace] ?? []
    }

    /// Snapshot of the live window→workspace map.
    func allWindowWorkspaces() -> [CGWindowID: Int] {
        windowWorkspaces
    }

    /// Move `windowID` to `workspace`. Identical effect to
    /// `assignWindow`; the alias clarifies caller intent at the use
    /// site.
    func moveWindow(_ windowID: CGWindowID, toWorkspace workspace: Int) {
        if let old = windowWorkspaces[windowID] {
            workspaceWindowSets[old]?.remove(windowID)
        }
        windowWorkspaces[windowID] = workspace
        workspaceWindowSets[workspace, default: []].insert(windowID)
    }

    /// Drop `windowID` from workspace tracking entirely. Used when the
    /// window closes or its app terminates.
    func removeWindow(_ windowID: CGWindowID) {
        if let old = windowWorkspaces[windowID] {
            workspaceWindowSets[old]?.remove(windowID)
        }
        windowWorkspaces.removeValue(forKey: windowID)
        savedFloatingFrames.removeValue(forKey: windowID)
    }

    /// Single global park position: 1px inside the bottom-right corner
    /// of the rightmost monitor. Because nothing lives to the right of
    /// the rightmost monitor (and typically nothing below it either),
    /// the window's off-screen extension area never overlaps another
    /// monitor — so macOS WindowServer doesn't trigger the
    /// rescale-to-neighbor bug that breaks per-monitor corner-park on
    /// middle monitors in horizontal multi-monitor layouts.
    func hidePosition() -> CGPoint {
        guard let rightmost = displayManager.screens.max(by: { $0.frame.maxX < $1.frame.maxX }) else {
            return .zero
        }
        let cg = displayManager.cgRect(for: rightmost)
        return CGPoint(x: cg.maxX - 1, y: cg.maxY - 1)
    }

    /// Park `window` at the global hide position via the
    /// EnhancedUI-guarded position write.
    func hideInCorner(_ window: HyprWindow, on screen: NSScreen) {
        let pos = hidePosition()
        window.setPositionOnly(pos)
        hyprLog(.debug, .lifecycle, "hide: '\(window.title ?? "?")' (\(window.windowID)) parked at (\(Int(pos.x)),\(Int(pos.y)))")
    }

    /// Capture `window`'s current frame so it can be restored after a
    /// workspace switch. No-op when the window has no readable frame.
    func saveFloatingFrame(_ window: HyprWindow) {
        if let frame = window.frame {
            savedFloatingFrames[window.windowID] = frame
        }
    }

    /// Apply the saved floating frame to `window` and clear the saved
    /// entry. No-op when no frame was captured.
    func restoreFloatingFrame(_ window: HyprWindow) {
        if let frame = savedFloatingFrames[window.windowID] {
            window.setFrame(frame)
            savedFloatingFrames.removeValue(forKey: window.windowID)
        }
    }

    /// Result of `moveWorkspace`: which workspace moved, which one
    /// the source screen fell back to, and which one was displaced
    /// off the target screen.
    /// Result of `moveWorkspace`. Static anchoring makes this struct
    /// effectively unused — kept for API compatibility with the
    /// orchestrator's `moveCurrentWorkspaceToMonitor` flow which now
    /// always rejects.
    struct MoveResult {
        let movedWs: Int
        let fallbackWs: Int
        let targetOldWs: Int
    }

    /// Always returns `nil` — workspaces are statically anchored and
    /// cannot move between monitors.
    func moveWorkspace(from sourceScreen: NSScreen, to targetScreen: NSScreen, monitorCount: Int) -> MoveResult? {
        hyprLog(.debug, .lifecycle, "moveWorkspace: rejected (workspaces are statically anchored)")
        return nil
    }

    /// Result of `switchWorkspace`. `toHide` and `toShow` are window
    /// id sets the caller drives through hide-corner and tile.
    /// `alreadyVisible` skips the hide/show pass entirely.
    struct SwitchResult {
        let toHide: Set<CGWindowID>
        let toShow: Set<CGWindowID>
        let screen: NSScreen
        let alreadyVisible: Bool
    }

    /// Switch to workspace `number`. Always lands on the workspace's
    /// static home monitor.
    ///
    /// - Parameter cursorScreen: kept for signature compatibility;
    ///   only used as the empty-result fallback when no enabled screens
    ///   exist or `number` is out of range.
    func switchWorkspace(_ number: Int, cursorScreen: NSScreen) -> SwitchResult {
        guard number >= 1 && number <= workspaceCount else {
            return SwitchResult(toHide: [], toShow: [], screen: cursorScreen, alreadyVisible: false)
        }
        guard let targetScreen = homeScreenForWorkspace(number) else {
            return SwitchResult(toHide: [], toShow: [], screen: cursorScreen, alreadyVisible: false)
        }

        let targetSID = screenID(for: targetScreen)

        if monitorWorkspace[targetSID] == number {
            hyprLog(.debug, .lifecycle, "switch: ws\(number) already visible on \(targetScreen.localizedName)")
            return SwitchResult(toHide: [], toShow: windowIDs(onWorkspace: number),
                                screen: targetScreen, alreadyVisible: true)
        }

        let oldWorkspace = monitorWorkspace[targetSID] ?? (workspacesAnchoredTo(targetScreen).first ?? 1)
        let toHide = windowIDs(onWorkspace: oldWorkspace)
        let toShow = windowIDs(onWorkspace: number)

        monitorWorkspace[targetSID] = number

        hyprLog(.debug, .lifecycle, "switch: \(targetScreen.localizedName) ws\(oldWorkspace)→ws\(number) (hide \(toHide.count), show \(toShow.count))")
        return SwitchResult(toHide: toHide, toShow: toShow, screen: targetScreen, alreadyVisible: false)
    }
}
