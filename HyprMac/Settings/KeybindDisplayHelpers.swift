// Display-side helpers on `Keybind`. Lives in Settings/ because every
// caller is SwiftUI display code — keeps `Models/Keybind.swift` free
// of UI strings and SF Symbol references.

import SwiftUI

extension Keybind {
    var keyCodeName: String { keyCodeToName(keyCode) }

    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.hypr)    { parts.append(UserConfig.shared.hyprKey.badgeLabel) }
        if modifiers.contains(.command) { parts.append("⌘") }
        if modifiers.contains(.shift)   { parts.append("⇧") }
        if modifiers.contains(.option)  { parts.append("⌥") }
        if modifiers.contains(.control) { parts.append("⌃") }
        parts.append(keyCodeName)
        return parts.joined(separator: "+")
    }

    var actionIcon: String {
        switch action {
        case .focusDirection(let d):
            switch d {
            case .left:  return "arrow.left"
            case .right: return "arrow.right"
            case .up:    return "arrow.up"
            case .down:  return "arrow.down"
            }
        case .swapDirection:
            return "arrow.left.arrow.right"
        case .switchWorkspace:
            return "number.circle"
        case .moveToWorkspace:
            return "arrow.up.right.square"
        case .moveWindowToMonitor:
            return "rectangle.2.swap"
        case .toggleFloating:
            return "macwindow.and.cursorarrow"
        case .toggleSplit:
            return "rectangle.split.2x1"
        case .showKeybinds:
            return "keyboard"
        case .launchApp:
            return "app"
        case .focusMenuBar:
            return "menubar.rectangle"
        case .focusFloating:
            return "macwindow.on.rectangle"
        case .closeWindow:
            return "xmark.circle"
        case .cycleWorkspace:
            return "arrow.clockwise.circle"
        case .toggleScratchpad:
            return "tray"
        case .moveToScratchpad:
            return "tray.and.arrow.down"
        }
    }

    // actions whose semantics touch the floating layer get the magenta ◇ suffix
    var touchesFloatingLayer: Bool {
        switch action {
        case .toggleFloating, .focusFloating, .toggleScratchpad, .moveToScratchpad:
            return true
        default:
            return false
        }
    }

    var actionDescription: String {
        switch action {
        case .focusDirection(let d):        return "Focus \(d.rawValue.capitalized)"
        case .swapDirection(let d):         return "Swap \(d.rawValue.capitalized)"
        case .switchWorkspace(let n):       return "Switch to Workspace \(n)"
        case .moveToWorkspace(let n):       return "Move to Workspace \(n)"
        case .moveWindowToMonitor(let d):   return "Move Window to \(d.rawValue.capitalized) Monitor"
        case .toggleFloating:               return "Toggle Floating"
        case .toggleSplit:                  return "Toggle Split Direction"
        case .showKeybinds:                 return "Show Keybind Overlay"
        case .launchApp(let b):             return "Launch \(appDisplayName(for: b))"
        case .focusMenuBar:                 return "Focus Menu Bar"
        case .focusFloating:                return "Cycle Floating Windows"
        case .closeWindow:                  return "Close Window"
        case .cycleWorkspace(let d):        return d > 0 ? "Next Workspace" : "Previous Workspace"
        case .toggleScratchpad:             return "Toggle Scratchpad"
        case .moveToScratchpad:             return "Send to Scratchpad"
        }
    }
}
