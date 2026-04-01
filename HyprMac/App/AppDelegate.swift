import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var windowManager: WindowManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        print("[HyprMac] bundle: \(Bundle.main.bundleIdentifier ?? "?")")
        print("[HyprMac] AXIsProcessTrusted=\(AXIsProcessTrusted())")

        if AXIsProcessTrusted() {
            // remap caps lock → F18 at driver level
            KeyRemapper.remapCapsLockToF18()
            startWindowManager()
        } else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)

            let alert = NSAlert()
            alert.messageText = "HyprMac Needs Accessibility Permission"
            alert.informativeText = "Grant access in System Settings → Privacy & Security → Accessibility, then relaunch HyprMac."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Quit & Relaunch")
            alert.addButton(withTitle: "I Already Granted It — Retry")
            let response = alert.runModal()

            if response == .alertSecondButtonReturn && AXIsProcessTrusted() {
                KeyRemapper.remapCapsLockToF18()
                startWindowManager()
            } else {
                NSApp.terminate(nil)
            }
        }
    }

    func startWindowManager() {
        let config = UserConfig.shared
        windowManager = WindowManager(config: config)
        windowManager?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowManager?.stop()
        // restore caps lock to normal when quitting
        KeyRemapper.restoreCapsLock()
    }
}
