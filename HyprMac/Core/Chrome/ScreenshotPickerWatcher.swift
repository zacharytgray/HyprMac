// Tells when macOS's screenshot picker is open. The picker stops at the dim
// panel over an inactive window, and takes no notice of ignoresMouseEvents or
// sharingType, so the dim has to come down while it is up.

import Cocoa

/// Watches for the picker without polling while it is closed.
///
/// `screencaptureui` only runs around a capture, so its launch is the signal.
/// It outlives the picker while the thumbnail shows, so while it runs the
/// window list says whether the picker's overlay, owned by `screencapture`,
/// is still up. If that overlay never shows, the picker counts as closed
/// after a moment, so a changed owner name cannot leave the dim off.
///
/// CleanShot runs `screencapture` itself, with no screencaptureui and no
/// launch event. Its fork is the signal there, about 80 ms before the overlay
/// shows. The picker keeps the window it first hit-tests until the cursor
/// leaves it, so a dim still up at that moment holds the whole screen.
///
/// Threading: main-thread only.
final class ScreenshotPickerWatcher {
    static let uiBundleID = "com.apple.screencaptureui"
    static let overlayOwner = "screencapture"
    // apps that run screencapture themselves: CleanShot X from Setapp and from its site
    static let captureAppBundleIDs: Set<String> = ["com.getcleanshot.app-setapp", "pl.maketheweb.cleanshotx"]
    static let pollInterval: TimeInterval = 0.2
    static let overlayGrace: CFAbsoluteTime = 1

    private(set) var isOpen = false
    var onChange: (Bool) -> Void = { _ in }

    var isUIRunning: () -> Bool = {
        !NSRunningApplication.runningApplications(withBundleIdentifier: ScreenshotPickerWatcher.uiBundleID).isEmpty
    }
    var isOverlayVisible: () -> Bool = {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { $0[kCGWindowOwnerName as String] as? String == ScreenshotPickerWatcher.overlayOwner }
    }
    var now: () -> CFAbsoluteTime = { CFAbsoluteTimeGetCurrent() }

    private var observation: NSKeyValueObservation?
    private var timer: Timer?
    private var forkSources: [pid_t: DispatchSourceProcess] = [:]
    // when the current signal (screencaptureui seen, or a capture app's fork)
    // started. nil while there is none
    private var signalAt: CFAbsoluteTime?
    private var forkPending = false
    private var overlaySeen = false

    func start() {
        mainThreadOnly()
        guard observation == nil else { return }
        observation = NSWorkspace.shared.observe(\.runningApplications, options: []) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.watchCaptureApps()
                self?.evaluate()
            }
        }
        watchCaptureApps()
        evaluate()
    }

    func stop() {
        mainThreadOnly()
        observation = nil
        forkSources.values.forEach { $0.cancel() }
        forkSources = [:]
        timer?.invalidate()
        timer = nil
        signalAt = nil
        forkPending = false
        overlaySeen = false
        setOpen(false, reason: "stopped")
    }

    /// A capture app started a process, which may be `screencapture`.
    func captureAppForked() {
        forkPending = true
        signalAt = now()
        overlaySeen = false
        setOpen(true, reason: "capture app started a process")
        evaluate()
    }

    /// Reads the current state and moves `isOpen` to match.
    func evaluate() {
        let uiRunning = isUIRunning()
        guard uiRunning || forkPending else {
            timer?.invalidate()
            timer = nil
            signalAt = nil
            overlaySeen = false
            setOpen(false, reason: "screencaptureui gone")
            return
        }
        let time = now()
        if signalAt == nil {
            signalAt = time
            setOpen(true, reason: "screencaptureui running")
        }
        if timer == nil {
            let tick = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in self?.evaluate() }
            RunLoop.main.add(tick, forMode: .common)
            timer = tick
        }
        if isOverlayVisible() {
            overlaySeen = true
            setOpen(true, reason: "picker overlay up")
        } else if overlaySeen || time - (signalAt ?? time) >= Self.overlayGrace {
            setOpen(false, reason: overlaySeen ? "picker overlay gone" : "no picker overlay")
            if forkPending {
                // that fork's picker is over. a running screencaptureui keeps the timer
                forkPending = false
                if !uiRunning { evaluate() }
            }
        }
    }

    // one fork source per running capture app, kept in step with the running apps
    private func watchCaptureApps() {
        let pids = Set(NSWorkspace.shared.runningApplications
            .filter { Self.captureAppBundleIDs.contains($0.bundleIdentifier ?? "") }
            .map(\.processIdentifier))
        for (pid, source) in forkSources where !pids.contains(pid) {
            source.cancel()
            forkSources[pid] = nil
        }
        for pid in pids where forkSources[pid] == nil {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .fork, queue: .main)
            source.setEventHandler { [weak self] in self?.captureAppForked() }
            source.resume()
            forkSources[pid] = source
        }
    }

    private func setOpen(_ open: Bool, reason: String) {
        guard open != isOpen else { return }
        isOpen = open
        hyprLog(.notice, .lifecycle, "screenshot picker \(open ? "open" : "closed"): \(reason)")
        onChange(open)
    }
}
