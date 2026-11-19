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
    // Nix replaces the bundle on its own; Sparkle must not
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: !RuntimeVariant.updatesManagedByNix, updaterDelegate: nil, userDriverDelegate: nil)
    #endif
    // per Mac, off removes the menu bar item. reopening the app shows Settings
    @AppStorage(UserConfig.showMenuBarIconKey) private var showMenuBarIcon = true

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            #if HYPRMAC_DEBUG_VARIANT
            MenuBarView(appDelegate: appDelegate)
            #else
            MenuBarView(appDelegate: appDelegate, updater: updaterController.updater)
            #endif
        } label: {
            WorkspaceIndicatorLabel()
        }
        .menuBarExtraStyle(.window)

        Window("HyprMac Settings", id: "settings") {
            SettingsView(showTutorial: { appDelegate.showTour() })
        }
        .defaultSize(width: 760, height: 600)
    }
}
