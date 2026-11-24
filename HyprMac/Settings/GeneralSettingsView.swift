// "General" section of Settings, the first screen in the navy style, and
// the panels that left General until their own sections are redone.

import SwiftUI

/// "General": is tiling on, what starts at login, where HyprMac shows,
/// updates and the tutorial. Everything else moved to its own section.
struct GeneralSettingsView: View {
    let showTutorial: () -> Void
    @ObservedObject var config = UserConfig.shared
    @AppStorage(UserConfig.menuBarStyleKey) private var menuBarStyle: MenuBarStyle = .full
    @State private var accessibilityGranted = AccessibilityManager.isAccessibilityEnabled()
    /// Grant pressed and the drag panel up
    @State private var waitingForGrant = false
    /// The window this view sits in, for Grant to move and lower
    @State private var hostWindow = HostWindow()
    @StateObject private var loginItem = LoginItemController()
    #if !HYPRMAC_DEBUG_VARIANT
    @Environment(\.updateController) private var updates
    #endif

    var body: some View {
        VStack(spacing: HyprSpacing.lg) {
            statusCard
            startupCard
            presenceCard
            updatesCard
            helpCard
            SectionResetFooter(title: "Reset General to defaults",
                               message: "Turns tiling on and stops restoring the saved layout at launch. This Mac's login item, menu bar, Dock and update settings stay as they are.") {
                config.resetToDefaults(.general)
            }
        }
        .background(HostWindowReader(host: hostWindow))
        .onAppear {
            accessibilityGranted = AccessibilityManager.isAccessibilityEnabled()
            loginItem.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = AccessibilityManager.isAccessibilityEnabled()
            loginItem.refresh()
        }
    }

    // MARK: status

    /// This window floats above System Settings, so while the drag panel is
    /// up it drops to the normal level and waits beside System Settings. It
    /// comes back to the front showing the result.
    private func grantAccessibility() {
        let window = hostWindow.window
        window?.level = .normal
        waitingForGrant = true
        AccessibilityDragHelper.shared.start(beside: window) { _ in
            waitingForGrant = false
            accessibilityGranted = AccessibilityManager.isAccessibilityEnabled()
            window?.level = Constants.interfaceWindowLevel
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var statusCard: some View {
        SettingsCard("Status") {
            SettingsRow("Tiling", icon: "rectangle.split.2x2.fill",
                        subtitle: config.enabled
                            ? "On. New windows tile as they open."
                            : "Paused. Windows stay where you put them.") {
                Toggle("", isOn: $config.enabled)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            } detail: {
                shortcutLine("Pause or resume with", action: .toggleTiling)
            }
            SettingsRow("Accessibility access", icon: accessibilityGranted ? "checkmark.shield" : "exclamationmark.shield",
                        tint: accessibilityGranted ? .hyprCyan : .hyprMagenta,
                        subtitle: accessibilityGranted
                            ? "Lets HyprMac move and resize windows."
                            : waitingForGrant
                            ? "Drag HyprMac from the panel into the list in System Settings."
                            : "Required. HyprMac can't move windows without it.",
                        divider: false) {
                if accessibilityGranted {
                    SettingsStatusPill(text: "GRANTED")
                } else {
                    Button(waitingForGrant ? "Open Again" : "Grant", action: grantAccessibility)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: startup

    private var startupCard: some View {
        SettingsCard("Startup") {
            SettingsRow("Launch at login", icon: "power", subtitle: loginItemSubtitle) {
                switch loginItem.state {
                case .enabled:
                    HStack(spacing: HyprSpacing.sm) {
                        SettingsStatusPill(text: "ON")
                        Button("Manage…") { loginItem.openLoginItems() }
                            .controlSize(.small)
                    }
                    .fixedSize()
                case .notEnabled:
                    Button("Enable") { loginItem.enable() }
                        .controlSize(.small)
                case .requiresApproval, .failed:
                    Button("Open Login Items") { loginItem.openLoginItems() }
                        .controlSize(.small)
                }
            }
            SettingsRow("Restore saved layout at launch", icon: "arrow.counterclockwise",
                        subtitle: "Brings back the layout saved for this display setup.",
                        divider: false) {
                Toggle("", isOn: $config.restoreLayoutOnLaunch)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            } detail: {
                shortcutLine("Save a layout with", action: .saveLayout)
            }
        }
    }

    private var loginItemSubtitle: String {
        if let instruction = loginItem.instructionText { return instruction }
        if loginItem.state == .enabled {
            return "Starts when you sign in. Turn it off in Login Items."
        }
        return "Start \(loginItem.appName) when you sign in."
    }

    // MARK: menu bar and dock

    private var menuBarSubtitle: String {
        switch menuBarStyle {
        case .full: return "Shows every workspace in use."
        case .compact: return "Shows only the current workspace, by number or name."
        case .hidden: return "No menu bar item. Open HyprMac from Spotlight to get back here."
        }
    }

    private var presenceCard: some View {
        SettingsCard("Menu bar and Dock") {
            SettingsRow("Menu bar item", icon: "menubar.rectangle", subtitle: menuBarSubtitle) {
                SettingsSegmented(options: MenuBarStyle.allCases.map { ($0, $0.displayName) },
                                  selection: $menuBarStyle)
            }
            SettingsRow("Show in Dock", icon: "dock.rectangle",
                        subtitle: "Also puts HyprMac in ⌘-Tab.", divider: false) {
                Toggle("", isOn: $config.showDockIcon)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            }
        }
    }

    // MARK: updates

    /// Nix or another manager replaces the app itself, so the switches give
    /// way to one read-only line. The debug variant has no updater.
    @ViewBuilder private var updatesCard: some View {
        #if !HYPRMAC_DEBUG_VARIANT
        if RuntimeVariant.updatesManagedExternally {
            ManagedUpdatesPanel(nixInstall: RuntimeVariant.updatesManagedByNix)
        } else if let updates {
            UpdateSettingsPanel(updates: updates)
        }
        #endif
    }

    // MARK: help

    private var helpCard: some View {
        SettingsCard("Help") {
            Button(action: showTutorial) {
                SettingsRow("Replay the tutorial", icon: "sparkles", tint: .hyprMagenta,
                            subtitle: "The tour from first launch: the Hypr key, tiling, workspaces.",
                            divider: false) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.settingsTextFaint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // "Pause or resume with [hypr][P]", or nothing when the action has no bind
    @ViewBuilder
    private func shortcutLine(_ lead: String, action: Action) -> some View {
        if let bind = config.keybinds.first(where: { $0.action == action }) {
            HStack(spacing: 6) {
                Text(lead)
                    .font(.hyprCaption)
                    .foregroundStyle(Color.settingsTextMuted)
                // light key caps, so the chord reads as a hint, not a control
                HStack(spacing: 3) {
                    let labels = bind.badgeLabels()
                    if bind.modifiers.contains(.hypr) { HyprKeyChip(fontSize: 9.5) }
                    ForEach(Array(labels.dropFirst(bind.modifiers.contains(.hypr) ? 1 : 0).enumerated()),
                            id: \.offset) { _, label in
                        KeyChip(label, fontSize: 9.5, onGlass: true)
                    }
                }
                .fixedSize()
            }
            .padding(.top, 3)
        }
    }
}

/// The panels that left General, unchanged in look, shown in their new
/// sections until each section gets its redesign.
struct MovedGeneralPanels: View {
    enum Panel { case mouse, rules, workspaceNames, pins, overlays }

    let panels: [Panel]
    @ObservedObject var config = UserConfig.shared
    @State private var showingWorkspaceNames = false

    var body: some View {
        VStack(spacing: HyprSpacing.lg) {
            ForEach(Array(panels.enumerated()), id: \.offset) { _, panel in
                switch panel {
                case .mouse: mousePanel
                case .rules: neverTilePanel
                case .workspaceNames: workspaceNamesPanel
                case .pins: workspacePinsPanel
                case .overlays: overlaysPanel
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

    // MARK: overlays

    private var overlaysPanel: some View {
        HyprPanel("Overlays") {
            HyprRow("Overlay appearance", icon: "circle.lefthalf.filled", divider: false) {
                Picker("", selection: $config.overlayAppearance) {
                    ForEach(OverlayAppearance.allCases) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }
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

/// Updates when something outside HyprMac updates it: the menu row's
/// wording, read-only, and for the defaults key the command that undoes it.
struct ManagedUpdatesPanel: View {
    let nixInstall: Bool

    var body: some View {
        let command = MenuBarPresentation.updaterBackOnCommand(nixInstall: nixInstall)
        SettingsCard("Updates") {
            SettingsRow(MenuBarPresentation.managedUpdatesTitle(nixInstall: nixInstall),
                        icon: "shippingbox",
                        subtitle: MenuBarPresentation.managedUpdatesHint(nixInstall: nixInstall),
                        divider: false) {
                if let command {
                    Button("Copy command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    .controlSize(.small)
                }
            } detail: {
                if let command {
                    Text(command)
                        .font(.hyprMonoXs)
                        .foregroundStyle(Color.settingsText)
                        .textSelection(.enabled)
                        .padding(.top, 3)
                }
            }
        }
    }
}

#if !HYPRMAC_DEBUG_VARIANT
/// The two updater switches. They write Sparkle's own settings, so a
/// choice made in an update window shows here too. The version, the
/// manual check and a pending update are in the sidebar (`SidebarUpdateRow`).
private struct UpdateSettingsPanel: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        SettingsCard("Updates",
                     footer: "A downloaded update installs when you quit HyprMac, or once the Mac has been idle for five minutes. HyprMac restarts and puts your workspaces back.") {
            SettingsRow("Check for updates automatically", icon: "arrow.triangle.2.circlepath",
                        subtitle: "Once a day.") {
                Toggle("", isOn: Binding(get: { updates.checksAutomatically },
                                         set: { updates.checksAutomatically = $0 }))
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            }
            SettingsRow("Install updates automatically", icon: "arrow.down.circle",
                        subtitle: "Off shows a dot in the menu bar and a button in the sidebar, then waits for you.",
                        divider: false) {
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

/// Holds this view's window without making SwiftUI redraw when it is set.
private final class HostWindow {
    weak var window: NSWindow?
}

/// Reports the window the settings view lands in.
private struct HostWindowReader: NSViewRepresentable {
    let host: HostWindow

    func makeNSView(context: Context) -> ReaderView { ReaderView(host: host) }
    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        let host: HostWindow
        init(host: HostWindow) {
            self.host = host
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            host.window = window
        }
    }
}
