// What an outside app activation (Dock click, Cmd-Tab) does when none of that
// app's windows are on screen, and where a minimized window that comes back
// takes the user. Pure; `WindowManager.appDidActivate` and the discovery poll
// run it.

import Foundation

enum DockAffordance: Equatable {
    case none
    /// All the app's unseen windows include the hidden scratchpad. Summon the
    /// layer: switching to its workspace would range-guard into a no-op and
    /// strand the activation.
    case showScratchpad
    case switchWorkspace(Int)

    static func decide(appWorkspaces: [Int],
                       visibleWorkspaces: Set<Int>,
                       scratchpadWorkspace: Int,
                       scratchpadVisible: Bool) -> DockAffordance {
        guard !anyVisible(appWorkspaces, visibleWorkspaces: visibleWorkspaces,
                          scratchpadWorkspace: scratchpadWorkspace,
                          scratchpadVisible: scratchpadVisible) else { return .none }
        let hidden = appWorkspaces.filter { !visibleWorkspaces.contains($0) }
        if hidden.contains(scratchpadWorkspace), !scratchpadVisible { return .showScratchpad }
        if let target = hidden.filter({ $0 != scratchpadWorkspace }).min() { return .switchWorkspace(target) }
        return .none
    }

    /// A minimized or Cmd-H'd window of the frontmost app came back on a
    /// hidden workspace. The app's activation (Dock click, `open -a`) ran
    /// first and saw no window to go to, and Cmd-Tab alone does not
    /// un-minimize, so the return is the user's signal. Go to the returned
    /// window's workspace instead of parking it. Nil when the app already
    /// shows a window, or the window lives on the scratchpad, which handles
    /// its own returns.
    static func returnTarget(returnedWorkspaces: [Int],
                             appWorkspaces: [Int],
                             visibleWorkspaces: Set<Int>,
                             scratchpadWorkspace: Int,
                             scratchpadVisible: Bool) -> Int? {
        guard !anyVisible(appWorkspaces, visibleWorkspaces: visibleWorkspaces,
                          scratchpadWorkspace: scratchpadWorkspace,
                          scratchpadVisible: scratchpadVisible) else { return nil }
        return returnedWorkspaces
            .filter { !visibleWorkspaces.contains($0) && $0 != scratchpadWorkspace }
            .min()
    }

    private static func anyVisible(_ workspaces: [Int], visibleWorkspaces: Set<Int>,
                                   scratchpadWorkspace: Int, scratchpadVisible: Bool) -> Bool {
        workspaces.contains {
            visibleWorkspaces.contains($0) || ($0 == scratchpadWorkspace && scratchpadVisible)
        }
    }
}
