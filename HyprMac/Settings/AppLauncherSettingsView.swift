import SwiftUI

struct AppLauncherSettingsView: View {
    @ObservedObject var config = UserConfig.shared

    // filter to just app launcher keybinds
    private var launcherBinds: [Keybind] {
        config.keybinds.filter {
            if case .launchApp = $0.action { return true }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bind hotkeys to launch or focus applications.")
                .font(.caption)
                .foregroundColor(.secondary)

            List {
                ForEach(launcherBinds) { bind in
                    HStack {
                        Text(bind.displayString)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 120, alignment: .leading)

                        if case .launchApp(let bundleID) = bind.action {
                            Text(appName(for: bundleID))
                            Spacer()
                            Text(bundleID)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            HStack {
                Text("Edit app launchers in the Keybinds tab or config file.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding()
    }

    private func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }
}
