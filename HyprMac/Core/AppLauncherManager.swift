import Cocoa

class AppLauncherManager {
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
            print("[HyprMac] app not found: \(bundleID)")
            return
        }

        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            if let error = error {
                print("[HyprMac] failed to launch \(bundleID): \(error)")
            }
        }
    }
}
