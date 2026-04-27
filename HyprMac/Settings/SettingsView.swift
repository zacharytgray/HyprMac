import SwiftUI

// Top-level Settings shell: NavigationSplitView with a sidebar of tabs
// (General/Keybinds/App Launcher/Tiling) and a detail pane. The hosting
// NSWindow is bumped to .floating level via WindowLevelSetter so it
// stays above tiled HyprMac-managed windows while configuring.
struct SettingsView: View {
    @State private var selectedTab: SettingsTab? = .general

    enum SettingsTab: String, CaseIterable, Hashable {
        case general, keybinds, appLauncher, tiling

        var label: String {
            switch self {
            case .general:     return "General"
            case .keybinds:    return "Keybinds"
            case .appLauncher: return "App Launcher"
            case .tiling:      return "Tiling"
            }
        }

        var icon: String {
            switch self {
            case .general:     return "gear"
            case .keybinds:    return "keyboard"
            case .appLauncher: return "app.badge"
            case .tiling:      return "rectangle.split.2x2"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, id: \.self, selection: $selectedTab) { tab in
                Label(tab.label, systemImage: tab.icon)
                    .padding(.vertical, 2)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 168)
            .listStyle(.sidebar)
            .navigationTitle("HyprMac")
        } detail: {
            switch selectedTab ?? .general {
            case .general:     GeneralSettingsView()
            case .keybinds:    KeybindsSettingsView()
            case .appLauncher: AppLauncherSettingsView()
            case .tiling:      TilingSettingsView()
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .background(WindowLevelSetter())
    }
}

// sets the hosting NSWindow to floating level once it's available
private struct WindowLevelSetter: NSViewRepresentable {
    func makeNSView(context: Context) -> WLView { WLView() }
    func updateNSView(_ nsView: WLView, context: Context) {}

    class WLView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.level = .floating
        }
    }
}
