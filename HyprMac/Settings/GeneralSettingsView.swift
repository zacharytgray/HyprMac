// "General" tab of Settings.

import SwiftUI

/// "General" tab. Enable toggle, accessibility status,
/// focus-follows-mouse, never-tile list, workspace names, workspace pins, System panel
/// (menu bar style, iCloud sync, launch-at-login), Updates, and a footer with
/// replay-the-tour + reset.
struct GeneralSettingsView: View {
    let showTutorial: () -> Void
    @ObservedObject var config = UserConfig.shared
    @AppStorage(UserConfig.menuBarStyleKey) private var menuBarStyle: MenuBarStyle = .full
    @State private var accessibilityGranted = AccessibilityManager.isAccessibilityEnabled()
    @StateObject private var loginItem = LoginItemController()
    @State private var showingWorkspaceNames = false
    @State private var choosingSyncSide = false
    #if !HYPRMAC_DEBUG_VARIANT
    @Environment(\.updateController) private var updates
    #endif

    var body: some View {
        VStack(spacing: HyprSpacing.lg) {
            statusPanel
            mousePanel
            neverTilePanel
            workspaceNamesPanel
            workspacePinsPanel
            systemPanel
            updatesPanel
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
                  footer: "Hover response controls how often focus can react while the pointer moves. Higher rates check for a new focus target more often. With the cursor kept in place, a switch to a workspace on another display still moves it, to the center of that display.") {
            HyprRow("Focus follows mouse", icon: "cursorarrow.motionlines") {
                Toggle("", isOn: $config.focusFollowsMouse)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            }
            HyprRow("Hover response", icon: "speedometer") {
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
            HyprRow("Keep cursor in place when switching workspaces", icon: "cursorarrow", divider: false) {
                Toggle("", isOn: $config.keepCursorOnWorkspaceSwitch)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            }
        }
    }

    // MARK: float and tile rules

    // one list for every rule: an app in Never tile, an app tile rule, and
    // the rules for one kind of window, made from the menu bar or an action
    private var neverTilePanel: some View {
        HyprPanel("Float and tile rules",
                  footer: "A rule for one kind of window beats a rule for its app. Add window rules from the menu bar's Focused window section.") {
            let rows = FloatingRuleRow.rows(excludedBundleIDs: config.excludedBundleIDs,
                                            rules: config.floatingRules)
            if rows.isEmpty {
                HyprRow("No rules", icon: "circle.dashed",
                        subtitle: "HyprMac decides what floats", divider: false) { EmptyView() }
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                    FloatingRuleRowView(row: row, config: config, isLast: idx == rows.count - 1,
                                        appName: appDisplayName(for: row.bundleID))
                }
            }
            HyprRow("Always float an app", icon: "plus", divider: false) {
                Button("Choose…") { pickExcludedApp() }
                    .controlSize(.small)
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
        HyprPanel("Pin apps",
                  footer: "New windows from these apps open on the chosen workspace or in the "
                        + "scratchpad, and HyprMac shows it. Retile all spaces also moves their "
                        + "open windows there, and a scratchpad pin applies at launch too.") {
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
                Text("Scratchpad").tag(WindowRule.scratchpad)
                Divider()
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

    private func setPinnedWorkspace(_ workspace: Int, for bundleID: String) {
        guard let index = config.windowRules.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        config.windowRules[index].workspace = workspace
    }

    // MARK: system — menu bar + iCloud + login items

    // turning sync on asks first when this Mac and iCloud disagree
    private var iCloudSyncBinding: Binding<Bool> {
        Binding(get: { config.iCloudSyncEnabled }, set: { on in
            if on, config.iCloudCopyDiffersFromLocal {
                choosingSyncSide = true
            } else {
                config.iCloudSyncEnabled = on
            }
        })
    }

    private var systemPanel: some View {
        HyprPanel("System",
                  footer: loginItemFooter) {
            HyprRow("Show in Dock", icon: "dock.rectangle",
                    subtitle: "Off keeps HyprMac out of the Dock and ⌘-Tab.") {
                Toggle("", isOn: $config.showDockIcon)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            }

            HyprRow("Menu bar", icon: "menubar.rectangle",
                    subtitle: "Full shows every workspace in use. Compact shows only the current workspace: its number, or its name from Workspace names (one Latin letter or digit goes in the badge; SF Symbols has no badges for other characters). Hidden removes the item; open HyprMac again from Spotlight or Finder to get back to Settings.") {
                Picker("", selection: $menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
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

            if config.isICloudDriveAvailable {
                HyprRow("Sync settings via iCloud", icon: "icloud",
                        subtitle: config.isICloudSyncLocked ? "Off while another tool manages the config file." : nil) {
                    Toggle("", isOn: iCloudSyncBinding)
                        .toggleStyle(HyprToggleStyle())
                        .labelsHidden()
                }
                .disabled(config.isICloudSyncLocked)
                .opacity(config.isICloudSyncLocked ? 0.5 : 1)
                .alert("iCloud has different settings", isPresented: $choosingSyncSide) {
                    Button("Use the settings in iCloud") { config.turnOnICloudSync(usingThisMac: false) }
                    Button("Use this Mac's settings") { config.turnOnICloudSync(usingThisMac: true) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The other settings are kept as a backup beside config.json.")
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

    // MARK: updates

    /// Nix or another manager replaces the app itself, and the debug variant has no updater.
    @ViewBuilder private var updatesPanel: some View {
        #if !HYPRMAC_DEBUG_VARIANT
        if let updates, !RuntimeVariant.updatesManagedExternally {
            UpdateSettingsPanel(updates: updates)
        }
        #endif
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
                        subtitle: "Restores the Hypr key, keybinds, rules, workspace names, layout, appearance and monitor settings, and turns off external control. Keeps this Mac's Show in Dock, Menu bar, Launch at login, iCloud sync and Updates.",
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
            // through the rule path, so an app tile rule for it goes
            config.addAlwaysFloatApp(id)
        }
    }

    // one rule per app: picking an app that already has one leaves it as is
    private func pickPinnedApp() {
        let panel = NSOpenPanel()
        panel.title = "Select Applications to Pin"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        let added = WindowRule.newRules(forBundleIDs: ids, existing: config.windowRules)
        if !added.isEmpty { config.windowRules.append(contentsOf: added) }
    }
}

#if !HYPRMAC_DEBUG_VARIANT
/// The two updater switches. They write Sparkle's own settings, so a
/// choice made in an update window shows here too. The version, the
/// manual check and a pending update are in the sidebar (`SidebarUpdateRow`).
private struct UpdateSettingsPanel: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        HyprPanel("Updates",
                  footer: "A downloaded update installs when you quit HyprMac, or once the Mac has been idle for five minutes. HyprMac restarts and puts your workspaces back.") {
            HyprRow("Check for updates automatically", icon: "arrow.triangle.2.circlepath",
                    subtitle: "Once a day.") {
                Toggle("", isOn: Binding(get: { updates.checksAutomatically },
                                         set: { updates.checksAutomatically = $0 }))
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            }
            HyprRow("Install updates automatically", icon: "arrow.down.circle",
                    subtitle: "Off shows a dot in the menu bar and a button in the sidebar, then waits for you.", divider: false) {
                Toggle("", isOn: Binding(get: { updates.installsAutomatically },
                                         set: { updates.installsAutomatically = $0 }))
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            }
            .disabled(!updates.checksAutomatically)
        }
    }
}
#endif
