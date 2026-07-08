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
    private var permissionPollTimer: Timer?

    /// AX permission gate plus the rest of startup. Trusted →
    /// applies the Hypr key remap and starts the manager. Not
    /// trusted → prompts for AX and polls until the grant lands,
    /// then starts automatically. No relaunch needed: TCC flips
    /// `AXIsProcessTrusted` live for a running process.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        hyprLog(.debug, .lifecycle, "bundle: \(Bundle.main.bundleIdentifier ?? "?")")
        hyprLog(.debug, .lifecycle, "AXIsProcessTrusted=\(AXIsProcessTrusted())")

        if AXIsProcessTrusted() {
            startAfterPermissionGranted()
        } else {
            promptForAccessibility()
        }
    }

    private func startAfterPermissionGranted() {
        // bound every synchronous AX round-trip for this process. the
        // macOS default is ~6s per message — one busy app (compiler,
        // hung Electron) parks our main thread that long per call.
        // yabai and AeroSpace both run at 1s.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        KeyRemapper.applyHyprKey(UserConfig.shared.hyprKey)
        startWindowManager()
    }

    /// Show the system AX prompt plus an explanatory alert, and poll
    /// for the grant once per second. The poll runs in `.common` mode
    /// so it fires while the alert's modal session is up — granting
    /// in System Settings dismisses the alert and starts HyprMac with
    /// no further clicks.
    private func promptForAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard AXIsProcessTrusted() else { return }
            hyprLog(.notice, .lifecycle, "AX permission granted — starting")
            self?.permissionPollTimer?.invalidate()
            self?.permissionPollTimer = nil
            NSApp.abortModal()
            self?.startAfterPermissionGranted()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer

        let alert = NSAlert()
        alert.messageText = "HyprMac Needs Accessibility Permission"
        alert.informativeText = """
        Enable HyprMac in System Settings → Privacy & Security → Accessibility. \
        HyprMac starts automatically as soon as access is granted — no relaunch needed.

        If the toggle is already on, turn it off and back on: macOS invalidates \
        the grant when the app is rebuilt or updated. If there are multiple \
        HyprMac entries, remove the stale ones with the − button.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")
        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            // keep running — the poll starts HyprMac when the grant lands
            let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            if let url = URL(string: pane) {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            permissionPollTimer?.invalidate()
            permissionPollTimer = nil
            NSApp.terminate(nil)
        default:
            // .abort — the poll detected the grant and dismissed the alert;
            // startAfterPermissionGranted already ran from the timer.
            break
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
            // first time ever — first-run walkthrough
            showWelcome(mode: .firstRun)
            UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
        } else if lastVersion == nil {
            // existing user who never had version tracking — show what's new
            showWelcome(mode: .whatsNew)
        } else if lastVersion != currentVersion {
            showWelcome(mode: .whatsNew)
        }

        UserDefaults.standard.set(currentVersion, forKey: "lastSeenVersion")
    }

    /// Public entry for replaying the first-run tour from Settings.
    func showTour() {
        showWelcome(mode: .firstRun)
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
