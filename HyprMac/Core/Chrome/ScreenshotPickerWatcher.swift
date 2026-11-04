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
/// Threading: main-thread only.
final class ScreenshotPickerWatcher {
    static let uiBundleID = "com.apple.screencaptureui"
    static let overlayOwner = "screencapture"
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
    // when this run of screencaptureui was first seen. nil while it isn't running
    private var uiSeenAt: CFAbsoluteTime?
    private var overlaySeen = false

    func start() {
        mainThreadOnly()
        guard observation == nil else { return }
        observation = NSWorkspace.shared.observe(\.runningApplications, options: []) { [weak self] _, _ in
            DispatchQueue.main.async { self?.evaluate() }
        }
        evaluate()
    }

    func stop() {
        mainThreadOnly()
        observation = nil
        timer?.invalidate()
        timer = nil
        uiSeenAt = nil
        overlaySeen = false
        setOpen(false, reason: "stopped")
    }

    /// Reads the current state and moves `isOpen` to match.
    func evaluate() {
        guard isUIRunning() else {
            timer?.invalidate()
            timer = nil
            uiSeenAt = nil
            overlaySeen = false
            setOpen(false, reason: "screencaptureui gone")
            return
        }
        let time = now()
        let firstSeen = uiSeenAt == nil
        if firstSeen {
            uiSeenAt = time
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
        } else if overlaySeen || time - (uiSeenAt ?? time) >= Self.overlayGrace {
            setOpen(false, reason: overlaySeen ? "picker overlay gone" : "no picker overlay")
        }
    }

    private func setOpen(_ open: Bool, reason: String) {
        guard open != isOpen else { return }
        isOpen = open
        hyprLog(.notice, .lifecycle, "screenshot picker \(open ? "open" : "closed"): \(reason)")
        onChange(open)
    }
}
