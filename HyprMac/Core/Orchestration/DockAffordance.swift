// What an outside app activation (Dock click, Cmd-Tab) does when none of that
// app's windows are on screen. Pure; `WindowManager.appDidActivate` runs it.

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
        let hasVisibleWindow = appWorkspaces.contains {
            visibleWorkspaces.contains($0) || ($0 == scratchpadWorkspace && scratchpadVisible)
        }
        guard !hasVisibleWindow else { return .none }
        let hidden = appWorkspaces.filter { !visibleWorkspaces.contains($0) }
        if hidden.contains(scratchpadWorkspace), !scratchpadVisible { return .showScratchpad }
        if let target = hidden.filter({ $0 != scratchpadWorkspace }).min() { return .switchWorkspace(target) }
        return .none
    }
}
