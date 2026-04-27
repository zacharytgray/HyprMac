// AppDelegate. Owns the AX permission gate, the `WindowManager`
// instance, and the welcome / what's-new flow that runs at first
// launch and across version bumps.

import Cocoa

/// Application lifecycle delegate.
///
/// At launch: gates on AX permission (prompting if missing), starts
/// the `WindowManager`, and decides whether to show onboarding,
/// welcome, or what's-new based on previous launch state. At quit:
/// stops the manager and restores the Caps Lock remap.
class AppDelegate: NSObject, NSApplicationDelegate {
    var windowManager: WindowManager?
    private var welcomeController: WelcomeWindowController?

    /// AX permission gate plus the rest of startup. Trusted →
    /// applies the Hypr key remap and starts the manager. Not
    /// trusted → prompts for AX, then offers a quit-or-retry alert
    /// after the user toggles the setting.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        hyprLog(.debug, .lifecycle, "bundle: \(Bundle.main.bundleIdentifier ?? "?")")
        hyprLog(.debug, .lifecycle, "AXIsProcessTrusted=\(AXIsProcessTrusted())")

        if AXIsProcessTrusted() {
            KeyRemapper.applyHyprKey(UserConfig.shared.hyprKey)
            startWindowManager()
        } else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)

            let alert = NSAlert()
            alert.messageText = "HyprMac Needs Accessibility Permission"
            alert.informativeText = "Grant access in System Settings → Privacy & Security → Accessibility, then relaunch HyprMac."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Quit & Relaunch")
            alert.addButton(withTitle: "I Already Granted It — Retry")
            let response = alert.runModal()

            if response == .alertSecondButtonReturn && AXIsProcessTrusted() {
                KeyRemapper.applyHyprKey(UserConfig.shared.hyprKey)
                startWindowManager()
            } else {
                NSApp.terminate(nil)
            }
        }
    }

    /// Construct `WindowManager`, start it when the user has not
    /// disabled HyprMac in config, and run the first-launch /
    /// version-bump welcome decision.
    func startWindowManager() {
        let config = UserConfig.shared
        windowManager = WindowManager(config: config)
        if config.enabled {
            windowManager?.start()
        }
        checkFirstLaunchOrUpdate()
    }

    private func checkFirstLaunchOrUpdate() {
        let hasSeenOnboarding = UserDefaults.standard.bool(forKey: "hasSeenOnboarding")
        let lastVersion = UserDefaults.standard.string(forKey: "lastSeenVersion")
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

        if !hasSeenOnboarding {
            // first time ever — show onboarding tutorial
            showWelcome(mode: .onboarding)
            UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
        } else if lastVersion == nil {
            // existing user who never had version tracking — show welcome
            showWelcome(mode: .welcome)
        } else if lastVersion != currentVersion {
            showWelcome(mode: .whatsNew)
        }

        UserDefaults.standard.set(currentVersion, forKey: "lastSeenVersion")
    }

    /// Public entry for the menu-bar "Show Onboarding" action.
    func showOnboarding() {
        showWelcome(mode: .onboarding)
    }

    private func showWelcome(mode: WelcomeMode) {
        // small delay so tiling engine settles first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            let controller = WelcomeWindowController()
            controller.show(mode: mode)
            self?.welcomeController = controller
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowManager?.stop()
        // restore caps lock to normal when quitting
        KeyRemapper.restoreCapsLock()
    }
}
