import Cocoa

class WorkspaceManager {
    let displayManager: DisplayManager

    // screenID → workspace number currently shown on that monitor
    private(set) var monitorWorkspace: [Int: Int] = [:]

    // workspace → last screenID it was shown on (its "home" screen)
    private(set) var workspaceHomeScreen: [Int: Int] = [:]

    // windowID → workspace number
    private var windowWorkspaces: [CGWindowID: Int] = [:]
    // reverse index: workspace → window IDs (kept in sync with windowWorkspaces)
    private var workspaceWindowSets: [Int: Set<CGWindowID>] = [:]

    // saved frames for floating windows before hiding (for restore)
    private var savedFloatingFrames: [CGWindowID: CGRect] = [:]

    // monitors excluded from tiling (keyed by NSScreen.localizedName)
    var disabledMonitors: Set<String> = []

    let workspaceCount = 9

    init(displayManager: DisplayManager) {
        self.displayManager = displayManager
    }

    // consistent screen ID matching TilingKey
    func screenID(for screen: NSScreen) -> Int {
        Int(screen.frame.origin.x * 10000 + screen.frame.origin.y)
    }

    func isMonitorDisabled(_ screen: NSScreen) -> Bool {
        disabledMonitors.contains(screen.localizedName)
    }

    // screens sorted left-to-right by CG x origin
    private func screensLeftToRight() -> [NSScreen] {
        displayManager.screens.sorted { $0.frame.origin.x < $1.frame.origin.x }
    }

    // assign workspace N to the Nth enabled monitor left-to-right (startup only).
    // disabled monitors get no workspace. only fills in screens that don't already have a mapping.
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

    // which workspace is currently shown on a given screen
    func workspaceForScreen(_ screen: NSScreen) -> Int {
        let sid = screenID(for: screen)
        if let ws = monitorWorkspace[sid] {
            return ws
        }
        hyprLog(.debug, .lifecycle, "WARNING: screen \(sid) had no workspace, reinitializing")
        initializeMonitors()
        return monitorWorkspace[sid] ?? 1
    }

    // which screen is currently showing a given workspace (nil = not visible)
    func screenForWorkspace(_ workspace: Int) -> NSScreen? {
        let targetSID = monitorWorkspace.first { $0.value == workspace }?.key
        guard let sid = targetSID else { return nil }
        return displayManager.screens.first { screenID(for: $0) == sid }
    }

    // which screen was last showing a workspace (its "home" — may or may not be visible now)
    func homeScreenForWorkspace(_ workspace: Int) -> NSScreen? {
        guard let sid = workspaceHomeScreen[workspace] else { return nil }
        return displayManager.screens.first { screenID(for: $0) == sid }
    }

    func setHomeScreen(for workspace: Int, screenID sid: Int) {
        workspaceHomeScreen[workspace] = sid
    }

    func isWorkspaceVisible(_ workspace: Int) -> Bool {
        monitorWorkspace.values.contains(workspace)
    }

    func assignWindow(_ windowID: CGWindowID, toWorkspace workspace: Int) {
        if let old = windowWorkspaces[windowID] {
            workspaceWindowSets[old]?.remove(windowID)
        }
        windowWorkspaces[windowID] = workspace
        workspaceWindowSets[workspace, default: []].insert(windowID)
    }

    func workspaceFor(_ windowID: CGWindowID) -> Int? {
        windowWorkspaces[windowID]
    }

    func isWindowVisible(_ windowID: CGWindowID) -> Bool {
        guard let ws = windowWorkspaces[windowID] else { return true }
        return isWorkspaceVisible(ws)
    }

    func windowIDs(onWorkspace workspace: Int) -> Set<CGWindowID> {
        workspaceWindowSets[workspace] ?? []
    }

    func allWindowWorkspaces() -> [CGWindowID: Int] {
        windowWorkspaces
    }

    func moveWindow(_ windowID: CGWindowID, toWorkspace workspace: Int) {
        if let old = windowWorkspaces[windowID] {
            workspaceWindowSets[old]?.remove(windowID)
        }
        windowWorkspaces[windowID] = workspace
        workspaceWindowSets[workspace, default: []].insert(windowID)
    }

    func removeWindow(_ windowID: CGWindowID) {
        if let old = windowWorkspaces[windowID] {
            workspaceWindowSets[old]?.remove(windowID)
        }
        windowWorkspaces.removeValue(forKey: windowID)
        savedFloatingFrames.removeValue(forKey: windowID)
    }

    // hide corner position: bottom-right of screen's full frame in CG coords
    func hidePosition(for screen: NSScreen) -> CGPoint {
        let primaryH = displayManager.primaryScreenHeight
        let frame = screen.frame
        let cgBottom = primaryH - frame.origin.y
        let cgRight = frame.origin.x + frame.width
        return CGPoint(x: cgRight - 1, y: cgBottom - 1)
    }

    func hideInCorner(_ window: HyprWindow, on screen: NSScreen) {
        let pos = hidePosition(for: screen)
        window.position = pos
        hyprLog(.debug, .lifecycle, "hiding '\(window.title ?? "?")' (\(window.windowID)) at (\(Int(pos.x)),\(Int(pos.y)))")
    }

    func saveFloatingFrame(_ window: HyprWindow) {
        if let frame = window.frame {
            savedFloatingFrames[window.windowID] = frame
        }
    }

    func restoreFloatingFrame(_ window: HyprWindow) {
        if let frame = savedFloatingFrames[window.windowID] {
            window.setFrame(frame)
            savedFloatingFrames.removeValue(forKey: window.windowID)
        }
    }

    // move current workspace from sourceScreen to targetScreen.
    // source falls back to its pinned home workspace (monitor index + 1).
    // pinned workspaces (1..monitorCount) can't be moved off their home monitor.
    // returns (movedWs, fallbackWs, targetOldWs) or nil if blocked.
    struct MoveResult {
        let movedWs: Int       // workspace that moved to target
        let fallbackWs: Int    // workspace source fell back to
        let targetOldWs: Int   // workspace target was showing before (now displaced)
    }

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

    struct SwitchResult {
        let toHide: Set<CGWindowID>
        let toShow: Set<CGWindowID>
        let screen: NSScreen      // the screen where the switch happened
        let alreadyVisible: Bool
    }

    /// Switch to workspace `number`.
    /// - If already visible somewhere: just focus that screen.
    /// - If not visible: show it on its HOME screen (where it was last seen),
    ///   NOT on the cursor's screen. First-time workspaces default to cursorScreen.
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
