// Input Monitoring: the optional permission behind `PhysicalKeyMonitor`.
// Only asked for when Caps Lock is the Hypr key. Without it HyprMac works
// as before; Hypr just ends early when Control comes up (#81).

import AppKit
import IOKit.hid

extension Notification.Name {
    /// Posted on main when the physical Caps Lock monitor starts, stops or
    /// fails to open, so permission rows can refresh.
    static let hyprMacInputMonitoringChanged = Notification.Name("HyprMacInputMonitoringChanged")
}

enum InputMonitoringPermission {
    enum Status: Equatable {
        case granted
        /// macOS says granted, but the keyboards still won't open
        case needsRelaunch
        case notGranted
    }

    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!

    // MARK: copy

    static let title = "Input Monitoring"
    static let purpose = "Keeps Hypr held through Control shortcuts."
    static let scope = "It reads only whether Caps Lock is held."
    static let promptNote = "macOS will ask to let it “receive keystrokes.”"
    static let relaunchNote = "Input Monitoring is on, but HyprMac can't read Caps Lock until it relaunches."
    static let relaunchButtonTitle = "Relaunch HyprMac"

    // MARK: state

    /// Swapped in tests.
    static var accessCheck: () -> Bool = {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static var isGranted: Bool { accessCheck() }

    /// The raw TCC answer, for logs and `--check-input-monitoring`.
    static var accessDescription: String {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return "granted"
        case kIOHIDAccessTypeDenied: return "denied"
        default: return "unknown"
        }
    }

    private static let lock = NSLock()
    private static var openFailed = false

    /// Set by `HotkeyManager`: access is granted but the keyboards didn't open.
    static var openFailedWithAccess: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return openFailed
        }
        set {
            lock.lock()
            let changed = openFailed != newValue
            openFailed = newValue
            lock.unlock()
            if changed { postChange() }
        }
    }

    static func status(granted: Bool, openFailed: Bool) -> Status {
        guard granted else { return .notGranted }
        return openFailed ? .needsRelaunch : .granted
    }

    static var currentStatus: Status {
        status(granted: isGranted, openFailed: openFailedWithAccess)
    }

    static func postChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .hyprMacInputMonitoringChanged, object: nil)
        }
    }

    // MARK: actions

    /// The system prompt the first time, then the Input Monitoring pane as
    /// the fallback when the prompt can't show (already answered) or the
    /// user picked Deny. Runs off main in case the request waits on the user.
    static func requestThenOpen() {
        DispatchQueue.global(qos: .userInitiated).async {
            let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            hyprLog(.notice, .hotkey, "Input Monitoring requested — granted: \(granted)")
            guard !granted else {
                postChange()
                return
            }
            DispatchQueue.main.async {
                NSWorkspace.shared.open(settingsURL)
            }
        }
    }

    /// Quit and open again through Launch Services. The new copy waits for
    /// this one to exit, so the quit-time Caps Lock restore can't land
    /// after the new launch applies the remap.
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
            Bundle.main.bundleURL.path,
        ]
        do {
            try task.run()
        } catch {
            hyprLog(.error, .lifecycle, "relaunch failed to start: \(error.localizedDescription)")
            return
        }
        hyprLog(.notice, .lifecycle, "relaunching for Input Monitoring")
        NSApp.terminate(nil)
    }
}
