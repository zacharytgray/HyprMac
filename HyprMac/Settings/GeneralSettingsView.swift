import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var config = UserConfig.shared
    @State private var accessibilityGranted = AccessibilityManager.isAccessibilityEnabled()

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
