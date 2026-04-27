// Keybind = key chord + action. The default table lives in
// `DefaultKeybinds.swift`.

import Carbon
import Cocoa

/// One user-configured key chord paired with the action it triggers.
struct Keybind: Codable, Equatable, Identifiable {
    /// Stable identity for SwiftUI lists. Two keybinds with the same
    /// chord collide on `id` — duplicate chords are not officially
    /// supported.
    var id: String { "\(modifiers.rawValue)-\(keyCode)" }

    let keyCode: UInt16
    let modifiers: ModifierFlags
    let action: Action
}

/// Modifier mask used by `Keybind`. Hypr is the primary modifier,
/// distinct from the OS-supplied modifiers; the rest mirror
/// `NSEvent.ModifierFlags` / `CGEventFlags`.
struct ModifierFlags: OptionSet, Codable, Equatable, Hashable {
    let rawValue: UInt

    static let hypr    = ModifierFlags(rawValue: 1 << 0)
    static let shift   = ModifierFlags(rawValue: 1 << 1)
    static let option  = ModifierFlags(rawValue: 1 << 2)
    static let control = ModifierFlags(rawValue: 1 << 3)
    static let command = ModifierFlags(rawValue: 1 << 4)

    /// Construct from per-modifier booleans. Used by the settings UI
    /// where each modifier toggle is its own checkbox.
    static func from(hypr: Bool = false, shift: Bool = false, control: Bool = false, option: Bool = false, command: Bool = false) -> ModifierFlags {
        var flags = ModifierFlags()
        if hypr    { flags.insert(.hypr) }
        if shift   { flags.insert(.shift) }
        if control { flags.insert(.control) }
        if option  { flags.insert(.option) }
        if command { flags.insert(.command) }
        return flags
    }

    /// Construct from `CGEventFlags` plus an externally-tracked Hypr
    /// state. Hypr is not in `CGEventFlags` — it is tracked separately
    /// by `HotkeyManager`.
    static func from(_ flags: CGEventFlags, hyprDown: Bool) -> ModifierFlags {
        var result = ModifierFlags()
        if hyprDown { result.insert(.hypr) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        return result
    }

    /// Construct from `NSEvent.ModifierFlags`. SwiftUI key recorders
    /// receive these and need the same Hypr-aware translation as the
    /// `CGEventFlags` form.
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

// default keybind table lives in Models/DefaultKeybinds.swift
