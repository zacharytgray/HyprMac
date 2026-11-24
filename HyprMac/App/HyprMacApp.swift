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
    // per Mac, hidden removes the menu bar item. reopening the app shows Settings
    @AppStorage private var menuBarStyle: MenuBarStyle

    // one time, from the old Show in menu bar and workspace indicator toggles.
    // skipped in a hosted test run, which uses the real app's defaults
    private static func migrateMenuBarStyle() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: UserConfig.menuBarStyleKey) == nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let showIcon = defaults.object(forKey: UserConfig.showMenuBarIconKey) as? Bool ?? true
        // the indicator only matters while the icon is on
        let showIndicator = showIcon ? UserConfig.shared.showMenuBarIndicator : true
        let style = MenuBarStyle.migrated(showIcon: showIcon, showIndicator: showIndicator)
        defaults.set(style.rawValue, forKey: UserConfig.menuBarStyleKey)
    }

    // macOS sets this false when the user ⌘-drags the item out of the bar
    private var menuBarInserted: Binding<Bool> {
        Binding(get: { menuBarStyle != .hidden }, set: { inserted in
            if !inserted {
                menuBarStyle = .hidden
            } else if menuBarStyle == .hidden {
                menuBarStyle = .full
            }
        })
    }

    init() {
        // a copy started only to answer whether Screen Recording is granted
        ScreenRecordingAccess.answerFreshCheckIfAsked()
        // a second copy leaves here, before Sparkle or the menu bar item start
        SingleInstance.claimOrExit()
        // before the scene's storage is built, so it reads the migrated value
        Self.migrateMenuBarStyle()
        _menuBarStyle = AppStorage(wrappedValue: .full, UserConfig.menuBarStyleKey)
        #if !HYPRMAC_DEBUG_VARIANT
        // the first touch of the shared controller starts the updater
        updates = UpdateController.shared
        #endif
    }

    var body: some Scene {
        MenuBarExtra(isInserted: menuBarInserted) {
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
            SettingsView(showTutorial: { appDelegate.showTutorial() })
            #else
            SettingsView(showTutorial: { appDelegate.showTutorial() })
                .environment(\.updateController, updates)
            #endif
        }
        .defaultSize(width: 760, height: 600)
    }
}
