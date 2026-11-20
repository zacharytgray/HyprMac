// Sparkle glue: the updater, the gentle reminder in the menu bar, the
// install that runs while the Mac is idle, and the updater windows' level.
// The debug variant has no Sparkle and leaves this file out.

#if !HYPRMAC_DEBUG_VARIANT
import Cocoa
import Sparkle
import SwiftUI

/// Owns the Sparkle updater and is its delegate.
///
/// - A scheduled check that finds an update does not open a window in the
///   middle of the user's work. It sets `UpdateState.shared.notice`, the
///   menu bar shows a dot, and the menu's update row opens the window.
///   Sparkle still shows the window itself right after launch.
/// - A downloaded update normally waits for a quit, and a window manager
///   is rarely quit. Sparkle hands over an install block instead, and
///   `IdleInstallPolicy` decides when to call it.
/// - Every updater window is lifted above the tiles (`UpdateWindows`).
///
/// Threading: main-thread only.
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = UpdateController()

    private var controller: SPUStandardUpdaterController!
    private let state = UpdateState.shared
    /// installs the downloaded update and relaunches. Sparkle's, kept
    /// until the idle check or the menu row calls it
    private var installNow: (() -> Void)?
    private var idleTimer: Timer?
    private var lastWait: IdleInstallPolicy.Wait?
    /// set by `AppDelegate` once the window manager exists
    var windowManager: () -> WindowManager? = { nil }

    var updater: SPUUpdater { controller.updater }

    private override init() {
        super.init()
        // Nix replaces the bundle on its own; Sparkle must not
        controller = SPUStandardUpdaterController(
            startingUpdater: !RuntimeVariant.updatesManagedByNix,
            updaterDelegate: self, userDriverDelegate: self)
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            center.addObserver(self, selector: #selector(windowCameForward(_:)), name: name, object: nil)
        }
        #if DEBUG
        // lets a test drive the menu's update row over ssh
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(activateFromTest), name: Self.testActivateNotification, object: nil)
        #endif
    }

    // MARK: settings

    var checksAutomatically: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { objectWillChange.send(); updater.automaticallyChecksForUpdates = newValue }
    }

    /// Download and install without asking. Off, a found update only shows
    /// the notice and its window.
    var installsAutomatically: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { objectWillChange.send(); updater.automaticallyDownloadsUpdates = newValue }
    }

    // MARK: the menu's update row

    /// Install a downloaded update, or open the update window: the one a
    /// scheduled check is holding back, or a fresh check.
    func activate() {
        if let installNow {
            hyprLog(.notice, .lifecycle, "update: installing now, asked from the menu")
            installNow()
            return
        }
        updater.checkForUpdates()
        bringWindowsForward()
    }

    #if DEBUG
    static let testActivateNotification = Notification.Name("com.zachgray.HyprMac.test.activateUpdate")
    @objc private func activateFromTest() { activate() }
    #endif

    // MARK: updater windows

    @objc private func windowCameForward(_ note: Notification) {
        guard let window = note.object as? NSWindow, UpdateWindows.isUpdateWindow(window) else { return }
        UpdateWindows.float(window, bringForward: false)
    }

    /// Sparkle shows its windows a beat after it is asked, and as a menu
    /// bar app HyprMac is often not active when it does. Lift them a few
    /// times over the next second and a half.
    private func bringWindowsForward() {
        for delay in [0, 0.15, 0.5, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let found = UpdateWindows.floatAll(in: NSApp.windows, bringForward: true)
                if found > 0, !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            }
        }
    }

    // MARK: SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Let Sparkle show a scheduled update only when it would do so in
    /// focus, which is right after launch. Later ones wait behind the
    /// notice. With the menu bar icon hidden there is nowhere to put a
    /// notice, so the window is shown.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        let iconShown = UserDefaults.standard.object(forKey: UserConfig.showMenuBarIconKey) as? Bool ?? true
        return immediateFocus || !iconShown
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        if handleShowingUpdate {
            bringWindowsForward()
        } else {
            hyprLog(.notice, .lifecycle, "update: \(update.displayVersionString) found by a scheduled check, shown in the menu bar")
            self.state.notice = .available(version: update.displayVersionString)
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        if case .available = state.notice { state.notice = nil }
    }

    func standardUserDriverWillFinishUpdateSession() {
        if case .available = state.notice { state.notice = nil }
    }

    // MARK: SPUUpdaterDelegate

    /// A silently downloaded update is ready. Keep Sparkle's install block
    /// and watch for an idle Mac. Quitting still installs it, as before.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        hyprLog(.notice, .lifecycle, "update: \(item.displayVersionString) downloaded, waiting for an idle Mac or a quit")
        installNow = immediateInstallHandler
        state.notice = .ready(version: item.displayVersionString)
        startIdleWatch()
        return true
    }

    /// Every updater relaunch passes through here, idle or clicked.
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        idleTimer?.invalidate()
        windowManager()?.saveRelaunchHandoff()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // a failed install leaves nothing to click
        guard installNow != nil else { return }
        hyprLog(.notice, .lifecycle, "update: aborted with the download pending: \(error.localizedDescription)")
        installNow = nil
        idleTimer?.invalidate()
        state.notice = nil
    }

    // MARK: idle install

    private func startIdleWatch() {
        idleTimer?.invalidate()
        lastWait = nil
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.checkIdle() }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func checkIdle() {
        // the setting can go off after the download. the menu row still installs
        guard let installNow, installsAutomatically else { return }
        let conditions = IdleInstallConditions.current(
            fullscreenInFront: windowManager()?.isFullscreenAppInFront() ?? false)
        if let wait = IdleInstallPolicy.wait(conditions, threshold: IdleInstallPolicy.threshold()) {
            if wait != lastWait, wait != .inUse {
                hyprLog(.notice, .lifecycle, "update: idle install waits, \(wait.rawValue)")
            }
            lastWait = wait
            return
        }
        hyprLog(.notice, .lifecycle, "update: installing, the Mac has been idle \(Int(conditions.idleSeconds))s")
        idleTimer?.invalidate()
        installNow()
    }
}

// lets Settings reach the updater without the debug variant knowing Sparkle
private struct UpdateControllerKey: EnvironmentKey {
    static let defaultValue: UpdateController? = nil
}

extension EnvironmentValues {
    var updateController: UpdateController? {
        get { self[UpdateControllerKey.self] }
        set { self[UpdateControllerKey.self] = newValue }
    }
}
#endif
