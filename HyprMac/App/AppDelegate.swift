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
    private var stage: StageSession?
    private var permissionsGate: PermissionsGateWindowController?
    private var permissionPollTimer: Timer?
    private var diagnosticOnly = false
    private var dockIconObserver: NSObjectProtocol?
    private var terminateSignalSource: DispatchSourceSignal?

    /// `hyprmac://` links from a status bar or another app. A raw Apple
    /// Event handler, so SwiftUI never sees the URL and opens no window for it.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    // MARK: Dock and menu bar icons

    /// Activation policy for the Show in Dock setting. `.accessory` keeps
    /// HyprMac out of the Dock and ⌘-Tab. Info.plist sets `LSUIElement`, so
    /// launch and every later `open` of the running app start from
    /// `.accessory`. Without it, LaunchServices made the app `.regular`
    /// again each time it was opened.
    static func activationPolicy(showDockIcon: Bool) -> NSApplication.ActivationPolicy {
        showDockIcon ? .regular : .accessory
    }

    /// Apply the setting at launch and whenever it changes. The setting is
    /// read from UserDefaults so this runs before `UserConfig.shared` exists.
    private func installDockIconPolicy() {
        applyDockIconPolicy()
        dockIconObserver = NotificationCenter.default.addObserver(
            forName: .hyprMacDockIconChanged, object: nil, queue: .main) { [weak self] _ in
                self?.applyDockIconPolicy()
                // a policy switch can drop focus; keep Settings in front
                NSApp.activate(ignoringOtherApps: true)
            }
    }

    private func applyDockIconPolicy() {
        let showDockIcon = RuntimeVariant.inheritedBool(forKey: UserConfig.showDockIconKey)
        let wanted = Self.activationPolicy(showDockIcon: showDockIcon)
        let current = NSApp.activationPolicy()
        guard current != wanted else { return }
        hyprLog(.debug, .lifecycle, "activation policy \(current.rawValue) → \(wanted.rawValue) showDockIcon=\(showDockIcon)")
        NSApp.setActivationPolicy(wanted)
    }

    /// HyprMac runs until the user quits it. `MenuBarExtra(isInserted:)`
    /// makes SwiftUI answer true here, so closing the menu bar panel or
    /// Settings quit the app in v0.22.7.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Opening HyprMac again (Spotlight, Finder, a Dock click) shows
    /// Settings. With both icons hidden, this is the way back in.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !SettingsWindow.show() {
            hyprLog(.notice, .lifecycle, "reopen: no settings opener captured yet")
        }
        return false
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
        installDockIconPolicy()

        hyprLog(.debug, .lifecycle, "bundle: \(Bundle.main.bundleIdentifier ?? "?")")
        hyprLog(.debug, .lifecycle, "AXIsProcessTrusted=\(AXIsProcessTrusted())")
        hyprLog(.debug, .lifecycle, "Input Monitoring access=\(PhysicalKeyMonitor.accessDescription)")

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

        if CommandLine.arguments.contains("--check-input-monitoring") {
            diagnosticOnly = true
            print("HyprMac input monitoring access=\(PhysicalKeyMonitor.accessDescription) bundle=\(Bundle.main.bundleIdentifier ?? "?")")
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

        quitCleanlyOnSIGTERM()

        if AXIsProcessTrusted() {
            startAfterPermissionGranted()
        } else {
            showPermissionsGate()
        }
    }

    /// `kill`, launchd and a deploy script all stop HyprMac with SIGTERM.
    /// The default handler ends the process on the spot, so
    /// `applicationWillTerminate` never ran: Caps Lock stayed mapped to F18
    /// and hidden windows stayed parked. Route it through the normal quit.
    /// SIGKILL and a crash still skip it; the next launch or quit removes a
    /// remap they leave behind.
    private func quitCleanlyOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            hyprLog(.notice, .lifecycle, "SIGTERM — quitting")
            NSApp.terminate(nil)
        }
        source.resume()
        terminateSignalSource = source
    }

    private func startAfterPermissionGranted() {
        // bound every synchronous AX round-trip for this process. the
        // macOS default is ~6s per message — one busy app (compiler,
        // hung Electron) parks our main thread that long per call.
        // yabai and AeroSpace both run at 1s.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        // a launch while paused removes the remap, which also clears one a
        // killed copy left behind
        KeyRemapper.applyHyprKey(UserConfig.shared.hyprKey, enabled: UserConfig.shared.enabled)
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
            self?.stage?.noteAccessGranted()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer

        #if HYPRMAC_DEBUG_VARIANT
        if Self.usesNewTutorial {
            presentStage(.onboarding(accessGranted: false, practiceHost: practiceHost))
            return
        }
        #endif

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
        #if !HYPRMAC_DEBUG_VARIANT
        // the updater saves the desk before a relaunch and asks about fullscreen
        UpdateController.shared.windowManager = { [weak self] in self?.windowManager }
        #endif
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
        #if HYPRMAC_DEBUG_VARIANT
        // the full-screen tutorial, one lesson so far: Debug app only, and
        // only when launched with --new-tutorial
        if Self.usesNewTutorial {
            presentStage(.tutorial(practiceHost: practiceHost))
            return
        }
        #endif
        presentWelcome(mode: .firstRun)
    }

    #if HYPRMAC_DEBUG_VARIANT
    private static var usesNewTutorial: Bool { CommandLine.arguments.contains("--new-tutorial") }

    /// the window manager starts after access, so look it up late
    private var practiceHost: PracticeHost { LatePracticeHost { [weak self] in self?.windowManager } }

    /// The full-screen stage. Onboarding runs from the launch gate (or the
    /// first-run decision when access was already there); a replay opens
    /// the tutorial. One stage at a time.
    private func presentStage(_ session: StageSession) {
        guard stage?.isShowing != true else { return }
        welcomeController?.dismiss()
        session.onClose = { [weak self] in self?.stage = nil }
        session.onQuit = { [weak self] in
            self?.permissionPollTimer?.invalidate()
            self?.permissionPollTimer = nil
            NSApp.terminate(nil)
        }
        stage = session
        session.show()
    }
    #endif

    private func showWelcome(mode: WelcomeMode) {
        // small delay so tiling engine settles first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.presentWelcome(mode: mode)
        }
    }

    private func presentWelcome(mode: WelcomeMode) {
        #if HYPRMAC_DEBUG_VARIANT
        // the first-run decision lands here too; the tutorial already covers it
        if Self.usesNewTutorial, mode == .firstRun {
            presentStage(.onboarding(accessGranted: true, practiceHost: practiceHost))
            return
        }
        #endif
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
