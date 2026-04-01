import Carbon
import Cocoa

struct Keybind: Codable, Equatable, Identifiable {
    var id: String { "\(modifiers.rawValue)-\(keyCode)" }

    let keyCode: UInt16
    let modifiers: ModifierFlags
    let action: ActionDescriptor

    // wrapper so Action can be serialized
    enum ActionDescriptor: Codable, Equatable {
        case focusDirection(String)
        case swapDirection(String)
        case switchDesktop(Int)
        case moveToDesktop(Int)
        case moveWorkspaceToMonitor(String)
        case toggleFloating
        case toggleSplit
        case launchApp(bundleID: String)

        func toAction() -> Action {
            switch self {
            case .focusDirection(let d): return .focusDirection(Direction(rawValue: d)!)
            case .swapDirection(let d): return .swapDirection(Direction(rawValue: d)!)
            case .switchDesktop(let n): return .switchDesktop(n)
            case .moveToDesktop(let n): return .moveToDesktop(n)
            case .moveWorkspaceToMonitor(let d): return .moveWorkspaceToMonitor(Direction(rawValue: d)!)
            case .toggleFloating: return .toggleFloating
            case .toggleSplit: return .toggleSplit
            case .launchApp(let b): return .launchApp(bundleID: b)
            }
        }
    }
}

struct ModifierFlags: OptionSet, Codable, Equatable, Hashable {
    let rawValue: UInt

    static let hypr    = ModifierFlags(rawValue: 1 << 0) // caps lock, our primary modifier
    static let shift   = ModifierFlags(rawValue: 1 << 1)
    static let option  = ModifierFlags(rawValue: 1 << 2)
    static let control = ModifierFlags(rawValue: 1 << 3)
    static let command = ModifierFlags(rawValue: 1 << 4)

    // build from CGEventFlags + our custom hypr tracking
    static func from(_ flags: CGEventFlags, hyprDown: Bool) -> ModifierFlags {
        var result = ModifierFlags()
        if hyprDown { result.insert(.hypr) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        return result
    }

    static func fromNS(_ flags: NSEvent.ModifierFlags, hyprDown: Bool = false) -> ModifierFlags {
        var result = ModifierFlags()
        if hyprDown { result.insert(.hypr) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }
}

// MARK: - default keybinds

extension Keybind {
    static let defaults: [Keybind] = {
        var binds: [Keybind] = []

        // hypr (caps lock) + arrow: focus direction
        binds.append(Keybind(keyCode: UInt16(kVK_LeftArrow), modifiers: .hypr,
                             action: .focusDirection("left")))
        binds.append(Keybind(keyCode: UInt16(kVK_RightArrow), modifiers: .hypr,
                             action: .focusDirection("right")))
        binds.append(Keybind(keyCode: UInt16(kVK_UpArrow), modifiers: .hypr,
                             action: .focusDirection("up")))
        binds.append(Keybind(keyCode: UInt16(kVK_DownArrow), modifiers: .hypr,
                             action: .focusDirection("down")))

        // hypr + shift + arrow: swap direction
        binds.append(Keybind(keyCode: UInt16(kVK_LeftArrow), modifiers: [.hypr, .shift],
                             action: .swapDirection("left")))
        binds.append(Keybind(keyCode: UInt16(kVK_RightArrow), modifiers: [.hypr, .shift],
                             action: .swapDirection("right")))
        binds.append(Keybind(keyCode: UInt16(kVK_UpArrow), modifiers: [.hypr, .shift],
                             action: .swapDirection("up")))
        binds.append(Keybind(keyCode: UInt16(kVK_DownArrow), modifiers: [.hypr, .shift],
                             action: .swapDirection("down")))

        // hypr + 1-9: focus monitor N / hypr + shift + 1-9: move window to monitor N
        let numKeys: [UInt16] = [
            UInt16(kVK_ANSI_1), UInt16(kVK_ANSI_2), UInt16(kVK_ANSI_3),
            UInt16(kVK_ANSI_4), UInt16(kVK_ANSI_5), UInt16(kVK_ANSI_6),
            UInt16(kVK_ANSI_7), UInt16(kVK_ANSI_8), UInt16(kVK_ANSI_9)
        ]
        for (i, key) in numKeys.enumerated() {
            binds.append(Keybind(keyCode: key, modifiers: .hypr,
                                 action: .switchDesktop(i + 1)))
            binds.append(Keybind(keyCode: key, modifiers: [.hypr, .shift],
                                 action: .moveToDesktop(i + 1)))
        }

        // hypr + ctrl + left/right: move current workspace to adjacent monitor
        binds.append(Keybind(keyCode: UInt16(kVK_LeftArrow), modifiers: [.hypr, .control],
                             action: .moveWorkspaceToMonitor("left")))
        binds.append(Keybind(keyCode: UInt16(kVK_RightArrow), modifiers: [.hypr, .control],
                             action: .moveWorkspaceToMonitor("right")))

        // hypr + shift + t: toggle floating
        binds.append(Keybind(keyCode: UInt16(kVK_ANSI_T), modifiers: [.hypr, .shift],
                             action: .toggleFloating))

        // hypr + j: toggle split direction (transpose)
        binds.append(Keybind(keyCode: UInt16(kVK_ANSI_J), modifiers: .hypr,
                             action: .toggleSplit))

        // hypr + enter: launch terminal
        binds.append(Keybind(keyCode: UInt16(kVK_Return), modifiers: .hypr,
                             action: .launchApp(bundleID: "com.apple.Terminal")))

        return binds
    }()
}
