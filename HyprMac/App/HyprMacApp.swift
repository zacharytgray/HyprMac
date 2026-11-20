// SwiftUI app entry. Composes the menu bar item and settings scene.
// Real lifecycle work lives in `AppDelegate`.

import SwiftUI

/// SwiftUI app shell.
@main
struct HyprMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #if !HYPRMAC_DEBUG_VARIANT
    // set in init, after the single-instance guard: a default value here
    // would start Sparkle before the guard runs
    private let updates: UpdateController
    #endif
    // per Mac, off removes the menu bar item. reopening the app shows Settings
    @AppStorage(UserConfig.showMenuBarIconKey) private var showMenuBarIcon = true

    init() {
        // a second copy leaves here, before Sparkle or the menu bar item start
        SingleInstance.claimOrExit()
        #if !HYPRMAC_DEBUG_VARIANT
        // the first touch of the shared controller starts the updater
        updates = UpdateController.shared
        #endif
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            #if HYPRMAC_DEBUG_VARIANT
            MenuBarView(appDelegate: appDelegate)
            #else
            MenuBarView(appDelegate: appDelegate, updates: updates)
            #endif
        } label: {
            WorkspaceIndicatorLabel()
        }
        .menuBarExtraStyle(.window)

        Window("HyprMac Settings", id: "settings") {
            #if HYPRMAC_DEBUG_VARIANT
            SettingsView(showTutorial: { appDelegate.showTour() })
            #else
            SettingsView(showTutorial: { appDelegate.showTour() })
                .environment(\.updateController, updates)
            #endif
        }
        .defaultSize(width: 760, height: 600)
    }
}
