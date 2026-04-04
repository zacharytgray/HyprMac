import SwiftUI
import Sparkle

struct MenuBarView: View {
    @ObservedObject var config = UserConfig.shared
    @Environment(\.openWindow) private var openWindow
    @State private var refreshID = UUID()
    let updater: SPUUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(config.enabled ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(config.enabled ? "HyprMac Active" : "HyprMac Disabled")
                    .font(.headline)
            }

            Divider()

            // workspace indicators per screen
            workspaceStatus
                .id(refreshID)

            Divider()

            Toggle("Enabled", isOn: $config.enabled)

            Button("Settings...") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }

            Button("Retile All Spaces") {
                NotificationCenter.default.post(name: .hyprMacRetileAll, object: nil)
            }

            Button("Check for Updates...") {
                updater.checkForUpdates()
            }

            Divider()

            Button("Quit HyprMac") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 200)
        .onReceive(NotificationCenter.default.publisher(for: .hyprMacWorkspaceChanged)) { _ in
            refreshID = UUID()
        }
    }

    @ViewBuilder
    private var workspaceStatus: some View {
        let delegate = NSApp.delegate as? AppDelegate
        let wm = delegate?.windowManager
        let ws = wm?.workspaceManager
        let occupied = MenuBarState.shared.occupiedWorkspaces
        let floatingWs = MenuBarState.shared.floatingWorkspaces

        if let ws = ws {
            ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { idx, screen in
                let active = ws.workspaceForScreen(screen)
                let maxWs = max(active, occupied.max() ?? 1, 3)
                HStack(spacing: 3) {
                    Image(systemName: "display")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    if NSScreen.screens.count > 1 {
                        Text("\(idx + 1)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    ForEach(1...maxWs, id: \.self) { num in
                        let hasFloat = floatingWs.contains(num)
                        HStack(spacing: 1) {
                            Text("\(num)")
                                .font(.system(size: 10, weight: num == active ? .semibold : .regular, design: .rounded))
                            if hasFloat {
                                Text("◇")
                                    .font(.system(size: 7))
                            }
                        }
                        .frame(minWidth: 18, minHeight: 18)
                        .padding(.horizontal, hasFloat ? 2 : 0)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(num == active ? Color.accentColor :
                                      occupied.contains(num) ? Color.secondary.opacity(0.12) : Color.clear)
                        )
                        .foregroundColor(num == active ? .white :
                                         occupied.contains(num) ? .primary : .secondary.opacity(0.3))
                    }
                }
            }
        }
    }
}

// shared observable for menu bar label — updated by WindowManager,
// observed by WorkspaceIndicatorLabel. this bridges the gap between
// WindowManager (not available at app init) and the MenuBarExtra label.
class MenuBarState: ObservableObject {
    static let shared = MenuBarState()
    @Published var labelText: String = ""
    @Published var occupiedWorkspaces: Set<Int> = []
    @Published var floatingWorkspaces: Set<Int> = []
    @Published var hasData = false
}

// compact menu bar label: dots for workspace state, ◇ for floating.
// position = workspace number, ● active, ○ occupied, · empty.
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
