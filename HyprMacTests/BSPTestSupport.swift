import Cocoa
@testable import HyprMac

// shared fixtures for BSP tests.
// HyprWindow only uses windowID for equality + hashing, so tests construct windows
// with synthetic IDs. the AXUIElement is a placeholder — BSP code never touches it.

func makeWindow(id: CGWindowID, pid: pid_t = 0) -> HyprWindow {
    let element = AXUIElementCreateApplication(pid)
    return HyprWindow(element: element, windowID: id, ownerPID: pid)
}

// reasonable defaults for layout-dependent tests
let defaultRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
let narrowRect = CGRect(x: 0, y: 0, width: 800, height: 1600)
let defaultGap: CGFloat = 8
let defaultPadding: CGFloat = 8
let defaultMinSlot: CGFloat = 500
