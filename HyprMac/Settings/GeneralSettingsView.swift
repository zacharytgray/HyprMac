import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var config = UserConfig.shared
    @State private var accessibilityGranted = AccessibilityManager.isAccessibilityEnabled()

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
            // status
            Section {
                HStack {
                    Label("HyprMac", systemImage: "bolt.fill")
                        .foregroundStyle(.primary)
                    Spacer()
                    Toggle("", isOn: $config.enabled)
                        .labelsHidden()
                }

                HStack {
                    Label("Accessibility", systemImage: accessibilityGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundStyle(accessibilityGranted ? .green : .orange)
                    Spacer()
                    if accessibilityGranted {
                        Text("Granted")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Grant Access") {
                            AccessibilityManager.promptForAccessibility()
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.accentColor)
                    }
                }
            } header: {
                Text("Status")
            } footer: {
                if !accessibilityGranted {
                    Text("Accessibility permission is required for HyprMac to function. Open System Settings to grant it.")
                        .foregroundStyle(.secondary)
                }
            }

            // mouse behavior
            Section("Mouse") {
                Toggle("Focus Follows Mouse", isOn: $config.focusFollowsMouse)
                Text("Hovering over a tiled window focuses it. Drag-swap works regardless of this setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // double-tap caps lock
            Section("Double-Tap Caps Lock") {
                Toggle("Enabled", isOn: doubleTapEnabled)
                if config.doubleTapAction != nil {
                    Picker("Action", selection: doubleTapChoice) {
                        ForEach(DoubleTapChoice.allCases, id: \.self) { c in
                            Text(c.rawValue).tag(c)
                        }
                    }
                }
                Text("Double-tap Caps Lock to trigger the action. Won't fire if Caps Lock was used as a modifier between taps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // never tile
            Section {
                if config.excludedBundleIDs.isEmpty {
                    Text("No apps excluded — all windows will be tiled.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(Array(config.excludedBundleIDs).sorted(), id: \.self) { bundleID in
                        HStack(spacing: 10) {
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable()
                                    .frame(width: 20, height: 20)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(appName(for: bundleID))
                                Text(bundleID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                config.excludedBundleIDs.remove(bundleID)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red.opacity(0.8))
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                Button("Add App…") { pickExcludedApp() }
            } header: {
                Text("Never Tile")
            } footer: {
                Text("These apps always float and are never placed in the tiling layout.")
                    .foregroundStyle(.secondary)
            }

            // menu bar
            Section("Menu Bar") {
                Toggle("Show Workspace Indicator", isOn: $config.showMenuBarIndicator)
                Text("Displays active workspaces and floating window status. When disabled, shows a static icon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // iCloud sync
            Section {
                if config.isICloudDriveAvailable {
                    Toggle("Sync via iCloud Drive", isOn: $config.iCloudSyncEnabled)
                    if config.iCloudSyncEnabled {
                        Label("Syncing via iCloud Drive", systemImage: "checkmark.icloud.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                } else {
                    Label("iCloud Drive not available", systemImage: "xmark.icloud")
                        .foregroundStyle(.secondary)
                }
                Text("Syncs keybinds, tiling settings, and preferences across Macs. Requires iCloud Drive in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("iCloud Sync")
            }

            // hypr key info
            Section("Hypr Key") {
                Label("Caps Lock → F18 (while HyprMac is running)", systemImage: "capslock.fill")
                    .font(.callout)
                Text("Caps Lock is remapped at the driver level via hidutil and acts as the Hypr modifier. Normal behavior is restored when the app quits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // startup
            Section("Startup") {
                Label("Launch at Login", systemImage: "power")
                    .font(.callout)
                Text("Add HyprMac to Login Items in System Settings → General → Login Items to launch at startup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // about + reset
            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(appVersion)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button("Reset All Settings to Defaults") {
                    config.resetToDefaults()
                }
                .foregroundStyle(.red)
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        .onAppear {
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
    case focusMenuBar  = "Focus Menu Bar"
    case focusFloating = "Focus Floating Windows"
    case toggleFloating = "Toggle Floating"
    case toggleSplit   = "Toggle Split"
    case showKeybinds  = "Show Keybinds"
    case closeWindow   = "Close Window"

    static func from(_ desc: Keybind.ActionDescriptor?) -> DoubleTapChoice {
        switch desc {
        case .toggleFloating: return .toggleFloating
        case .toggleSplit:    return .toggleSplit
        case .showKeybinds:   return .showKeybinds
        case .focusFloating:  return .focusFloating
        case .closeWindow:    return .closeWindow
        default:              return .focusMenuBar
        }
    }

    func toDescriptor() -> Keybind.ActionDescriptor {
        switch self {
        case .focusMenuBar:   return .focusMenuBar
        case .focusFloating:  return .focusFloating
        case .toggleFloating: return .toggleFloating
        case .toggleSplit:    return .toggleSplit
        case .showKeybinds:   return .showKeybinds
        case .closeWindow:    return .closeWindow
        }
    }
}
