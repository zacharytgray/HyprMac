import SwiftUI

struct MenuBarView: View {
    @ObservedObject var config = UserConfig.shared
    @Environment(\.openWindow) private var openWindow

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

            Toggle("Enabled", isOn: $config.enabled)

            Button("Settings...") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }

            Button("Retile Current Space") {
                NotificationCenter.default.post(name: .hyprMacRetile, object: nil)
            }

            Divider()

            Text("Spaces: \(SpaceManager().getAllSpaceIDs().count)")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            Button("Quit HyprMac") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 200)
    }
}

extension Notification.Name {
    static let hyprMacRetile = Notification.Name("hyprMacRetile")
}
