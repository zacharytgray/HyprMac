// Display-side helpers on `Keybind`. Lives in Settings/ because every
// caller is SwiftUI display code — keeps `Models/Keybind.swift` free
// of UI strings and SF Symbol references.

import SwiftUI

extension Keybind {
    var keyCodeName: String { keyCodeToName(keyCode) }

    func badgeLabels(hyprLabel: String = "HYPR") -> [String] {
        var parts: [String] = []
        if modifiers.contains(.hypr) { parts.append(hyprLabel) }
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(keyCodeName)
        return parts
    }

    var overlayChord: String { badgeLabels().joined(separator: " ") }

    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.hypr)    { parts.append("HYPR") }
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
        case .moveToWorkspaceAndFollow:
            return "arrow.up.right.square.fill"
        case .moveWindowToMonitor:
            return "rectangle.2.swap"
        case .toggleFloating:
            return "macwindow.and.cursorarrow"
        case .toggleSplit:
            return "rectangle.split.2x1"
        case .showKeybinds:
            return "keyboard"
        case .showWorkspaceOverview:
            return "rectangle.grid.3x2"
        case .launchApp:
            return "app"
        case .focusMenuBar:
            return "menubar.rectangle"
        case .focusFloating:
            return "macwindow.on.rectangle"
        case .moveToNextEmptyWorkspace:
            return "rectangle.stack.badge.plus"
        case .closeWindow:
            return "xmark.circle"
        case .cycleWorkspace:
            return "arrow.clockwise.circle"
        case .toggleScratchpad:
            return "tray"
        case .moveToScratchpad:
            return "tray.and.arrow.down"
        case .resizeDirection:
            return "arrow.up.left.and.arrow.down.right"
        case .toggleTiling:
            return "pause.circle"
        case .runCommand:
            return "terminal"
        case .saveLayout:
            return "square.and.arrow.down"
        case .restoreLayout:
            return "square.and.arrow.up"
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
        case .moveToWorkspaceAndFollow(let n): return "Move to Workspace \(n) and Follow"
        case .moveWindowToMonitor(let d):   return "Move Window to \(d.rawValue.capitalized) Monitor"
        case .toggleFloating:               return "Toggle Floating"
        case .toggleSplit:                  return "Toggle Split Direction"
        case .showKeybinds:                 return "Show Keybind Overlay"
        case .showWorkspaceOverview:        return "Show Workspace Overview"
        case .launchApp(let b):             return "Launch \(appDisplayName(for: b))"
        case .focusMenuBar:                 return "Focus Menu Bar"
        case .focusFloating:                return "Cycle Floating Windows"
        case .moveToNextEmptyWorkspace:     return "Move to dedicated workspace"
        case .closeWindow:                  return "Close Window"
        case .cycleWorkspace(let d):        return d > 0 ? "Next Workspace" : "Previous Workspace"
        case .toggleScratchpad:             return "Toggle Scratchpad"
        case .moveToScratchpad:             return "Send to Scratchpad"
        case .resizeDirection(let d):       return "Resize \(d.rawValue.capitalized)"
        case .toggleTiling:                 return "Pause / Resume Tiling"
        case .runCommand(let label, let cmd): return Keybind.commandDescription(label: label, command: cmd)
        case .saveLayout:                   return "Save Layout"
        case .restoreLayout:                return "Restore Layout"
        }
    }

    /// Row title for a `runCommand` bind: the user's label when they gave
    /// one, else the program's basename.
    static func commandDescription(label: String, command: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        guard let program = (try? CommandLineParser.tokenize(command))?.first else {
            return "Run command"
        }
        return "Run \((program as NSString).lastPathComponent)"
    }
}
