import SwiftUI

@main
struct HyprMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("HyprMac", systemImage: "rectangle.split.2x2") {
            MenuBarView()
        }
        .menuBarExtraStyle(.window)

        Window("HyprMac Settings", id: "settings") {
            SettingsView()
        }
        .defaultSize(width: 600, height: 500)
    }
}
