// SwiftUI app entry. Composes the menu bar item and settings scene.
// Real lifecycle work lives in `AppDelegate`.

import SwiftUI
#if !HYPRMAC_DEBUG_VARIANT
import Sparkle
#endif

/// SwiftUI app shell.
@main
struct HyprMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #if !HYPRMAC_DEBUG_VARIANT
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif

    var body: some Scene {
        MenuBarExtra {
            #if HYPRMAC_DEBUG_VARIANT
            MenuBarView()
            #else
            MenuBarView(updater: updaterController.updater)
            #endif
        } label: {
            WorkspaceIndicatorLabel()
        }
        .menuBarExtraStyle(.window)

        Window("HyprMac Settings", id: "settings") {
            SettingsView()
        }
        .defaultSize(width: 760, height: 600)
    }
}
