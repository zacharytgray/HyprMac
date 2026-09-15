// "General" tab of Settings.

import SwiftUI

/// "General" tab. Enable toggle, accessibility status,
/// focus-follows-mouse, never-tile list, System panel (menu bar
/// indicator, iCloud sync, launch-at-login), and a footer with
/// replay-the-tour + reset.
struct GeneralSettingsView: View {
    let showTutorial: () -> Void
    @ObservedObject var config = UserConfig.shared
    @State private var accessibilityGranted = AccessibilityManager.isAccessibilityEnabled()

    var body: some View {
        VStack(spacing: HyprSpacing.lg) {
            statusPanel
            mousePanel
            neverTilePanel
            systemPanel
            layoutsPanel
            footerPanel
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
                  footer: "Hover response controls how often focus can react while the pointer moves. Higher rates check for a new focus target more often.") {
            HyprRow("Focus follows mouse", icon: "cursorarrow.motionlines") {
                Toggle("", isOn: $config.focusFollowsMouse)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            }
            HyprRow("Hover response", icon: "speedometer", divider: false) {
                Picker("", selection: $config.mouseHoverPollHz) {
                    if HoverResponseRate(rawValue: config.mouseHoverPollHz) == nil {
                        Text(HoverResponseRate.displayName(for: config.mouseHoverPollHz))
                            .tag(config.mouseHoverPollHz)
                    }
                    ForEach(HoverResponseRate.allCases) { rate in
                        Text(rate.displayName).tag(rate.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
                .disabled(!config.focusFollowsMouse)
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

    // MARK: system — menu bar + iCloud + login items

    private var systemPanel: some View {
        HyprPanel("System",
                  footer: "Add HyprMac to Login Items in System Settings → General → Login Items to launch at startup.") {
            HyprRow("Menu bar workspace indicator", icon: "rectangle.fill.on.rectangle.fill") {
                Toggle("", isOn: $config.showMenuBarIndicator)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            }

            if config.isICloudDriveAvailable {
                HyprRow("Sync settings via iCloud", icon: "icloud") {
                    Toggle("", isOn: $config.iCloudSyncEnabled)
                        .toggleStyle(HyprToggleStyle())
                        .labelsHidden()
                }
            } else {
                HyprRow("Sync settings via iCloud", icon: "xmark.icloud",
                        subtitle: "Enable iCloud Drive in System Settings") { EmptyView() }
            }

            Button { openLoginItems() } label: {
                HyprRow("Launch at login", icon: "power", divider: false) {
                    HyprChip("MANUAL ↗")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: layouts

    private var layoutsPanel: some View {
        HyprPanel("Layouts",
                  footer: "Hypr+Ctrl+S saves the window arrangement for the current display setup; Hypr+Ctrl+R brings it back. A saved layout also restores on its own when that display setup reconnects.") {
            HyprRow("Restore saved layout at launch", icon: "arrow.counterclockwise", divider: false) {
                Toggle("", isOn: $config.restoreLayoutOnLaunch)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            }
        }
    }

    // MARK: footer — replay tour + reset

    private var footerPanel: some View {
        HyprPanel {
            Button {
                showTutorial()
            } label: {
                HyprRow("HyprMac Tutorial", icon: "sparkles") {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.hyprTextTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { config.resetToDefaults() } label: {
                HyprRow("Reset all settings…",
                        subtitle: "Restores keybinds, tiling, exclusions to defaults",
                        divider: false) { EmptyView() }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
    }

    // MARK: helpers

    private func openLoginItems() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
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
