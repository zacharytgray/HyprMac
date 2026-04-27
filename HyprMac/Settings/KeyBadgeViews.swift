import SwiftUI

// shared keybind badge components — used by KeybindsSettingsView and AppLauncherSettingsView

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

struct KeyChip: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.14), radius: 1, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
    }
}
