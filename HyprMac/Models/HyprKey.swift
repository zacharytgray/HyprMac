// Identifies the physical key acting as the Hypr modifier. Caps Lock
// is the default; the user can pick another modifier or function key
// from the settings UI.

import Carbon
import CoreGraphics

/// Physical key that takes the Hypr modifier role.
///
/// `capsLock` is special — it is remapped to `F18` at the IOKit
/// driver level via `KeyRemapper.usesCapsLockRemap`, so the Carbon
/// key code observed by `HotkeyManager` is `kVK_F18` regardless of
/// the user's choice. Every other case is a key the OS already
/// surfaces to the event tap directly.
enum HyprKey: String, Codable, CaseIterable, Identifiable {
    case capsLock
    case tab
    case grave
    case backslash
    case f13
    case f14
    case f15
    case f16
    case f17
    case f18
    case f19
    case f20
    case leftShift
    case rightShift
    case leftControl
    case rightControl
    case leftOption
    case rightOption
    case leftCommand
    case rightCommand

    var id: String { rawValue }

    var keyCode: UInt16 {
        switch self {
        case .capsLock: return UInt16(kVK_F18)
        case .tab: return UInt16(kVK_Tab)
        case .grave: return UInt16(kVK_ANSI_Grave)
        case .backslash: return UInt16(kVK_ANSI_Backslash)
        case .f13: return UInt16(kVK_F13)
        case .f14: return UInt16(kVK_F14)
        case .f15: return UInt16(kVK_F15)
        case .f16: return UInt16(kVK_F16)
        case .f17: return UInt16(kVK_F17)
        case .f18: return UInt16(kVK_F18)
        case .f19: return UInt16(kVK_F19)
        case .f20: return UInt16(kVK_F20)
        case .leftShift: return UInt16(kVK_Shift)
        case .rightShift: return UInt16(kVK_RightShift)
        case .leftControl: return UInt16(kVK_Control)
        case .rightControl: return UInt16(kVK_RightControl)
        case .leftOption: return UInt16(kVK_Option)
        case .rightOption: return UInt16(kVK_RightOption)
        case .leftCommand: return UInt16(kVK_Command)
        case .rightCommand: return UInt16(kVK_RightCommand)
        }
    }

    var displayName: String {
        switch self {
        case .capsLock: return "Caps Lock"
        case .tab: return "Tab"
        case .grave: return "`"
        case .backslash: return "\\"
        case .f13: return "F13"
        case .f14: return "F14"
        case .f15: return "F15"
        case .f16: return "F16"
        case .f17: return "F17"
        case .f18: return "F18"
        case .f19: return "F19"
        case .f20: return "F20"
        case .leftShift: return "Left Shift"
        case .rightShift: return "Right Shift"
        case .leftControl: return "Left Control"
        case .rightControl: return "Right Control"
        case .leftOption: return "Left Option"
        case .rightOption: return "Right Option"
        case .leftCommand: return "Left Command"
        case .rightCommand: return "Right Command"
        }
    }

    var badgeLabel: String {
        switch self {
        case .capsLock: return "⇪"
        case .tab: return "Tab"
        case .grave: return "`"
        case .backslash: return "\\"
        case .leftShift: return "L⇧"
        case .rightShift: return "R⇧"
        case .leftControl: return "L⌃"
        case .rightControl: return "R⌃"
        case .leftOption: return "L⌥"
        case .rightOption: return "R⌥"
        case .leftCommand: return "L⌘"
        case .rightCommand: return "R⌘"
        default: return displayName
        }
    }

    var pickerIcon: String {
        switch self {
        case .capsLock: return "capslock.fill"
        case .tab: return "arrow.right.to.line"
        case .grave, .backslash: return "keyboard"
        case .leftShift, .rightShift: return "shift"
        case .leftControl, .rightControl, .leftOption, .rightOption, .leftCommand, .rightCommand:
            return "command"
        default: return "keyboard"
        }
    }

    var usesCapsLockRemap: Bool {
        self == .capsLock
    }

    var nativeModifierFlag: CGEventFlags? {
        switch self {
        case .leftShift, .rightShift: return .maskShift
        case .leftControl, .rightControl: return .maskControl
        case .leftOption, .rightOption: return .maskAlternate
        case .leftCommand, .rightCommand: return .maskCommand
        default: return nil
        }
    }

    var isNativeModifier: Bool {
        nativeModifierFlag != nil
    }

    static func nativeModifierFlag(for keyCode: UInt16) -> CGEventFlags? {
        switch Int(keyCode) {
        case kVK_Shift, kVK_RightShift: return .maskShift
        case kVK_Control, kVK_RightControl: return .maskControl
        case kVK_Option, kVK_RightOption: return .maskAlternate
        case kVK_Command, kVK_RightCommand: return .maskCommand
        default: return nil
        }
    }

    static func isNativeModifierKeyCode(_ keyCode: UInt16) -> Bool {
        nativeModifierFlag(for: keyCode) != nil
    }

    static func isKeyCode(_ keyCode: UInt16, sameNativeModifierAs flag: CGEventFlags, excluding excludedKeyCode: UInt16) -> Bool {
        keyCode != excludedKeyCode && nativeModifierFlag(for: keyCode) == flag
    }
}
