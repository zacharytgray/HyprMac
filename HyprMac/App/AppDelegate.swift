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
    private var permissionsGate: PermissionsGateWindowController?
    private var permissionPollTimer: Timer?
    private var diagnosticOnly = false

    /// `hyprmac://` links from a status bar or another app. A raw Apple
    /// Event handler, so SwiftUI never sees the URL and opens no window for it.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
        guard let url = URL(string: text), let command = ExternalCommand.parse(url) else {
            // a typo in another app's config should be findable in the log
            hyprLog(.notice, .lifecycle, "hyprmac:// link not understood: \(text.prefix(200))")
            return
        }
        windowManager?.handleExternalURL(command)
    }

    /// AX permission gate plus the rest of startup. Trusted →
    /// applies the Hypr key remap and starts the manager. Not
    /// trusted → shows the permissions gate and polls until the
    /// grant lands, then starts automatically. No relaunch needed:
    /// TCC flips `AXIsProcessTrusted` live for a running process.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        hyprLog(.debug, .lifecycle, "bundle: \(Bundle.main.bundleIdentifier ?? "?")")
        hyprLog(.debug, .lifecycle, "AXIsProcessTrusted=\(AXIsProcessTrusted())")

        #if HYPRMAC_DEBUG_VARIANT
        if CommandLine.arguments.contains("--request-accessibility") {
            diagnosticOnly = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
            print("HyprMac accessibility request trusted=\(trusted) bundle=\(Bundle.main.bundleIdentifier ?? "?")")
            fflush(stdout)
            NSApp.terminate(nil)
            return
        }

        if CommandLine.arguments.contains("--check-accessibility") {
            diagnosticOnly = true
            let trusted = AXIsProcessTrusted()
            print("HyprMac accessibility trusted=\(trusted) bundle=\(Bundle.main.bundleIdentifier ?? "?")")
            fflush(stdout)
            NSApp.terminate(nil)
            return
        }
        #endif

        #if DEBUG
        if OverlayPreview.isRequested {
            diagnosticOnly = true
            OverlayPreview.run()
            return
        }
        #endif

        // one-shot frame diagnostic. runs before anything starts, so no
        // window manager and no key remap touch the machine.
        #if DEBUG
        if let probe = ProbeFrameArguments.parse(CommandLine.arguments) {
            switch probe {
            case let .success(arguments):
                ProbeFrame.run(arguments)
            case let .failure(reason):
                print("HyprMac --probe-frame: \(reason)")
                fflush(stdout)
                exit(1)
            }
        }
        #endif

        if AXIsProcessTrusted() {
            startAfterPermissionGranted()
        } else {
            showPermissionsGate()
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

    /// Show the non-modal permissions gate and poll for the AX grant
    /// once per second. The gate shows live status with a Grant button;
    /// on grant the poll live-starts HyprMac and dismisses the gate —
    /// no relaunch, no further clicks. The gate's Quit button terminates.
    private func showPermissionsGate() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard AXIsProcessTrusted() else { return }
            hyprLog(.notice, .lifecycle, "AX permission granted — starting")
            self?.permissionPollTimer?.invalidate()
            self?.permissionPollTimer = nil
            self?.startAfterPermissionGranted()
            self?.permissionsGate?.markAccessibilityGrantedAndDismiss()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer

        let gate = PermissionsGateWindowController()
        gate.show { [weak self] in
            self?.permissionPollTimer?.invalidate()
            self?.permissionPollTimer = nil
            NSApp.terminate(nil)
        }
        permissionsGate = gate
    }

    /// Construct `WindowManager`, start it when the user has not
    /// disabled HyprMac in config, and run the first-launch /
    /// version-bump welcome decision.
    func startWindowManager() {
        let config = UserConfig.shared
        windowManager = WindowManager(config: config)
        windowManager?.keybindOverlay.onShowTutorial = { [weak self] in
            self?.showTour()
        }
        if config.enabled {
            windowManager?.start()
        }
        checkFirstLaunchOrUpdate()
    }

    private func checkFirstLaunchOrUpdate() {
        let hasSeenOnboarding = RuntimeVariant.inheritedBool(forKey: "hasSeenOnboarding")
        let lastVersion = UserDefaults.standard.string(forKey: "lastSeenVersion")
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

        if let mode = RuntimeVariant.shouldShowWelcome(
            hasSeenOnboarding: hasSeenOnboarding,
            lastVersion: lastVersion,
            currentVersion: currentVersion
        ) {
            showWelcome(mode: mode)
        }
        if !hasSeenOnboarding {
            UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
        }

        UserDefaults.standard.set(currentVersion, forKey: "lastSeenVersion")
    }

    /// Public entry for replaying the first-run tour from Settings.
    func showTour() {
        hyprLog(.debug, .lifecycle, "tutorial requested")
        presentWelcome(mode: .firstRun)
    }

    private func showWelcome(mode: WelcomeMode) {
        // small delay so tiling engine settles first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.presentWelcome(mode: mode)
        }
    }

    private func presentWelcome(mode: WelcomeMode) {
        welcomeController?.dismiss()
        let controller = WelcomeWindowController()
        welcomeController = controller
        controller.show(mode: mode)
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !diagnosticOnly else { return }
        windowManager?.stop(keepPauseShortcut: false)
        // restore caps lock to normal when quitting
        KeyRemapper.restoreCapsLock()
    }
}
