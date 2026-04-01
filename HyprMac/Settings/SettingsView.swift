import SwiftUI

struct SettingsView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
                .tag(0)

            KeybindsSettingsView()
                .tabItem { Label("Keybinds", systemImage: "keyboard") }
                .tag(1)

            AppLauncherSettingsView()
                .tabItem { Label("App Launcher", systemImage: "app.badge") }
                .tag(2)

            TilingSettingsView()
                .tabItem { Label("Tiling", systemImage: "rectangle.split.2x2") }
                .tag(3)
        }
        .frame(minWidth: 550, minHeight: 400)
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
