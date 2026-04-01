import SwiftUI
import Sparkle

@main
struct HyprMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        MenuBarExtra("HyprMac", systemImage: "rectangle.split.2x2") {
            MenuBarView(updater: updaterController.updater)
        }
        .menuBarExtraStyle(.window)

        Window("HyprMac Settings", id: "settings") {
            SettingsView()
        }
        .defaultSize(width: 600, height: 500)
    }
}
