// "General" section of Settings: tiling status, startup, the menu bar and
// Dock, updates and the tutorial.

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
                ShortcutHint("Pause or resume with", action: .toggleTiling)
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
                        .buttonStyle(.settingsProminent)
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
                            .buttonStyle(.settings)
                    }
                    .fixedSize()
                case .notEnabled:
                    Button("Enable") { loginItem.enable() }
                        .buttonStyle(.settings)
                case .requiresApproval, .failed:
                    Button("Open Login Items") { loginItem.openLoginItems() }
                        .buttonStyle(.settings)
                }
            }
            SettingsRow("Restore saved layout at launch", icon: "arrow.counterclockwise",
                        subtitle: "Brings back the layout saved for this display setup.",
                        divider: false) {
                Toggle("", isOn: $config.restoreLayoutOnLaunch)
                    .toggleStyle(HyprToggleStyle())
                    .labelsHidden()
            } detail: {
                ShortcutHint("Save a layout with", action: .saveLayout)
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
                    .buttonStyle(.settings)
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
