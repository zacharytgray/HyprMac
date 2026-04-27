import Foundation

// canonical grouping for displaying keybinds in the settings list and the
// keybind overlay. both sites previously kept their own copies of this map.
enum KeybindCategory: String, CaseIterable {
    case focusNav         = "Focus & Navigation"
    case windowManagement = "Window Management"
    case workspaces       = "Workspaces"
    case apps             = "Apps"
    case system           = "System"

    static func from(_ action: Action) -> KeybindCategory {
        switch action {
        case .focusDirection, .focusFloating, .focusMenuBar:
            return .focusNav
        case .swapDirection, .toggleFloating, .toggleSplit, .closeWindow:
            return .windowManagement
        case .switchWorkspace, .moveToWorkspace, .moveWorkspaceToMonitor, .cycleWorkspace:
            return .workspaces
        case .launchApp:
            return .apps
        case .showKeybinds:
            return .system
        }
    }
}
