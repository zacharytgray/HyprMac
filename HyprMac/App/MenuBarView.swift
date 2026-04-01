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

            Button("Retile Current Space") {
                NotificationCenter.default.post(name: .hyprMacRetile, object: nil)
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

        if let ws = ws {
            ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { idx, screen in
                let active = ws.workspaceForScreen(screen)
                HStack(spacing: 4) {
                    Text("Screen \(idx + 1):")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ForEach(1...9, id: \.self) { num in
                        Text("\(num)")
                            .font(.caption2.monospaced())
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(num == active ? Color.accentColor : Color.clear)
                            .foregroundColor(num == active ? .white : .secondary)
                            .cornerRadius(3)
                    }
                }
            }
        }
    }
}

extension Notification.Name {
    static let hyprMacRetile = Notification.Name("hyprMacRetile")
    static let hyprMacWorkspaceChanged = Notification.Name("hyprMacWorkspaceChanged")
}
