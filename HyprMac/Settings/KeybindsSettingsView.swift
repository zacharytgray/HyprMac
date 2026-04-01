import SwiftUI
import Carbon

struct KeybindsSettingsView: View {
    @ObservedObject var config = UserConfig.shared

    var body: some View {
        VStack(alignment: .leading) {
            Text("Default keybinds — these override system shortcuts while HyprMac is active.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            Table(config.keybinds) {
                TableColumn("Shortcut") { (bind: Keybind) in
                    Text(bind.displayString)
                        .font(.system(.body, design: .monospaced))
                }
                .width(min: 150, ideal: 200)

                TableColumn("Action") { (bind: Keybind) in
                    Text(bind.actionDescription)
                }
                .width(min: 200, ideal: 300)
            }

            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    config.keybinds = Keybind.defaults
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
    }
}

// MARK: - display helpers

extension Keybind {
    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.hypr) { parts.append("⇪") }
        if modifiers.contains(.command) { parts.append("⌘") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.control) { parts.append("⌃") }
        parts.append(keyCodeName)
        return parts.joined(separator: " + ")
    }

    var keyCodeName: String {
        switch Int(keyCode) {
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Return: return "Return"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_J: return "J"
        default: return "Key(\(keyCode))"
        }
    }

    var actionDescription: String {
        switch action {
        case .focusDirection(let d): return "Focus \(d)"
        case .swapDirection(let d): return "Swap \(d)"
        case .switchDesktop(let n): return "Switch to Desktop \(n)"
        case .moveToDesktop(let n): return "Move to Desktop \(n)"
        case .moveWorkspaceToMonitor(let d): return "Move Workspace \(d)"
        case .toggleFloating: return "Toggle Floating"
        case .toggleSplit: return "Toggle Split"
        case .launchApp(let b): return "Launch \(b)"
        }
    }
}
