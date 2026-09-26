// HID-level key remap shim. Drives `hidutil` to map Caps Lock → F18 so
// the Hypr key produces clean keyDown/keyUp events that
// `HotkeyManager`'s CGEventTap can intercept; Caps Lock alone is a
// driver-level toggle and never reaches the tap.
//
// `UserKeyMapping` is one system-wide list. It also holds any mapping the
// user sets with hidutil themselves (a LaunchAgent, a script). HyprMac
// reads the list, adds or removes only its own entry, and writes every
// other entry back unchanged and in order. The rules are in
// `KeyMappingMerge`, which is pure so tests never touch the keyboard.

import Foundation
import IOKit.hid
import IOKit.hidsystem

/// One `UserKeyMapping` entry. Both sides are HID usages packed as
/// `page << 32 | usage`, the form hidutil takes.
struct HIDKeyMapping: Codable, Equatable {
    let src: UInt64
    let dst: UInt64
}

/// Static helpers for applying and clearing the Caps Lock → F18 remap.
///
/// Reads the current `UserKeyMapping` through the public IOKit event
/// system client and writes the merged list with `hidutil property --set`.
///
/// This only works while Caps Lock stays set to "⇪ Caps Lock" in System
/// Settings → Keyboard → Keyboard Shortcuts… → Modifier Keys. That pane
/// applies first, per keyboard, so "No Action" (or any other choice)
/// swallows the key before our mapping or the event tap ever sees it.
/// macOS exposes no supported way to read or change that setting, so
/// HyprMac asks the user to check it — see `HyprKeySystemGuidance`.
class KeyRemapper {
    // foreign Caps Lock entries our entry replaced, kept across launches so
    // a crash doesn't lose them
    static let heldDefaultsKey = "heldCapsLockKeyMappings"

    /// Apply or restore the remap based on the configured Hypr key.
    /// `hyprKey.usesCapsLockRemap` controls which path runs.
    static func applyHyprKey(_ key: HyprKey) {
        if key.usesCapsLockRemap {
            remapCapsLockToF18()
        } else {
            restoreCapsLock()
        }
    }

    static func remapCapsLockToF18() {
        // assumes Modifier Keys still has Caps Lock on "⇪ Caps Lock";
        // we can't read that, so the UI asks the user instead
        update(.install)
    }

    static func restoreCapsLock() {
        update(.remove)
    }

    /// Read the list, merge, write it back when it changed. The closures and
    /// the defaults are the test seam; the live ones touch the real mapping.
    static func update(_ operation: KeyMappingMerge.Operation,
                       read: () -> Any? = KeyRemapper.readUserKeyMapping,
                       write: ([HIDKeyMapping]) -> Bool = KeyRemapper.writeUserKeyMapping,
                       defaults: UserDefaults = .standard) {
        let raw = read()
        let held = loadHeld(from: defaults)
        guard let plan = KeyMappingMerge.plan(operation, read: raw, held: held) else {
            hyprLog(.error, .lifecycle,
                    "UserKeyMapping \(operation.rawValue): the list has an entry HyprMac can't read, "
                    + "so every hidutil mapping was left unchanged")
            return
        }
        // store a new hold before the write, so a crash mid-write can't lose
        // the user's entry. clearing waits for the write: a failed remove
        // still needs the hold. a stale hold is dropped safely later.
        if !plan.held.isEmpty {
            saveHeld(plan.held, to: defaults)
        }
        if plan.changed {
            guard write(plan.mapping) else {
                hyprLog(.error, .lifecycle,
                        "UserKeyMapping \(operation.rawValue): hidutil failed, the mapping is unchanged")
                return
            }
        }
        saveHeld(plan.held, to: defaults)

        for entry in held where !plan.held.contains(entry) && !plan.restored.contains(entry) {
            hyprLog(.notice, .lifecycle,
                    "dropped the held Caps Lock mapping to \(hex(entry.dst)): the list changed since "
                    + "HyprMac replaced it")
        }
        for entry in plan.displaced {
            hyprLog(.notice, .lifecycle,
                    "Caps Lock had a user mapping to \(hex(entry.dst)). HyprMac's Caps Lock → F18 "
                    + "replaces it while Caps Lock is the Hypr key. It comes back when HyprMac quits "
                    + "or the Hypr key changes")
        }
        for entry in plan.restored {
            hyprLog(.notice, .lifecycle, "put back the user's Caps Lock mapping to \(hex(entry.dst))")
        }
        hyprLog(.notice, .lifecycle,
                "UserKeyMapping \(operation.rawValue): \(plan.mapping.count) entries, "
                + (plan.changed ? "written" : "already current"))
    }

    // MARK: - live IO

    /// The current `UserKeyMapping`, or nil when nothing has set it since boot.
    ///
    /// Read through IOKit rather than by parsing `hidutil property --get`:
    /// the key is public (`kIOHIDUserKeyUsageMapKey`, listed as readable in
    /// IOHIDProperties.h), the value comes back typed, and hidutil's `--get`
    /// output is a CoreFoundation description string, not a stable format.
    static func readUserKeyMapping() -> Any? {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        return IOHIDEventSystemClientCopyProperty(client, kIOHIDUserKeyUsageMapKey as CFString)
    }

    /// Replace the whole list. true when hidutil exited cleanly.
    static func writeUserKeyMapping(_ mapping: [HIDKeyMapping]) -> Bool {
        // hidutil CLI — the write path that has always shipped, no entitlements
        let json: [String: Any] = [kIOHIDUserKeyUsageMapKey: KeyMappingMerge.propertyList(mapping)]
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let jsonString = String(data: data, encoding: .utf8) else { return false }

        let task = Process()
        task.launchPath = "/usr/bin/hidutil"
        task.arguments = ["property", "--set", jsonString]
        let errors = Pipe()
        task.standardOutput = FileHandle.nullDevice
        task.standardError = errors
        do {
            try task.run()
        } catch {
            hyprLog(.error, .lifecycle, "could not launch hidutil: \(error.localizedDescription)")
            return false
        }
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let text = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            hyprLog(.error, .lifecycle, "hidutil exited with status \(task.terminationStatus): \(text)")
            return false
        }
        return true
    }

    static func loadHeld(from defaults: UserDefaults) -> [HIDKeyMapping] {
        guard let data = defaults.data(forKey: heldDefaultsKey) else { return [] }
        return (try? JSONDecoder().decode([HIDKeyMapping].self, from: data)) ?? []
    }

    static func saveHeld(_ held: [HIDKeyMapping], to defaults: UserDefaults) {
        if held.isEmpty {
            defaults.removeObject(forKey: heldDefaultsKey)
        } else if let data = try? JSONEncoder().encode(held) {
            defaults.set(data, forKey: heldDefaultsKey)
        }
    }

    private static func hex(_ usage: UInt64) -> String {
        "0x" + String(usage, radix: 16, uppercase: true)
    }
}

/// Pure rules for HyprMac's one entry in `UserKeyMapping`.
///
/// - Install adds Caps Lock → F18 once. Every other entry stays, in order.
/// - A foreign entry whose source is Caps Lock (say the user's own
///   Caps Lock → Escape) can't coexist with ours: one key has one
///   destination. Ours takes its place in the list while Caps Lock is the
///   Hypr key, and the foreign entry is held to go back on remove.
/// - Remove takes out only ours. A held entry goes back where ours was,
///   unless something else has mapped Caps Lock since.
/// - A list with an entry this can't reproduce exactly makes `plan` return
///   nil, and nothing is written.
/// - An entry identical to ours counts as ours, whoever added it.
enum KeyMappingMerge {
    enum Operation: String {
        case install, remove
    }

    struct Plan: Equatable {
        /// the full list to write
        let mapping: [HIDKeyMapping]
        /// false when the list already matches and the write can be skipped
        let changed: Bool
        /// foreign Caps Lock entries to put back on a later remove
        let held: [HIDKeyMapping]
        /// foreign entries this install took out
        let displaced: [HIDKeyMapping]
        /// held entries this remove put back
        let restored: [HIDKeyMapping]
    }

    static let capsLock: UInt64 = 0x700000039
    static let f18: UInt64 = 0x70000006D
    static let ours = HIDKeyMapping(src: capsLock, dst: f18)

    /// nil means the read can't be trusted and nothing may be written.
    static func plan(_ operation: Operation, read raw: Any?, held: [HIDKeyMapping]) -> Plan? {
        guard let current = parse(raw) else { return nil }
        switch operation {
        case .install: return install(current, held: held)
        case .remove: return remove(current, held: held)
        }
    }

    /// The property as HyprMac models it. A missing property (nothing set
    /// since boot) is an empty list. Anything but plain src/dst pairs is nil.
    static func parse(_ raw: Any?) -> [HIDKeyMapping]? {
        guard let raw else { return [] }
        guard let items = raw as? [Any] else { return nil }
        var result: [HIDKeyMapping] = []
        for item in items {
            // an extra key would be lost on the write, so it counts as unreadable
            guard let entry = item as? [String: Any], entry.count == 2,
                  let src = usage(entry[kIOHIDKeyboardModifierMappingSrcKey]),
                  let dst = usage(entry[kIOHIDKeyboardModifierMappingDstKey]) else { return nil }
            result.append(HIDKeyMapping(src: src, dst: dst))
        }
        return result
    }

    // a whole, non-negative number, or nil. 1.5 or -1 would change on the write.
    private static func usage(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              number == NSNumber(value: number.uint64Value) else { return nil }
        return number.uint64Value
    }

    static func propertyList(_ mapping: [HIDKeyMapping]) -> [[String: UInt64]] {
        mapping.map {
            [kIOHIDKeyboardModifierMappingSrcKey: $0.src, kIOHIDKeyboardModifierMappingDstKey: $0.dst]
        }
    }

    static func install(_ current: [HIDKeyMapping], held: [HIDKeyMapping]) -> Plan {
        var mapping: [HIDKeyMapping] = []
        var displaced: [HIDKeyMapping] = []
        var hadOurs = false
        var placed = false
        for entry in current {
            if entry == ours {
                hadOurs = true
            } else if entry.src == capsLock {
                displaced.append(entry)
            } else {
                mapping.append(entry)
                continue
            }
            // ours sits where the first Caps Lock entry was; later copies drop
            if !placed {
                mapping.append(ours)
                placed = true
            }
        }
        if !placed { mapping.append(ours) }

        // a fresh displacement is the user's current choice. ours already in
        // place with nothing new keeps the earlier hold. otherwise the list
        // was reset since, and an old hold is stale.
        let nextHeld = !displaced.isEmpty ? displaced : (hadOurs ? held : [])
        return Plan(mapping: mapping, changed: mapping != current, held: nextHeld,
                    displaced: displaced, restored: [])
    }

    static func remove(_ current: [HIDKeyMapping], held: [HIDKeyMapping]) -> Plan {
        var mapping: [HIDKeyMapping] = []
        var slot: Int?
        for entry in current {
            if entry == ours {
                if slot == nil { slot = mapping.count }
            } else {
                mapping.append(entry)
            }
        }
        // none of ours: the list was reset or rewritten since the install,
        // so there is nothing to take out and the hold is stale
        guard let slot else {
            return Plan(mapping: current, changed: false, held: [], displaced: [], restored: [])
        }
        var restored: [HIDKeyMapping] = []
        if !mapping.contains(where: { $0.src == capsLock }) {
            restored = held
            mapping.insert(contentsOf: held, at: slot)
        }
        return Plan(mapping: mapping, changed: true, held: [], displaced: [], restored: restored)
    }
}
