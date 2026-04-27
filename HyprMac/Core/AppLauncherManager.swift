// Launches an app by bundle ID, or activates and unminimizes its
// existing windows if it is already running.

import Cocoa

/// Launch-or-focus helper for the `Action.launchApp` keybind.
///
/// Resolves an app by bundle identifier and routes through one of three
/// paths: already running with windows → activate; already running
/// with no windows → reopen the app (so `applicationOpenUntitledFile`
/// can fire); not running → launch via `NSWorkspace.openApplication`.
class AppLauncherManager {
    /// Bring the app to the foreground, opening a window if needed.
    /// No-op when the bundle ID does not resolve to an installed app.
    func launchOrFocus(bundleID: String) {
        // if already running, unhide/unminimize and activate
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            if app.isHidden {
                app.unhide()
            }

            // unminimize any minimized windows
            let pid = app.processIdentifier
            let appRef = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            var hasWindows = false
            if AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let windows = windowsRef as? [AXUIElement] {
                hasWindows = !windows.isEmpty
                for window in windows {
                    var minimized: CFTypeRef?
                    if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
                       (minimized as? Bool) == true {
                        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                    }
                }
            }

            if hasWindows {
                // windows exist, just activate
                app.activate(options: [.activateAllWindows])
            } else {
                // no windows — re-open the app to trigger a new window
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
                NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
            }
            return
        }

        // otherwise launch it
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            hyprLog(.debug, .lifecycle, "app not found: \(bundleID)")
            return
        }

        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            if let error = error {
                hyprLog(.debug, .lifecycle, "failed to launch \(bundleID): \(error)")
            }
        }
    }
}
