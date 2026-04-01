import Foundation

enum Direction: String, Codable {
    case left, right, up, down
}

enum Action: Equatable {
    case focusDirection(Direction)
    case swapDirection(Direction)
    case switchDesktop(Int)
    case moveToDesktop(Int)
    case moveWorkspaceToMonitor(Direction)  // move current workspace to adjacent monitor
    case toggleFloating
    case toggleSplit
    case showKeybinds
    case launchApp(bundleID: String)
    case focusMenuBar
}
