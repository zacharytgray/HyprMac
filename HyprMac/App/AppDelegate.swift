import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var windowManager: WindowManager?
    private var welcomeController: WelcomeWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        print("[HyprMac] bundle: \(Bundle.main.bundleIdentifier ?? "?")")
        print("[HyprMac] AXIsProcessTrusted=\(AXIsProcessTrusted())")

        if AXIsProcessTrusted() {
            // remap caps lock → F18 at driver level
            KeyRemapper.remapCapsLockToF18()
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
                KeyRemapper.remapCapsLockToF18()
                startWindowManager()
            } else {
                NSApp.terminate(nil)
            }
        }
    }

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
