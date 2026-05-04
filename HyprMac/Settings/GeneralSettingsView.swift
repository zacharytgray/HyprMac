// "General" tab of Settings.

import SwiftUI

/// "General" tab. Enable toggle, accessibility status,
/// focus-follows-mouse, never-tile bundle list, menu bar indicator,
/// iCloud sync, Hypr key picker, version, and reset.
struct GeneralSettingsView: View {
    @ObservedObject var config = UserConfig.shared
    @State private var accessibilityGranted = AccessibilityManager.isAccessibilityEnabled()

    var body: some View {
        VStack(spacing: HyprSpacing.lg) {
            statusPanel
            mousePanel
            neverTilePanel
            menuBarPanel
            iCloudPanel
            startupPanel
            aboutPanel
        }
        .onAppear {
            accessibilityGranted = AccessibilityManager.isAccessibilityEnabled()
        }
    }

    // MARK: status

    private var statusPanel: some View {
        HyprPanel("Status",
                  footer: accessibilityGranted ? nil : "Accessibility permission is required for HyprMac to function. Open System Settings to grant it.") {
            HyprRow("HyprMac", icon: "bolt.fill") {
                if config.enabled {
                    HyprAccentBadge("ACTIVE", icon: "checkmark")
                }
                Toggle("", isOn: $config.enabled)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            }
            HyprRow(accessibilityGranted ? "Accessibility granted" : "Accessibility required",
                    icon: accessibilityGranted ? "checkmark.shield" : "exclamationmark.shield",
                    divider: false) {
                if accessibilityGranted {
                    HyprChip("OK")
                } else {
                    Button("Grant") { AccessibilityManager.promptForAccessibility() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: mouse

    private var mousePanel: some View {
        HyprPanel("Mouse",
                  footer: "Hovering over a tiled window focuses it. Drag-swap works regardless of this setting.") {
            HyprRow("Focus follows mouse", icon: "cursorarrow.motionlines", divider: false) {
                Toggle("", isOn: $config.focusFollowsMouse)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            }
        }
    }

    // MARK: never tile

    private var neverTilePanel: some View {
        HyprPanel("Never tile",
                  footer: "These apps always float and are never placed in the tiling layout.") {
            if config.excludedBundleIDs.isEmpty {
                HyprRow("No exclusions", icon: "circle.dashed",
                        subtitle: "All windows tile by default", divider: false) { EmptyView() }
            } else {
                let sorted = Array(config.excludedBundleIDs).sorted()
                ForEach(Array(sorted.enumerated()), id: \.element) { idx, bundleID in
                    excludedRow(bundleID: bundleID, isLast: idx == sorted.count - 1)
                }
            }
            HyprRow("Add app", icon: "plus", divider: false) {
                Button("Choose…") { pickExcludedApp() }
                    .controlSize(.small)
            }
        }
    }

    private func excludedRow(bundleID: String, isLast: Bool) -> some View {
        HStack(spacing: HyprSpacing.md) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "app").font(.system(size: 16)).foregroundStyle(Color.hyprTextTertiary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(appDisplayName(for: bundleID)).font(.hyprBody)
                Text(bundleID).font(.hyprMonoXs).foregroundStyle(Color.hyprTextTertiary)
            }
            Spacer()
            Button {
                config.excludedBundleIDs.remove(bundleID)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red.opacity(0.75))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, HyprSpacing.md)
        .padding(.vertical, HyprSpacing.sm)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(Color.hyprSeparator)
                    .frame(height: 0.5)
                    .padding(.leading, HyprSpacing.md + 22 + HyprSpacing.md)
            }
        }
    }

    // MARK: menu bar

    private var menuBarPanel: some View {
        HyprPanel("Menu bar",
                  footer: "Displays active workspaces and floating window status. When disabled, shows a static icon.") {
            HyprRow("Workspace indicator", icon: "rectangle.fill.on.rectangle.fill", divider: false) {
                Toggle("", isOn: $config.showMenuBarIndicator)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            }
        }
    }

    // MARK: iCloud

    private var iCloudPanel: some View {
        HyprPanel("iCloud sync",
                  footer: "Syncs keybinds, tiling settings, and preferences across Macs. Requires iCloud Drive in System Settings.") {
            if config.isICloudDriveAvailable {
                HyprRow("Sync via iCloud Drive", icon: "icloud", divider: false) {
                    Toggle("", isOn: $config.iCloudSyncEnabled)
                        .toggleStyle(HyprToggleStyle())
                        .labelsHidden()
                }
            } else {
                HyprRow("iCloud Drive unavailable", icon: "xmark.icloud",
                        subtitle: "Enable iCloud Drive in System Settings", divider: false) { EmptyView() }
            }
        }
    }

    // MARK: startup

    private var startupPanel: some View {
        HyprPanel("Startup",
                  footer: "Add HyprMac to Login Items in System Settings → General → Login Items to launch at startup.") {
            HyprRow("Launch at login", icon: "power", divider: false) {
                HyprChip("MANUAL")
            }
        }
    }

    // MARK: about

    private var aboutPanel: some View {
        HyprPanel("About") {
            HyprRow("Version", icon: "tag") {
                HyprChip(appVersion)
            }
            HyprRow("Getting started", icon: "sparkles") {
                Button("Show") {
                    (NSApp.delegate as? AppDelegate)?.showOnboarding()
                }
                .controlSize(.small)
            }
            HyprRow("Reset all settings", icon: "arrow.counterclockwise",
                    subtitle: "Restores keybinds, tiling, exclusions to defaults",
                    divider: false) {
                Button("Reset") { config.resetToDefaults() }
                    .controlSize(.small)
                    .tint(.red)
            }
        }
    }

    // MARK: helpers

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
