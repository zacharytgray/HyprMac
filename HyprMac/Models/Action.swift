import Foundation

enum Direction: String, Codable {
    case left, right, up, down
}

enum Action: Equatable {
    case focusDirection(Direction)
    case swapDirection(Direction)
    case switchDesktop(Int)
    case moveToDesktop(Int)
    case toggleFloating
    case toggleSplit
    case launchApp(bundleID: String)
}
