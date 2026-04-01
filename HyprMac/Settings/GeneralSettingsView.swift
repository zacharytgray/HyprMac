import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var config = UserConfig.shared
    @State private var accessibilityGranted = AccessibilityManager.isAccessibilityEnabled()

    // double-tap action UI state
    private var doubleTapEnabled: Binding<Bool> {
        Binding(
            get: { config.doubleTapAction != nil },
            set: { config.doubleTapAction = $0 ? .focusMenuBar : nil }
        )
    }
    private var doubleTapChoice: Binding<DoubleTapChoice> {
        Binding(
            get: { DoubleTapChoice.from(config.doubleTapAction) },
            set: { config.doubleTapAction = $0.toDescriptor() }
        )
    }

    var body: some View {
        Form {
            Section("Status") {
                Toggle("HyprMac Enabled", isOn: $config.enabled)

                HStack {
                    Text("Accessibility Permission")
                    Spacer()
                    if accessibilityGranted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Granted")
                            .foregroundColor(.green)
                    } else {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                        Button("Grant Access") {
                            AccessibilityManager.promptForAccessibility()
                        }
                    }
                }
            }

            Section("Mouse") {
                Toggle("Focus Follows Mouse", isOn: $config.focusFollowsMouse)
                Text("Hovering over a tiled window focuses it. Drag-swap still works regardless of this setting.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Double-Tap Caps Lock") {
                Toggle("Enabled", isOn: doubleTapEnabled)
                if config.doubleTapAction != nil {
                    Picker("Action", selection: doubleTapChoice) {
                        ForEach(DoubleTapChoice.allCases, id: \.self) { c in
                            Text(c.rawValue).tag(c)
                        }
                    }
                }
                Text("Tap Caps Lock twice quickly to trigger the action. Won't fire if Caps Lock is used as a modifier between taps.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Hypr Key") {
                Text("Caps Lock is remapped to F18 while HyprMac is running. It acts as the Hypr modifier key for all keybinds. Normal Caps Lock is restored when the app quits.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Startup") {
                Text("Add HyprMac to Login Items in System Settings to launch at startup.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Button("Reset All Settings to Defaults") {
                    config.resetToDefaults()
                }
                .foregroundColor(.red)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            // refresh permission status
            accessibilityGranted = AccessibilityManager.isAccessibilityEnabled()
        }
    }
}

// choices for the double-tap caps lock action
enum DoubleTapChoice: String, CaseIterable {
    case focusMenuBar = "Focus Menu Bar"
    case toggleFloating = "Toggle Floating"
    case toggleSplit = "Toggle Split"
    case showKeybinds = "Show Keybinds"

    static func from(_ desc: Keybind.ActionDescriptor?) -> DoubleTapChoice {
        switch desc {
        case .toggleFloating: return .toggleFloating
        case .toggleSplit: return .toggleSplit
        case .showKeybinds: return .showKeybinds
        default: return .focusMenuBar
        }
    }

    func toDescriptor() -> Keybind.ActionDescriptor {
        switch self {
        case .focusMenuBar: return .focusMenuBar
        case .toggleFloating: return .toggleFloating
        case .toggleSplit: return .toggleSplit
        case .showKeybinds: return .showKeybinds
        }
    }
}
