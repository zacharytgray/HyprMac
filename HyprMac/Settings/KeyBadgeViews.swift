// Keybind chord-display chips shared between Keybinds and App
// Launcher tabs and the keybind overlay.

import SwiftUI

/// Renders a keybind's chord as a row of chip-styled key badges
/// (Hypr, modifiers, key).
struct KeybadgeView: View {
    @ObservedObject var config = UserConfig.shared
    let bind: Keybind

    var body: some View {
        HStack(spacing: 3) {
            if bind.modifiers.contains(.hypr)    { KeyChip(config.hyprKey.badgeLabel) }
            if bind.modifiers.contains(.control) { KeyChip("⌃") }
            if bind.modifiers.contains(.option)  { KeyChip("⌥") }
            if bind.modifiers.contains(.shift)   { KeyChip("⇧") }
            if bind.modifiers.contains(.command) { KeyChip("⌘") }
            KeyChip(bind.keyCodeName)
        }
    }
}

/// Single chip-styled key label rendered inside `KeybadgeView`.
struct KeyChip: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minWidth: 28)
            .background(
                RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                    .fill(Color.gray.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                    .strokeBorder(Color.hyprSeparator, lineWidth: 1)
            )
            .foregroundStyle(Color.hyprTextPrimary)
    }
}
