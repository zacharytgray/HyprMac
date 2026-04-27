// Virtual workspace bookkeeping. Keeps the screen↔workspace mapping,
// the per-window workspace assignment, and the home-screen affinity that
// makes a workspace return to the same monitor when revealed.

import Cocoa

/// Single source of truth for HyprMac's nine virtual workspaces.
///
/// Owns:
/// - `monitorWorkspace`: which workspace is currently visible on each
///   screen (keyed by `screenID`).
/// - `workspaceHomeScreen`: which screen each workspace was last shown
///   on. A workspace returns to its home screen when it is reactivated
///   from a hidden state, so workspace identity does not drift across
///   monitors.
/// - `windowWorkspaces` (private): window → workspace assignment, with
///   a reverse index for O(1) "windows on workspace N" lookup.
/// - `savedFloatingFrames` (private): per-window floating frames captured
///   before a hide, restored on show so a floater returns to where the
///   user left it.
///
/// Threading: main-thread only.
class WorkspaceManager {
    let displayManager: DisplayManager

    /// Screen → workspace currently shown on that screen.
    private(set) var monitorWorkspace: [Int: Int] = [:]

    /// Workspace → screen it was last shown on. Used to send a hidden
    /// workspace back to the same monitor on reactivation.
    private(set) var workspaceHomeScreen: [Int: Int] = [:]

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

    /// Establish or refresh the screen→workspace mapping.
    ///
    /// Assigns workspace N to the Nth enabled monitor left-to-right
    /// for any screen that has no existing mapping. Drops mappings
    /// for newly-disabled or removed screens. Already-mapped screens
    /// keep their workspace, so this is safe to call after a screen
    /// reconfiguration without disturbing the user's setup.
    func initializeMonitors() {
        let sorted = screensLeftToRight()

        // remove workspace assignments for disabled monitors
        for screen in sorted where isMonitorDisabled(screen) {
            let sid = screenID(for: screen)
            if let ws = monitorWorkspace.removeValue(forKey: sid) {
                // don't remove homeScreen — workspace still exists, just not visible
                hyprLog(.debug, .lifecycle, "removed workspace \(ws) from disabled monitor \(screen.localizedName)")
            }
        }

        let enabledScreens = sorted.filter { !isMonitorDisabled($0) }
        let usedWorkspaces = Set(monitorWorkspace.values)

        for (i, screen) in enabledScreens.enumerated() {
            let sid = screenID(for: screen)
            if monitorWorkspace[sid] != nil { continue }

            let preferred = i + 1
            if !usedWorkspaces.contains(preferred) {
                monitorWorkspace[sid] = preferred
                workspaceHomeScreen[preferred] = sid
            } else {
                for ws in 1...workspaceCount {
                    if !usedWorkspaces.contains(ws) && !monitorWorkspace.values.contains(ws) {
                        monitorWorkspace[sid] = ws
                        workspaceHomeScreen[ws] = sid
                        break
                    }
                }
                if monitorWorkspace[sid] == nil {
                    monitorWorkspace[sid] = preferred
                    workspaceHomeScreen[preferred] = sid
                }
            }
        }

        // clean up stale entries for screens that no longer exist
        let currentSIDs = Set(sorted.map { screenID(for: $0) })
        for sid in monitorWorkspace.keys where !currentSIDs.contains(sid) {
            monitorWorkspace.removeValue(forKey: sid)
        }
        // also clean workspaceHomeScreen pointing to nonexistent screens
        for (ws, sid) in workspaceHomeScreen where !currentSIDs.contains(sid) {
            workspaceHomeScreen.removeValue(forKey: ws)
        }

        hyprLog(.debug, .lifecycle, "workspace init: monitors=\(monitorWorkspace) homes=\(workspaceHomeScreen) disabled=\(disabledMonitors)")
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

    /// Screen `workspace` was last shown on (its home), regardless of
    /// current visibility. Returns `nil` when the workspace has never
    /// been shown.
    func homeScreenForWorkspace(_ workspace: Int) -> NSScreen? {
        guard let sid = workspaceHomeScreen[workspace] else { return nil }
        return displayManager.screens.first { screenID(for: $0) == sid }
    }

    /// Force-set `workspace`'s home screen. Used by
    /// `WorkspaceOrchestrator` when a manual move re-anchors a
    /// workspace's affinity.
    func setHomeScreen(for workspace: Int, screenID sid: Int) {
        workspaceHomeScreen[workspace] = sid
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

    /// CG coordinate for the hide-corner sliver: the bottom-right
    /// pixel of `screen`'s full frame. Hidden windows park here; the
    /// 1 px sliver remains visible (macOS limitation).
    func hidePosition(for screen: NSScreen) -> CGPoint {
        let primaryH = displayManager.primaryScreenHeight
        let frame = screen.frame
        let cgBottom = primaryH - frame.origin.y
        let cgRight = frame.origin.x + frame.width
        return CGPoint(x: cgRight - 1, y: cgBottom - 1)
    }

    /// Park `window` at the hide corner of `screen`. Used to make a
    /// window on a hidden workspace visually disappear without
    /// touching its tree state.
    func hideInCorner(_ window: HyprWindow, on screen: NSScreen) {
        let pos = hidePosition(for: screen)
        window.position = pos
        hyprLog(.debug, .lifecycle, "hiding '\(window.title ?? "?")' (\(window.windowID)) at (\(Int(pos.x)),\(Int(pos.y)))")
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
    struct MoveResult {
        let movedWs: Int       // workspace that moved to target
        let fallbackWs: Int    // workspace source fell back to
        let targetOldWs: Int   // workspace target was showing before (now displaced)
    }

    /// Move the workspace currently on `sourceScreen` to
    /// `targetScreen`, with `sourceScreen` falling back to its pinned
    /// home workspace (`monitor index + 1`).
    ///
    /// Pinned workspaces (1..`monitorCount`) cannot be moved off
    /// their home monitor — those calls return `nil`. The fallback
    /// must not already be visible on a different screen, otherwise
    /// the move is also blocked.
    func moveWorkspace(from sourceScreen: NSScreen, to targetScreen: NSScreen, monitorCount: Int) -> MoveResult? {
        let srcSID = screenID(for: sourceScreen)
        let tgtSID = screenID(for: targetScreen)
        let srcWs = monitorWorkspace[srcSID] ?? 1
        let tgtWs = monitorWorkspace[tgtSID] ?? 1

        // can't move pinned workspaces
        if srcWs <= monitorCount {
            hyprLog(.debug, .lifecycle, "moveWorkspace: ws\(srcWs) is pinned, can't move")
            return nil
        }

        // figure out source's fallback: its pinned home workspace (based on left-to-right index)
        let sorted = screensLeftToRight()
        let srcIdx = sorted.firstIndex(of: sourceScreen) ?? 0
        let fallbackWs = srcIdx + 1  // pinned workspace for this monitor position

        // if fallback is already visible on another screen, this gets complicated — block it
        if isWorkspaceVisible(fallbackWs) && screenForWorkspace(fallbackWs) != sourceScreen {
            // fallback ws is showing elsewhere, can't use it
            hyprLog(.debug, .lifecycle, "moveWorkspace: fallback ws\(fallbackWs) already visible elsewhere")
            return nil
        }

        // move: target shows srcWs, source shows fallback
        monitorWorkspace[tgtSID] = srcWs
        monitorWorkspace[srcSID] = fallbackWs
        workspaceHomeScreen[srcWs] = tgtSID
        workspaceHomeScreen[fallbackWs] = srcSID
        // displaced workspace from target remembers target as home
        workspaceHomeScreen[tgtWs] = tgtSID

        hyprLog(.debug, .lifecycle, "moveWorkspace: ws\(srcWs) → screen \(tgtSID), screen \(srcSID) → ws\(fallbackWs) (target had ws\(tgtWs))")
        return MoveResult(movedWs: srcWs, fallbackWs: fallbackWs, targetOldWs: tgtWs)
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

    /// Switch to workspace `number`.
    ///
    /// - If already visible somewhere: just focus that screen.
    /// - If not visible: show it on its home screen (where it was
    ///   last seen) when that screen is enabled; otherwise on
    ///   `cursorScreen` when enabled; otherwise the first enabled
    ///   screen. First-time workspaces default to `cursorScreen`.
    ///
    /// - Parameter cursorScreen: the screen the cursor is currently on.
    func switchWorkspace(_ number: Int, cursorScreen: NSScreen) -> SwitchResult {
        guard number >= 1 && number <= workspaceCount else {
            return SwitchResult(toHide: [], toShow: [], screen: cursorScreen, alreadyVisible: false)
        }

        // already visible on some screen?
        if let existingScreen = screenForWorkspace(number) {
            let sid = screenID(for: cursorScreen)
            if screenID(for: existingScreen) == sid {
                hyprLog(.debug, .lifecycle, "workspace \(number) already active on this screen")
            } else {
                hyprLog(.debug, .lifecycle, "workspace \(number) visible on another screen — focusing")
            }
            return SwitchResult(toHide: [], toShow: windowIDs(onWorkspace: number),
                                screen: existingScreen, alreadyVisible: true)
        }

        // not visible — find where to show it
        // use home screen if known and enabled, otherwise cursor screen (if enabled),
        // otherwise first enabled screen
        let targetScreen: NSScreen
        if let home = homeScreenForWorkspace(number), !isMonitorDisabled(home) {
            targetScreen = home
        } else if !isMonitorDisabled(cursorScreen) {
            targetScreen = cursorScreen
        } else if let firstEnabled = displayManager.screens.first(where: { !isMonitorDisabled($0) }) {
            targetScreen = firstEnabled
        } else {
            // all monitors disabled — nothing to do
            return SwitchResult(toHide: [], toShow: [], screen: cursorScreen, alreadyVisible: false)
        }

        let targetSID = screenID(for: targetScreen)
        let oldWorkspace = monitorWorkspace[targetSID] ?? 1
        let toHide = windowIDs(onWorkspace: oldWorkspace)
        let toShow = windowIDs(onWorkspace: number)

        // update mappings
        monitorWorkspace[targetSID] = number
        workspaceHomeScreen[oldWorkspace] = targetSID  // displaced ws remembers this screen
        workspaceHomeScreen[number] = targetSID         // new ws is now on this screen

        hyprLog(.debug, .lifecycle, "screen \(targetSID): workspace \(oldWorkspace) → \(number) (hide \(toHide.count), show \(toShow.count))")

        return SwitchResult(toHide: toHide, toShow: toShow, screen: targetScreen, alreadyVisible: false)
    }
}
