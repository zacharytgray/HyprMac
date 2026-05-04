// Menu bar dropdown contents and the compact dot-grid label that
// lives in the menu bar itself.

import SwiftUI
import Sparkle

/// `MenuBarExtra` dropdown contents: status header, per-screen
/// workspace badges, and standard actions (Settings, Retile, Check
/// for Updates, Quit). Restyled to match the settings window — same
/// surface treatment, mono accent typography, cyan active-state
/// indicator. The label rendered in the menu bar itself is
/// `WorkspaceIndicatorLabel` (below).
struct MenuBarView: View {
    @ObservedObject var config = UserConfig.shared
    @Environment(\.openWindow) private var openWindow
    @State private var refreshID = UUID()
    let updater: SPUUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: HyprSpacing.md) {
            header
            workspacePanel
                .id(refreshID)
            actions
        }
        .padding(HyprSpacing.md)
        .frame(width: 280)
        .background(Color.hyprBackground)
        .onReceive(NotificationCenter.default.publisher(for: .hyprMacWorkspaceChanged)) { _ in
            refreshID = UUID()
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: HyprSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("HYPRMAC")
                    .font(.hyprMono)
                    .kerning(2)
                    .foregroundStyle(Color.hyprTextPrimary)
                Text(config.enabled ? "Tiling active" : "Tiling paused")
                    .font(.hyprMonoXs)
                    .foregroundStyle(config.enabled ? Color.hyprCyan : Color.hyprTextTertiary)
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
        let delegate = NSApp.delegate as? AppDelegate
        let wm = delegate?.windowManager
        let ws = wm?.workspaceManager
        let occupied = MenuBarState.shared.occupiedWorkspaces
        let floatingWs = MenuBarState.shared.floatingWorkspaces

        if let ws = ws {
            HyprPanel("Workspaces") {
                ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { idx, screen in
                    let active = ws.workspaceForScreen(screen)
                    let maxWs = max(active, occupied.max() ?? 1, 3)
                    workspaceRow(
                        screenIndex: idx,
                        screenCount: NSScreen.screens.count,
                        active: active,
                        maxWs: maxWs,
                        occupied: occupied,
                        floatingWs: floatingWs,
                        isLast: idx == NSScreen.screens.count - 1
                    )
                }
            }
        }
    }

    private func workspaceRow(screenIndex idx: Int,
                              screenCount: Int,
                              active: Int,
                              maxWs: Int,
                              occupied: Set<Int>,
                              floatingWs: Set<Int>,
                              isLast: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: HyprSpacing.sm) {
                Image(systemName: "display")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.hyprTextSecondary)
                if screenCount > 1 {
                    Text("\(idx + 1)")
                        .font(.hyprMonoXs)
                        .foregroundStyle(Color.hyprTextSecondary)
                }
                Spacer(minLength: HyprSpacing.sm)
                HStack(spacing: 2) {
                    ForEach(1...maxWs, id: \.self) { num in
                        workspaceBadge(
                            num: num,
                            active: num == active,
                            occupied: occupied.contains(num),
                            floating: floatingWs.contains(num)
                        )
                    }
                }
            }
            .padding(.horizontal, HyprSpacing.md)
            .padding(.vertical, HyprSpacing.sm)

            if !isLast {
                Rectangle()
                    .fill(Color.hyprSeparator)
                    .frame(height: 0.5)
                    .padding(.leading, HyprSpacing.md)
            }
        }
    }

    private func workspaceBadge(num: Int, active: Bool, occupied: Bool, floating: Bool) -> some View {
        HStack(spacing: 1) {
            Text("\(num)")
                .font(.hyprMonoSm)
            if floating {
                Text("◇").font(.system(size: 8))
            }
        }
        .frame(minWidth: 20, minHeight: 18)
        .padding(.horizontal, floating ? 2 : 0)
        .foregroundStyle(active ? Color.hyprCyan
                         : occupied ? Color.hyprTextPrimary
                         : Color.hyprTextTertiary)
        .background(
            RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                .fill(active ? Color.hyprCyan.opacity(0.18)
                      : occupied ? Color.hyprSurfaceElevated
                      : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HyprRadius.sm, style: .continuous)
                .strokeBorder(active ? Color.hyprCyan.opacity(0.55)
                              : occupied ? Color.hyprSeparator
                              : Color.clear,
                              lineWidth: 0.5)
        )
    }

    // MARK: actions

    private var actions: some View {
        VStack(spacing: 1) {
            MenuBarRow("Settings…", icon: "gearshape", shortcut: "⌘,") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            MenuBarRow("Retile all spaces", icon: "rectangle.3.group") {
                NotificationCenter.default.post(name: .hyprMacRetileAll, object: nil)
            }
            MenuBarRow("Check for updates…", icon: "arrow.down.circle") {
                updater.checkForUpdates()
            }
            Rectangle()
                .fill(Color.hyprSeparator)
                .frame(height: 0.5)
                .padding(.vertical, HyprSpacing.xs)
            MenuBarRow("Quit HyprMac", icon: "power", shortcut: "⌘Q", destructive: true) {
                NSApp.terminate(nil)
            }
        }
    }
}

// MARK: - menu row

private struct MenuBarRow: View {
    let label: String
    let icon: String
    let shortcut: String?
    let destructive: Bool
    let action: () -> Void

    @State private var hovering = false

    init(_ label: String,
         icon: String,
         shortcut: String? = nil,
         destructive: Bool = false,
         action: @escaping () -> Void) {
        self.label = label
        self.icon = icon
        self.shortcut = shortcut
        self.destructive = destructive
        self.action = action
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
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.hyprMono)
                        .foregroundStyle(Color.hyprTextSecondary)
                }
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
    @Published var labelText: String = ""
    @Published var occupiedWorkspaces: Set<Int> = []
    @Published var floatingWorkspaces: Set<Int> = []
    @Published var hasData = false
}

// Compact dot-grid menu bar label, one symbol per workspace 1..N where N
// is the highest occupied (or active) workspace. Encoding:
//   ●  active workspace
//   ◆  active workspace, contains floating window(s)
//   ○  occupied (has windows) but not active
//   ◇  occupied + floating, not active
//   ·  empty
// String is computed by WindowManager.updateMenuBarState and pushed via
// MenuBarState.labelText. Falls back to a static icon if disabled or if
// no workspace data has been seen yet.
struct WorkspaceIndicatorLabel: View {
    @ObservedObject private var config = UserConfig.shared
    @ObservedObject private var state = MenuBarState.shared

    var body: some View {
        if config.showMenuBarIndicator, state.hasData, !state.labelText.isEmpty {
            Text(state.labelText)
                .font(.system(size: 12, weight: .regular))
        } else {
            Image(systemName: "rectangle.split.2x2")
        }
    }
}

extension Notification.Name {
    static let hyprMacRetileAll = Notification.Name("hyprMacRetileAll")
    static let hyprMacWorkspaceChanged = Notification.Name("hyprMacWorkspaceChanged")
}
