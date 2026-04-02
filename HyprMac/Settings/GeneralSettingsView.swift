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

            Section("Never Tile") {
                if config.excludedBundleIDs.isEmpty {
                    Text("No excluded apps. All windows will be tiled.")
                        .foregroundColor(.secondary)
                        .font(.caption)
                } else {
                    ForEach(Array(config.excludedBundleIDs).sorted(), id: \.self) { bundleID in
                        HStack(spacing: 10) {
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable()
                                    .frame(width: 20, height: 20)
                            }
                            Text(appName(for: bundleID))
                            Spacer()
                            Text(bundleID)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Button(role: .destructive) {
                                config.excludedBundleIDs.remove(bundleID)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                Button("Add App...") { pickExcludedApp() }
                Text("These apps will always float and never be placed in the tiling layout.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("iCloud Sync") {
                if config.isICloudDriveAvailable {
                    Toggle("Sync Settings via iCloud Drive", isOn: $config.iCloudSyncEnabled)
                    if config.iCloudSyncEnabled {
                        HStack {
                            Image(systemName: "checkmark.icloud.fill")
                                .foregroundColor(.blue)
                            Text("Syncing via iCloud Drive")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                } else {
                    HStack {
                        Image(systemName: "xmark.icloud")
                            .foregroundColor(.secondary)
                        Text("iCloud Drive not available")
                            .foregroundColor(.secondary)
                    }
                }
                Text("Sync keybinds, tiling settings, and preferences across Macs via iCloud Drive. Requires iCloud Drive enabled in System Settings.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Menu Bar") {
                Toggle("Show Workspace Indicator", isOn: $config.showMenuBarIndicator)
                Text("Display active workspaces and floating window status in the menu bar. When disabled, shows a static icon.")
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

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(appVersion)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            // refresh permission status
            accessibilityGranted = AccessibilityManager.isAccessibilityEnabled()
        }
    }

    private func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private func pickExcludedApp() {
        let panel = NSOpenPanel()
        panel.title = "Select Application to Exclude"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url,
           let bundle = Bundle(url: url), let id = bundle.bundleIdentifier {
            config.excludedBundleIDs.insert(id)
        }
    }
}

// choices for the double-tap caps lock action
enum DoubleTapChoice: String, CaseIterable {
    case focusMenuBar = "Focus Menu Bar"
    case focusFloating = "Focus Floating Windows"
    case toggleFloating = "Toggle Floating"
    case toggleSplit = "Toggle Split"
    case showKeybinds = "Show Keybinds"
    case closeWindow = "Close Window"

    static func from(_ desc: Keybind.ActionDescriptor?) -> DoubleTapChoice {
        switch desc {
        case .toggleFloating: return .toggleFloating
        case .toggleSplit: return .toggleSplit
        case .showKeybinds: return .showKeybinds
        case .focusFloating: return .focusFloating
        case .closeWindow: return .closeWindow
        default: return .focusMenuBar
        }
    }

    func toDescriptor() -> Keybind.ActionDescriptor {
        switch self {
        case .focusMenuBar: return .focusMenuBar
        case .focusFloating: return .focusFloating
        case .toggleFloating: return .toggleFloating
        case .toggleSplit: return .toggleSplit
        case .showKeybinds: return .showKeybinds
        case .closeWindow: return .closeWindow
        }
    }
}
