import Cocoa

class WorkspaceManager {
    let displayManager: DisplayManager

    // screenID → workspace number currently shown on that monitor
    private(set) var monitorWorkspace: [Int: Int] = [:]

    // windowID → workspace number
    private var windowWorkspaces: [CGWindowID: Int] = [:]

    // saved frames for floating windows before hiding (for restore)
    private var savedFloatingFrames: [CGWindowID: CGRect] = [:]

    let workspaceCount = 9

    init(displayManager: DisplayManager) {
        self.displayManager = displayManager
    }

    // consistent screen ID matching TilingKey
    func screenID(for screen: NSScreen) -> Int {
        Int(screen.frame.origin.x * 10000 + screen.frame.origin.y)
    }

    // screens sorted left-to-right by CG x origin
    private func screensLeftToRight() -> [NSScreen] {
        displayManager.screens.sorted { $0.frame.origin.x < $1.frame.origin.x }
    }

    // call on startup: assign workspace N to the Nth monitor left-to-right
    func initializeMonitors() {
        let sorted = screensLeftToRight()
        for (i, screen) in sorted.enumerated() {
            let ws = i + 1
            let sid = screenID(for: screen)
            monitorWorkspace[sid] = ws
        }
        print("[HyprMac] workspace init: \(monitorWorkspace)")
    }

    // which workspace is currently shown on a given screen
    func workspaceForScreen(_ screen: NSScreen) -> Int {
        monitorWorkspace[screenID(for: screen)] ?? 1
    }

    // which screen is currently showing a given workspace (nil = not visible)
    func screenForWorkspace(_ workspace: Int) -> NSScreen? {
        let targetSID = monitorWorkspace.first { $0.value == workspace }?.key
        guard let sid = targetSID else { return nil }
        return displayManager.screens.first { screenID(for: $0) == sid }
    }

    // is a workspace visible on any monitor right now?
    func isWorkspaceVisible(_ workspace: Int) -> Bool {
        monitorWorkspace.values.contains(workspace)
    }

    // assign a window to a workspace (global, no screen binding)
    func assignWindow(_ windowID: CGWindowID, toWorkspace workspace: Int) {
        windowWorkspaces[windowID] = workspace
    }

    // get workspace for a window
    func workspaceFor(_ windowID: CGWindowID) -> Int? {
        windowWorkspaces[windowID]
    }

    // is this window on a currently-visible workspace?
    func isWindowVisible(_ windowID: CGWindowID) -> Bool {
        guard let ws = windowWorkspaces[windowID] else {
            return true  // untracked windows are visible
        }
        return isWorkspaceVisible(ws)
    }

    // all window IDs assigned to a workspace
    func windowIDs(onWorkspace workspace: Int) -> Set<CGWindowID> {
        var result: Set<CGWindowID> = []
        for (wid, ws) in windowWorkspaces where ws == workspace {
            result.insert(wid)
        }
        return result
    }

    // move a window to a different workspace
    func moveWindow(_ windowID: CGWindowID, toWorkspace workspace: Int) {
        windowWorkspaces[windowID] = workspace
    }

    // remove tracking for a terminated window
    func removeWindow(_ windowID: CGWindowID) {
        windowWorkspaces.removeValue(forKey: windowID)
        savedFloatingFrames.removeValue(forKey: windowID)
    }

    // hide corner position: bottom-right of screen's full frame (CG coords, 1px inside)
    func hidePosition(for screen: NSScreen) -> CGPoint {
        let primaryH = displayManager.primaryScreenHeight
        let frame = screen.frame
        let cgBottom = primaryH - frame.origin.y  // bottom of screen in CG coords
        let cgRight = frame.origin.x + frame.width
        return CGPoint(x: cgRight - 1, y: cgBottom - 1)
    }

    func hideInCorner(_ window: HyprWindow, on screen: NSScreen) {
        let pos = hidePosition(for: screen)
        window.position = pos
        print("[HyprMac] hiding '\(window.title ?? "?")' (\(window.windowID)) at (\(Int(pos.x)),\(Int(pos.y)))")
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

    // Swap the active workspaces between two screens.
    // Returns (workspaceA, workspaceB) — the workspaces that moved.
    // Pinned workspaces (1..monitorCount) are blocked from leaving their home monitor.
    func swapWorkspaces(screenA: NSScreen, screenB: NSScreen, monitorCount: Int) -> (Int, Int)? {
        let sidA = screenID(for: screenA)
        let sidB = screenID(for: screenB)
        let wsA = monitorWorkspace[sidA] ?? 1
        let wsB = monitorWorkspace[sidB] ?? 1

        // pinned: workspaces 1..monitorCount are home-locked
        if wsA <= monitorCount || wsB <= monitorCount {
            print("[HyprMac] swapWorkspaces: workspace \(wsA) or \(wsB) is pinned (1..\(monitorCount)), blocked")
            return nil
        }

        monitorWorkspace[sidA] = wsB
        monitorWorkspace[sidB] = wsA
        print("[HyprMac] swapped workspaces: screen \(sidA) now ws\(wsB), screen \(sidB) now ws\(wsA)")
        return (wsA, wsB)
    }

    // Switch the given screen to workspace `number`.
    // Returns (toHide, toShow, focusScreen) — or focusScreen only if already visible.
    // alreadyVisible=true means the workspace is showing on some other screen — just focus it.
    struct SwitchResult {
        let toHide: Set<CGWindowID>
        let toShow: Set<CGWindowID>
        let screen: NSScreen          // screen where the action happened
        let alreadyVisible: Bool      // workspace was already shown elsewhere
    }

    func switchWorkspace(_ number: Int, from currentScreen: NSScreen, allScreens: [NSScreen]) -> SwitchResult {
        guard number >= 1 && number <= workspaceCount else {
            return SwitchResult(toHide: [], toShow: [], screen: currentScreen, alreadyVisible: false)
        }

        // already visible on some screen?
        if let existingScreen = screenForWorkspace(number) {
            let sid = screenID(for: currentScreen)
            if screenID(for: existingScreen) == sid {
                // already on this screen — no-op
                print("[HyprMac] workspace \(number) already active on this screen")
            } else {
                // on another screen — just focus it
                print("[HyprMac] workspace \(number) visible on another screen — focusing")
            }
            return SwitchResult(toHide: [], toShow: windowIDs(onWorkspace: number),
                                screen: existingScreen, alreadyVisible: true)
        }

        // switch current screen to the new workspace
        let sid = screenID(for: currentScreen)
        let oldWorkspace = monitorWorkspace[sid] ?? 1
        let toHide = windowIDs(onWorkspace: oldWorkspace)
        let toShow = windowIDs(onWorkspace: number)

        monitorWorkspace[sid] = number
        print("[HyprMac] screen \(sid): workspace \(oldWorkspace) → \(number) (hide \(toHide.count), show \(toShow.count))")

        return SwitchResult(toHide: toHide, toShow: toShow, screen: currentScreen, alreadyVisible: false)
    }
}
