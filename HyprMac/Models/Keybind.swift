import Carbon
import Cocoa

struct Keybind: Codable, Equatable, Identifiable {
    var id: String { "\(modifiers.rawValue)-\(keyCode)" }

    let keyCode: UInt16
    let modifiers: ModifierFlags
    let action: Action
}

struct ModifierFlags: OptionSet, Codable, Equatable, Hashable {
    let rawValue: UInt

    static let hypr    = ModifierFlags(rawValue: 1 << 0) // caps lock, our primary modifier
    static let shift   = ModifierFlags(rawValue: 1 << 1)
    static let option  = ModifierFlags(rawValue: 1 << 2)
    static let control = ModifierFlags(rawValue: 1 << 3)
    static let command = ModifierFlags(rawValue: 1 << 4)

    // build from individual booleans (settings UI)
    static func from(hypr: Bool = false, shift: Bool = false, control: Bool = false, option: Bool = false, command: Bool = false) -> ModifierFlags {
        var flags = ModifierFlags()
        if hypr    { flags.insert(.hypr) }
        if shift   { flags.insert(.shift) }
        if control { flags.insert(.control) }
        if option  { flags.insert(.option) }
        if command { flags.insert(.command) }
        return flags
    }

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

// default keybind table lives in Models/DefaultKeybinds.swift
