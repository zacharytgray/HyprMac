// Menu bar dropdown contents and compact workspace label.

import SwiftUI
#if !HYPRMAC_DEBUG_VARIANT
import Sparkle
#endif

/// `MenuBarExtra` dropdown contents: status header, per-monitor
/// workspace state, and standard actions (Settings, Retile, Check
/// for Updates, Quit). Restyled to match the settings window — same
/// surface treatment, mono accent typography, cyan active-state
/// indicator. The label rendered in the menu bar itself is
/// `WorkspaceIndicatorLabel` (below).
struct MenuBarView: View {
    let appDelegate: AppDelegate
    @ObservedObject var config = UserConfig.shared
    @ObservedObject private var menuBarState = MenuBarState.shared
    @Environment(\.openWindow) private var openWindow
    #if !HYPRMAC_DEBUG_VARIANT
    let updater: SPUUpdater
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: HyprSpacing.md) {
            header
            workspacePanel
            actions
        }
        .padding(HyprSpacing.md)
        .frame(width: 320)
        .background(Color.hyprBackground)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: HyprSpacing.sm) {
            VStack(alignment: .leading, spacing: 4) {
                HyprLockup(markSize: 18)
                Text(config.enabled ? "Tiling active" : "Tiling paused")
                    .font(.hyprMonoXs)
                    .foregroundStyle(config.enabled ? Color.overlayPrimary : Color.hyprTextTertiary)
            }
            Spacer(minLength: HyprSpacing.sm)
            Toggle("", isOn: $config.enabled)
                .toggleStyle(HyprToggleStyle())
                .labelsHidden()
        }
        .padding(.horizontal, HyprSpacing.xs)
    }

    // MARK: workspace panel

    @ViewBuilder
    private var workspacePanel: some View {
        if MenuBarPresentation.showsWorkspaceState(
            enabled: config.enabled,
            indicatorEnabled: true,
            hasData: menuBarState.hasData,
            monitors: menuBarState.monitors,
            scratchpadCount: menuBarState.scratchpadCount) {
            HyprPanel("Workspaces") {
                ForEach(menuBarState.monitors) { monitor in
                    monitorRow(monitor)
                }
                if menuBarState.scratchpadCount > 0 {
                    Rectangle()
                        .fill(Color.hyprSeparator)
                        .frame(height: 0.5)
                    HStack(spacing: 3) {
                        Image(systemName: "tray")
                            .font(.system(size: 10))
                        Text("\(menuBarState.scratchpadCount) stashed")
                            .font(.hyprMonoXs)
                        Spacer()
                    }
                    .foregroundStyle(Color.overlaySecondary)
                    .padding(.horizontal, HyprSpacing.md)
                    .padding(.vertical, HyprSpacing.sm)
                }
            }
        }
    }

    private func monitorRow(_ monitor: MenuBarMonitorSnapshot) -> some View {
        VStack(alignment: .leading, spacing: HyprSpacing.sm) {
            HStack(spacing: HyprSpacing.sm) {
                Image(systemName: monitor.isPortrait ? "rectangle.portrait" : "display")
                    .font(.system(size: 11))
                Text(monitor.name).font(.hyprBody).lineLimit(1).truncationMode(.middle)
                Spacer()
            }.foregroundStyle(Color.hyprTextSecondary)
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(25), spacing: 6), count: 5),
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(monitor.workspaces) { workspace in
                    Button {
                        guard config.enabled else { return }
                        appDelegate.windowManager?.handleAction(.switchWorkspace(workspace.id))
                    } label: {
                        Text(UserConfig.workspaceDisplayName(workspace.id, names: config.workspaceNames,
                                                             fallback: "\(workspace.id)"))
                            .font(.hyprMonoSm).lineLimit(1).minimumScaleFactor(0.5)
                            .frame(width: 25, height: 23)
                            .background(RoundedRectangle(cornerRadius: 4).fill(workspace.isActive ? Color.overlayPrimary : (workspace.isOccupied ? Color.overlaySecondary.opacity(0.24) : Color.white.opacity(0.06))))
                            .foregroundStyle(workspace.isActive ? Color.hyprBackground : Color.hyprTextPrimary)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(workspace.hasFloatingWindows ? config.resolvedFloatingColor : Color.clear, lineWidth: 1.5))
                    }.buttonStyle(.plain).disabled(!config.enabled).help("Switch to \(UserConfig.workspaceDisplayName(workspace.id, names: config.workspaceNames, fallback: "workspace \(workspace.id)"))")
                }
            }
        }
        .padding(.horizontal, HyprSpacing.md)
        .padding(.vertical, HyprSpacing.sm)
    }

    // MARK: actions

    private var actions: some View {
        VStack(spacing: 1) {
            MenuBarRow("Keybinds", icon: "keyboard") {
                appDelegate.windowManager?.handleAction(.showKeybinds)
            } trailing: {
                if let binding = config.keybinds.first(where: { $0.action == .showKeybinds }) {
                    KeybadgeView(bind: binding, fontSize: 11)
                }
            }
            MenuBarRow("Workspace overview", icon: "rectangle.grid.3x2") {
                appDelegate.windowManager?.handleAction(.showWorkspaceOverview)
            } trailing: {
                if let binding = config.keybinds.first(where: { $0.action == .showWorkspaceOverview }) {
                    KeybadgeView(bind: binding, fontSize: 11)
                }
            }
            MenuBarRow("Settings…", icon: "gearshape") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            MenuBarRow("Tutorial", icon: "sparkles") {
                appDelegate.showTour()
            }
            MenuBarRow("Retile all spaces", icon: "rectangle.3.group") {
                NotificationCenter.default.post(name: .hyprMacRetileAll, object: nil)
            } trailing: {
                if let binding = config.keybinds.first(where: { $0.action == .retileAll }) {
                    KeybadgeView(bind: binding, fontSize: 11)
                }
            }
            #if !HYPRMAC_DEBUG_VARIANT
            MenuBarRow("Check for updates…", icon: "arrow.down.circle") {
                updater.checkForUpdates()
            } trailing: {
                Text("v\(appVersion)")
                    .font(.hyprMonoXs)
                    .foregroundStyle(Color.hyprTextTertiary)
            }
            #endif
            Rectangle()
                .fill(Color.hyprSeparator)
                .frame(height: 0.5)
                .padding(.vertical, HyprSpacing.xs)
            MenuBarRow("Quit HyprMac", icon: "power", destructive: true) {
                NSApp.terminate(nil)
            }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}

// MARK: - menu row

private struct MenuBarRow<Trailing: View>: View {
    let label: String
    let icon: String
    let shortcut: String?
    let destructive: Bool
    let action: () -> Void
    let trailing: () -> Trailing

    @State private var hovering = false

    init(_ label: String,
         icon: String,
         shortcut: String? = nil,
         destructive: Bool = false,
         action: @escaping () -> Void,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.label = label
        self.icon = icon
        self.shortcut = shortcut
        self.destructive = destructive
        self.action = action
        self.trailing = trailing
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: HyprSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(destructive ? Color.red.opacity(0.85) : Color.hyprTextSecondary)
                    .frame(width: 16)
                Text(label)
                    .font(.hyprBody)
                    .foregroundStyle(destructive ? Color.red.opacity(0.95) : Color.hyprTextPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.hyprMono)
                        .foregroundStyle(Color.hyprTextSecondary)
                }
                trailing()
            }
            .padding(.horizontal, HyprSpacing.md)
            .padding(.vertical, HyprSpacing.sm - 1)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                    .fill(hovering ? Color.hyprTextTertiary.opacity(0.10) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(HyprMotion.snap, value: hovering)
    }
}

// Bridge for the menu bar label between WindowManager (which knows the
// workspace state but is not available at app init) and the SwiftUI
// MenuBarExtra label (which is built before WindowManager exists).
// WindowManager.updateMenuBarState writes to .shared after every poll;
// WorkspaceIndicatorLabel observes it.
class MenuBarState: ObservableObject {
    static let shared = MenuBarState()
    @Published var labelText = ""
    @Published var monitors: [MenuBarMonitorSnapshot] = []
    @Published var hasData = false
    /// Number of windows in the scratchpad (0 = hide the tray glyph).
    @Published var scratchpadCount = 0
    /// Whether the scratchpad layer is currently summoned (filled tray).
    @Published var scratchpadVisible = false
}

struct MenuBarMonitorSnapshot: Equatable, Identifiable {
    let id: Int
    let name: String
    let currentWorkspace: Int
    let isPortrait: Bool
    let workspaces: [MenuBarWorkspaceBadge]

    init(id: Int, name: String, currentWorkspace: Int, isPortrait: Bool,
         workspaces: [MenuBarWorkspaceBadge] = []) {
        self.id = id
        self.name = name
        self.currentWorkspace = currentWorkspace
        self.isPortrait = isPortrait
        self.workspaces = workspaces
    }
}

struct MenuBarWorkspaceBadge: Equatable, Identifiable {
    let id: Int
    let isActive: Bool
    let isOccupied: Bool
    let hasFloatingWindows: Bool
}

enum MenuBarPresentation {
    static func workspaceBadgeRows(_ badges: [MenuBarWorkspaceBadge]) -> [[MenuBarWorkspaceBadge]] {
        stride(from: 0, to: badges.count, by: 5).map { start in
            Array(badges[start..<min(start + 5, badges.count)])
        }
    }

    static func workspaceGlyphs(active: Set<Int>, occupied: Set<Int>,
                                floating: Set<Int>) -> String {
        let lastWorkspace = max(active.max() ?? 1, occupied.max() ?? 1)
        return (1...lastWorkspace).map { workspace in
            if active.contains(workspace) {
                return floating.contains(workspace) ? "◆" : "■"
            }
            if occupied.contains(workspace) {
                return floating.contains(workspace) ? "◇" : "□"
            }
            return "·"
        }.joined(separator: " ")
    }

    static func monitorSummary(_ monitors: [MenuBarMonitorSnapshot], names: [String: String]) -> String {
        monitors.map { "\($0.name): \(UserConfig.workspaceDisplayName($0.currentWorkspace, names: names))" }
            .joined(separator: "\n")
    }

    static func showsWorkspaceState(enabled: Bool, indicatorEnabled: Bool,
                                    hasData: Bool, monitors: [MenuBarMonitorSnapshot],
                                    scratchpadCount: Int) -> Bool {
        enabled && indicatorEnabled && hasData
            && (!monitors.isEmpty || scratchpadCount > 0)
    }

    static func showsIndicator(indicatorEnabled: Bool, hasData: Bool,
                               labelText: String, scratchpadCount: Int) -> Bool {
        indicatorEnabled && hasData && (!labelText.isEmpty || scratchpadCount > 0)
    }
}

// Compact workspace glyphs remain visible while tiling is paused.
struct WorkspaceIndicatorLabel: View {
    @ObservedObject private var config = UserConfig.shared
    @ObservedObject private var state = MenuBarState.shared

    var body: some View {
        if MenuBarPresentation.showsIndicator(
            indicatorEnabled: config.showMenuBarIndicator,
            hasData: state.hasData,
            labelText: state.labelText,
            scratchpadCount: state.scratchpadCount) {
            HStack(spacing: 5) {
                if !state.labelText.isEmpty {
                    Text(state.labelText)
                        .font(.system(size: 12, weight: .regular))
                }
                if state.scratchpadCount > 0 {
                    Image(systemName: state.scratchpadVisible ? "tray.fill" : "tray")
                    if state.scratchpadCount > 1 {
                        Text("\(state.scratchpadCount)")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
            }
            .help(MenuBarPresentation.monitorSummary(state.monitors, names: config.workspaceNames))
        } else {
            Image(systemName: "rectangle.split.2x2")
        }
    }
}

extension Notification.Name {
    static let hyprMacRetileAll = Notification.Name("hyprMacRetileAll")
    static let hyprMacWorkspaceChanged = Notification.Name("hyprMacWorkspaceChanged")
    // posted once per dispatched hotkey action; Tour's try-it hint observes it
    static let hyprMacActionDispatched = Notification.Name("hyprMacActionDispatched")
}
