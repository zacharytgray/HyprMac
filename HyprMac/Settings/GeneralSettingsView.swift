// "General" tab of Settings.

import SwiftUI

/// "General" tab. Enable toggle, accessibility status,
/// focus-follows-mouse, never-tile list, workspace names, workspace pins, System panel
/// (menu bar indicator, iCloud sync, launch-at-login), and a footer with
/// replay-the-tour + reset.
struct GeneralSettingsView: View {
    let showTutorial: () -> Void
    @ObservedObject var config = UserConfig.shared
    @State private var accessibilityGranted = AccessibilityManager.isAccessibilityEnabled()
    @StateObject private var loginItem = LoginItemController()
    @State private var showingWorkspaceNames = false

    var body: some View {
        VStack(spacing: HyprSpacing.lg) {
            statusPanel
            mousePanel
            neverTilePanel
            workspaceNamesPanel
            workspacePinsPanel
            systemPanel
            layoutsPanel
            footerPanel
        }
        .onAppear {
            accessibilityGranted = AccessibilityManager.isAccessibilityEnabled()
            loginItem.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }

    // MARK: status

    private var statusPanel: some View {
        HyprPanel("Status",
                  footer: accessibilityGranted ? nil : "Accessibility permission is required for HyprMac to function. Open System Settings to grant it.") {
            HyprRow("HyprMac", icon: "bolt.fill") {
                // the toggle style carries its own spacer; keep the badge beside it
                HStack(spacing: 0) {
                    if config.enabled {
                        HyprAccentBadge("ACTIVE", icon: "checkmark")
                    }
                    Toggle("", isOn: $config.enabled)
                        .toggleStyle(HyprToggleStyle())
                        .labelsHidden()
                }
                .fixedSize()
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

    // MARK: workspace names

    private var workspaceNamesPanel: some View {
        HyprPanel("Workspace names",
                  footer: "Names replace the numbers in the switch HUD, the menu bar and the workspace pickers.") {
            HyprRow("Names", icon: "character.cursor.ibeam",
                    subtitle: workspaceNamesSummary, divider: false) {
                Button("Rename…") { showingWorkspaceNames = true }
                    .controlSize(.small)
            }
        }
        .sheet(isPresented: $showingWorkspaceNames) {
            WorkspaceNamesSheet(config: config)
        }
    }

    // "None, ..." or "3 named: web, term, music"
    private var workspaceNamesSummary: String {
        let named = Constants.workspaceRange.compactMap { workspace -> String? in
            let name = config.workspaceNames[String(workspace)]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? nil : name
        }
        if named.isEmpty { return "None, workspaces show their numbers" }
        let shown = named.prefix(4).joined(separator: ", ")
        return "\(named.count) named: " + shown + (named.count > 4 ? ", …" : "")
    }

    // MARK: workspace pins

    private var workspacePinsPanel: some View {
        HyprPanel("Pin apps to workspaces",
                  footer: "New windows from these apps open on the chosen workspace, and HyprMac "
                        + "switches to it. Retile all spaces also moves their open windows there.") {
            if config.windowRules.isEmpty {
                HyprRow("No pinned apps", icon: "pin.slash",
                        subtitle: "New windows open on the display they appear on", divider: false) { EmptyView() }
            } else {
                let sorted = config.windowRules.sorted {
                    appDisplayName(for: $0.bundleID).localizedCaseInsensitiveCompare(
                        appDisplayName(for: $1.bundleID)) == .orderedAscending
                }
                ForEach(Array(sorted.enumerated()), id: \.element.id) { idx, rule in
                    pinnedRow(rule: rule, isLast: idx == sorted.count - 1)
                }
            }
            HyprRow("Add app", icon: "plus", divider: false) {
                Button("Choose…") { pickPinnedApp() }
                    .controlSize(.small)
            }
        }
    }

    private func pinnedRow(rule: WindowRule, isLast: Bool) -> some View {
        HStack(spacing: HyprSpacing.md) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "app").font(.system(size: 16)).foregroundStyle(Color.hyprTextTertiary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(appDisplayName(for: rule.bundleID)).font(.hyprBody)
                Text(rule.bundleID).font(.hyprMonoXs).foregroundStyle(Color.hyprTextTertiary)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { rule.workspace },
                set: { setPinnedWorkspace($0, for: rule.bundleID) }
            )) {
                ForEach(Constants.workspaceRange, id: \.self) {
                    Text(UserConfig.workspaceDisplayName($0, names: config.workspaceNames)).tag($0)
                }
            }
            .labelsHidden()
            .fixedSize()
            Button {
                config.windowRules.removeAll { $0.bundleID == rule.bundleID }
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

    // cyan, blue, purple, pink, red, orange, yellow, green
    static let overlayAccentPresets = ["56D8F0", "0A84FF", "BF5AF2", "FF6FB5",
                                       "FF453A", "FF9F0A", "FFD60A", "30D158"]

    private func setPinnedWorkspace(_ workspace: Int, for bundleID: String) {
        guard let index = config.windowRules.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        config.windowRules[index].workspace = workspace
    }

    // MARK: system — menu bar + iCloud + login items

    private var systemPanel: some View {
        HyprPanel("System",
                  footer: loginItemFooter) {
            HyprRow("Menu bar workspace indicator", icon: "rectangle.fill.on.rectangle.fill") {
                Toggle("", isOn: $config.showMenuBarIndicator)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            }

            HyprRow("Allow other apps to control HyprMac", icon: "link",
                    subtitle: "Lets apps like BetterTouchTool run HyprMac actions with hyprmac:// links.") {
                Toggle("", isOn: $config.externalControlEnabled)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            }

            HyprRow("Overlay appearance", icon: "circle.lefthalf.filled") {
                Picker("", selection: $config.overlayAppearance) {
                    ForEach(OverlayAppearance.allCases) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }

            HyprRow("Overlay accent", icon: "paintpalette",
                    subtitle: "Workspace HUD, overview, keybind sheet and this menu.") {
                HStack(spacing: 5) {
                    ForEach(Self.overlayAccentPresets, id: \.self) { hex in
                        let selected = config.overlayAccentHex == hex
                        Button { config.overlayAccentHex = hex } label: {
                            Circle().fill(Color(nsColor: NSColor.fromHex(hex) ?? .gray))
                                .frame(width: 14, height: 14)
                                .overlay(Circle().stroke(Color.hyprTextPrimary, lineWidth: selected ? 2 : 0)
                                    .padding(-2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Accent \(hex)")
                    }
                    ColorPicker("", selection: Binding(
                        get: { Color.overlaySecondary },
                        set: { config.overlayAccentHex = NSColor($0).hexString }
                    ), supportsOpacity: false)
                        .labelsHidden()
                        .fixedSize()
                    Button("Default") { config.overlayAccentHex = nil }
                        .controlSize(.small)
                        .disabled(config.overlayAccentHex == nil)
                }
            }

            HyprRow("Switch HUD position", icon: "rectangle.inset.bottomleft.filled") {
                Picker("", selection: $config.switchHUDPosition) {
                    ForEach(SwitchHUDPosition.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
            }

            HyprRow("Switch HUD style", icon: "square.grid.3x1.below.line.grid.1x2") {
                Picker("", selection: $config.switchHUDStyle) {
                    ForEach(SwitchHUDStyle.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
            }

            HyprRow("Switch HUD font", icon: "textformat") {
                Picker("", selection: $config.switchHUDFont) {
                    ForEach(SwitchHUDFont.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
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

            HyprRow("Launch at login", icon: "power", divider: false) {
                switch loginItem.state {
                case .enabled:
                    HStack(spacing: HyprSpacing.sm) {
                        HyprAccentBadge("ENABLED", icon: "checkmark")
                        Button("Manage") { loginItem.openLoginItems() }
                            .controlSize(.small)
                    }
                case .notEnabled:
                    Button("Enable") { loginItem.enable() }
                        .controlSize(.small)
                case .requiresApproval, .failed:
                    Button("Open Login Items") { loginItem.openLoginItems() }
                        .controlSize(.small)
                }
            }
        }
    }

    private var loginItemFooter: String {
        if let instruction = loginItem.instructionText {
            return instruction
        }
        if loginItem.state == .enabled {
            return "\(loginItem.appName) will launch automatically when you sign in. You can turn it off in System Settings → General → Login Items."
        }
        return "Start \(loginItem.appName) automatically when you sign in."
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

    // one rule per app: picking an app that already has one leaves it as is
    private func pickPinnedApp() {
        let panel = NSOpenPanel()
        panel.title = "Select Application to Pin"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url,
           let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
           !config.windowRules.contains(where: { $0.bundleID == id }) {
            config.windowRules.append(WindowRule(bundleID: id, workspace: 1))
        }
    }
}
