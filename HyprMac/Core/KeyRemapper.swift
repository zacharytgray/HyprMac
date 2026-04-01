import Foundation

// remaps Caps Lock → F18 at the IOKit driver level using hidutil
// this happens before CGEventTap, so caps lock never toggles
// and F18 produces clean keyDown/keyUp events
class KeyRemapper {
    private static let capsLockHID: UInt = 0x700000039
    private static let f18HID: UInt = 0x70000006D

    static func remapCapsLockToF18() {
        // first, clear any system-level Caps Lock overrides from Modifier Keys settings
        // these take priority over hidutil and eat caps lock events
        clearSystemModifierOverrides()

        let mapping: [[String: UInt]] = [
            [
                "HIDKeyboardModifierMappingSrc": capsLockHID,
                "HIDKeyboardModifierMappingDst": f18HID
            ]
        ]
        applyMapping(mapping)
        print("[HyprMac] remapped Caps Lock → F18")
    }

    // remove Modifier Keys panel overrides for Caps Lock
    // (System Settings → Keyboard → Modifier Keys → "No Action" blocks hidutil)
    private static func clearSystemModifierOverrides() {
        let defaults = UserDefaults.standard
        // find all per-keyboard modifier mappings
        let globalDefaults = UserDefaults(suiteName: UserDefaults.globalDomain)
        let keys = globalDefaults?.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("com.apple.keyboard.modifiermapping")
        } ?? []

        for key in keys {
            // remove the key from current host global domain
            let task = Process()
            task.launchPath = "/usr/bin/defaults"
            task.arguments = ["-currentHost", "delete", "-g", key]
            try? task.run()
            task.waitUntilExit()
            print("[HyprMac] cleared system modifier override: \(key)")
        }
    }

    static func restoreCapsLock() {
        applyMapping([])
        print("[HyprMac] restored Caps Lock to default")
    }

    private static func applyMapping(_ mapping: [[String: UInt]]) {
        // use hidutil CLI — reliable and doesn't need special entitlements
        let json: [String: Any] = ["UserKeyMapping": mapping]
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let jsonString = String(data: data, encoding: .utf8) else { return }

        let task = Process()
        task.launchPath = "/usr/bin/hidutil"
        task.arguments = ["property", "--set", jsonString]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try? task.run()
        task.waitUntilExit()
    }
}
