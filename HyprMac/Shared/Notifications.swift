import Foundation

extension Notification.Name {
    static let hyprMacRetileAll = Notification.Name("hyprMacRetileAll")
    static let hyprMacWorkspaceChanged = Notification.Name("hyprMacWorkspaceChanged")
    // posted once per dispatched hotkey action; Tour's try-it hint observes it
    static let hyprMacActionDispatched = Notification.Name("hyprMacActionDispatched")
    // the Show in Dock setting changed; AppDelegate applies the activation policy
    static let hyprMacDockIconChanged = Notification.Name("hyprMacDockIconChanged")
}
