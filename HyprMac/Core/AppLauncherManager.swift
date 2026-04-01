import Cocoa

class AppLauncherManager {
    func launchOrFocus(bundleID: String) {
        // if already running, activate it
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate()
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
