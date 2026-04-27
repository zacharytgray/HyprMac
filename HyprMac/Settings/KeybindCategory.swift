// Categorizes a keybind for display. Single source for the action →
// category mapping; both the settings list and the keybind overlay
// route through `from(_:)`.

import Foundation

/// Display category for a keybind.
enum KeybindCategory: String, CaseIterable {
    case focusNav         = "Focus & Navigation"
    case windowManagement = "Window Management"
    case workspaces       = "Workspaces"
    case apps             = "Apps"
    case system           = "System"

    /// Classify `action` into one of the display categories.
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
