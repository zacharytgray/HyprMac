// AppDelegate. Owns the `WindowManager` instance, the stage (onboarding,
// the Access step and the tutorial) and the What's New window an update
// shows.

import Cocoa

/// Application lifecycle delegate.
///
/// At launch: waits for AX permission on the stage when it's missing,
/// starts the `WindowManager`, and decides between onboarding (fresh
/// install only) and What's New (after an update). At quit: stops the
/// manager and restores the Caps Lock remap.
class AppDelegate: NSObject, NSApplicationDelegate {
    var windowManager: WindowManager?
    private var whatsNewController: WhatsNewWindowController?
    private var stage: StageSession?
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
            showAccessStage()
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
        // a crash in the tutorial's pause lesson left tiling off; on again
        // before the remap and the window manager read it
        PauseLessonModel.resumeOwnedPause(config: UserConfig.shared)
        // a launch while paused removes the remap, which also clears one a
        // killed copy left behind
        KeyRemapper.applyHyprKey(UserConfig.shared.hyprKey, enabled: UserConfig.shared.enabled)
        startWindowManager()
    }

    /// Access is missing: poll for the grant once per second and show the
    /// stage. A fresh install gets all of onboarding from Access; a Mac
    /// that's already set up gets the Access step alone. On grant the poll
    /// live-starts HyprMac, with no relaunch.
    private func showAccessStage() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard AXIsProcessTrusted() else { return }
            hyprLog(.notice, .lifecycle, "AX permission granted — starting")
            self?.permissionPollTimer?.invalidate()
            self?.permissionPollTimer = nil
            self?.startAfterPermissionGranted()
            self?.stage?.noteAccessGranted()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer

        if alreadyOnboarded {
            presentStage(.accessOnly())
        } else {
            presentStage(.onboarding(accessGranted: false, practiceHost: practiceHost))
        }
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
            self?.showTutorial()
        }
        // a tutorial cut short by a crash can leave its practice app's rule
        PracticeSession.removeRules(bundleID: PracticeSession.helperBundleID, from: config)
        // and its saved desk, which is dropped rather than put back
        windowManager?.discardTutorialDesk()
        if config.enabled {
            windowManager?.start()
        }
        checkFirstLaunchOrUpdate()
    }

    /// Read once per launch, before this launch writes its own flags.
    private lazy var alreadyOnboarded: Bool = RuntimeVariant.alreadyOnboarded(
        hasSeenOnboarding: RuntimeVariant.inheritedBool(forKey: "hasSeenOnboarding"),
        lastVersion: UserDefaults.standard.string(forKey: "lastSeenVersion"),
        hadConfigFile: UserConfig.shared.hadConfigFileAtLoad)

    private func checkFirstLaunchOrUpdate() {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let mode = Self.forcesOnboarding ? .onboarding : RuntimeVariant.shouldShowWelcome(
            alreadyOnboarded: alreadyOnboarded,
            lastVersion: UserDefaults.standard.string(forKey: "lastSeenVersion"),
            currentVersion: currentVersion)

        if let mode {
            // small delay so the tiling engine settles first
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.present(mode)
            }
        }
        UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
        UserDefaults.standard.set(currentVersion, forKey: "lastSeenVersion")
    }

    /// Debug app only: `--force-onboarding` runs onboarding on a Mac that's
    /// set up. Make it yours writes real settings, so back them up first.
    private static var forcesOnboarding: Bool {
        #if HYPRMAC_DEBUG_VARIANT
        return CommandLine.arguments.contains("--force-onboarding")
        #else
        return false
        #endif
    }

    private func present(_ mode: WelcomeMode) {
        switch mode {
        case .onboarding:
            // a fresh install without access is on the stage already
            presentStage(.onboarding(accessGranted: true, practiceHost: practiceHost))
        case .whatsNew:
            whatsNewController?.dismiss()
            let controller = WhatsNewWindowController()
            whatsNewController = controller
            controller.show()
        }
    }

    /// The menu bar, Hypr+K and Settings → General open the tutorial here.
    func showTutorial() {
        hyprLog(.debug, .lifecycle, "tutorial requested")
        // back at the lesson a run was left on, if one was
        presentStage(.tutorial(practiceHost: practiceHost, resume: TutorialResume.load()))
    }

    /// the window manager starts after access, so look it up late
    private var practiceHost: PracticeHost { LatePracticeHost { [weak self] in self?.windowManager } }

    /// The full-screen stage, one at a time.
    private func presentStage(_ session: StageSession) {
        guard stage?.isShowing != true else { return }
        whatsNewController?.dismiss()
        // the user's desk, written when the tutorial starts and put back on
        // every way out, after the practice cleanup
        session.onTutorialStart = { [weak self] in self?.windowManager?.snapshotDeskForTutorial() }
        session.onClose = { [weak self, weak session] in
            if session?.tutorialStarted == true { self?.windowManager?.restoreDeskAfterTutorial() }
            self?.stage = nil
        }
        session.onQuit = { [weak self] in
            self?.permissionPollTimer?.invalidate()
            self?.permissionPollTimer = nil
            NSApp.terminate(nil)
        }
        stage = session
        session.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !diagnosticOnly else { return }
        // a lesson left by quitting is where the tutorial opens next time;
        // then the helper, its rules and its workspace go
        stage?.noteLeaving()
        stage?.cleanUp()
        if stage?.tutorialStarted == true { windowManager?.restoreDeskAfterTutorial() }
        windowManager?.stop(keepPauseShortcut: false)
        // restore caps lock to normal when quitting
        KeyRemapper.restoreCapsLock()
    }
}
