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

/// One keyboard service and whether it holds its own copy of
/// `UserKeyMapping`. The system-wide write hands every keyboard present a
/// copy; a keyboard the event system makes later gets none (#103).
struct HIDKeyboardMapping: Equatable {
    let id: UInt64
    let name: String
    let hasList: Bool
}

/// Static helpers for applying and clearing the Caps Lock → F18 remap.
/// The remap is in place only while Caps Lock is the Hypr key and HyprMac
/// is active. Pausing removes it and resuming puts it back.
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

    /// Whether Caps Lock should be mapped to F18 right now: only while it
    /// is the Hypr key and HyprMac is active. Paused, the key goes back to
    /// macOS so Caps Lock works as Caps Lock (#94).
    static func wantsRemap(_ key: HyprKey, enabled: Bool) -> Bool {
        key.usesCapsLockRemap && enabled
    }

    /// Install or remove the remap for the configured Hypr key and the
    /// paused state. Called at launch, on pause and resume, and when the
    /// Hypr key changes. The closures and the defaults are the test seam.
    static func applyHyprKey(_ key: HyprKey, enabled: Bool,
                             read: () -> Any? = KeyRemapper.readUserKeyMapping,
                             write: ([HIDKeyMapping]) -> Bool = KeyRemapper.writeUserKeyMapping,
                             defaults: UserDefaults = .standard,
                             capsLockOff: () -> Void = KeyRemapper.turnCapsLockOff) {
        // install assumes Modifier Keys still has Caps Lock on "⇪ Caps Lock";
        // we can't read that, so the UI asks the user instead
        update(wantsRemap(key, enabled: enabled) ? .install : .remove,
               read: read, write: write, defaults: defaults, capsLockOff: capsLockOff)
    }

    static func restoreCapsLock() {
        update(.remove)
    }

    /// Put the remap back if it is gone. Another HyprMac quitting (the
    /// release build beside a debug build, or the reverse) restores Caps
    /// Lock for both, a hidutil script or a reset list does the same, and
    /// the Hypr key is then a plain Caps Lock until the next launch, with
    /// nothing in the log to say so.
    ///
    /// With the entry in place it also checks each keyboard. The event
    /// system copies the list into every keyboard present at a write, and
    /// gives a keyboard it makes later (a wake, a plug-in, a Bluetooth
    /// reconnect) no copy at all, so Caps Lock on that keyboard stays Caps
    /// Lock (#103). Such a keyboard gets the current list, and only it. A
    /// keyboard with any list of its own is left alone: someone set it.
    ///
    /// Asked after a wake, an unlock, the session becoming active again and
    /// a keyboard arriving. Two IOKit reads; a write runs only when the
    /// entry or a keyboard's copy is missing.
    /// - Returns: whether anything was written.
    @discardableResult
    static func reassertHyprKey(_ key: HyprKey, enabled: Bool,
                                read: () -> Any? = KeyRemapper.readUserKeyMapping,
                                write: ([HIDKeyMapping]) -> Bool = KeyRemapper.writeUserKeyMapping,
                                defaults: UserDefaults = .standard,
                                capsLockOff: () -> Void = KeyRemapper.turnCapsLockOff,
                                keyboards: () -> [HIDKeyboardMapping] = KeyRemapper.readKeyboardMappings,
                                pushToKeyboard: (UInt64, [HIDKeyMapping]) -> Bool = KeyRemapper.writeKeyboardMapping) -> Bool {
        guard wantsRemap(key, enabled: enabled) else { return false }
        let raw = read()
        guard let current = KeyMappingMerge.parse(raw) else {
            hyprLog(.error, .lifecycle, "UserKeyMapping check: the list has an entry HyprMac can't read, so it was left unchanged")
            return false
        }
        // the system-wide write below reaches every keyboard present, so
        // keyboards only need a look while the list already has ours
        guard !current.contains(KeyMappingMerge.ours) else {
            return copyListToKeyboardsWithoutOne(current, keyboards: keyboards(), push: pushToKeyboard)
        }
        hyprLog(.notice, .lifecycle, "Caps Lock → F18 mapping is gone (another HyprMac quit, or the list was reset) — putting it back")
        update(.install, read: { raw }, write: write, defaults: defaults, capsLockOff: capsLockOff)
        return true
    }

    /// Give the list to each keyboard that has no copy of it. true when one
    /// took it.
    private static func copyListToKeyboardsWithoutOne(_ list: [HIDKeyMapping],
                                                     keyboards: [HIDKeyboardMapping],
                                                     push: (UInt64, [HIDKeyMapping]) -> Bool) -> Bool {
        var wrote = false
        for keyboard in keyboards where !keyboard.hasList {
            if push(keyboard.id, list) {
                hyprLog(.notice, .lifecycle,
                        "keyboard \(keyboard.name) (\(hex(keyboard.id))) had no UserKeyMapping, so Caps Lock "
                        + "on it was still Caps Lock — gave it the list (\(list.count) entries)")
                wrote = true
            } else {
                hyprLog(.error, .lifecycle,
                        "keyboard \(keyboard.name) (\(hex(keyboard.id))) has no UserKeyMapping and "
                        + "didn't take the list; Caps Lock on it is still Caps Lock")
            }
        }
        return wrote
    }

    /// Read the list, merge, write it back when it changed. The closures and
    /// the defaults are the test seam; the live ones touch the real mapping.
    static func update(_ operation: KeyMappingMerge.Operation,
                       read: () -> Any? = KeyRemapper.readUserKeyMapping,
                       write: ([HIDKeyMapping]) -> Bool = KeyRemapper.writeUserKeyMapping,
                       defaults: UserDefaults = .standard,
                       capsLockOff: () -> Void = KeyRemapper.turnCapsLockOff) {
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
            // the key just stopped being Caps Lock, so it can't turn a lock
            // off: one left on while paused or before launch would stay on
            if operation == .install { capsLockOff() }
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
                    + "or pauses, or the Hypr key changes")
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

    /// Every keyboard service the HID event system has, with whether it
    /// holds its own `UserKeyMapping`. `hidutil property --matching … --get`
    /// reads the same per-keyboard value.
    static func readKeyboardMappings() -> [HIDKeyboardMapping] {
        keyboardServices().map { id, service in
            let name = IOHIDServiceClientCopyProperty(service, kIOHIDProductKey as CFString) as? String
            let list = IOHIDServiceClientCopyProperty(service, kIOHIDUserKeyUsageMapKey as CFString)
            return HIDKeyboardMapping(id: id, name: name ?? "keyboard", hasList: list != nil)
        }
    }

    /// Set the list on one keyboard only. Every other keyboard and the
    /// system-wide list stay as they are. true when the keyboard reads it
    /// back: the set call itself says yes even when the keyboard refuses.
    static func writeKeyboardMapping(_ id: UInt64, _ mapping: [HIDKeyMapping]) -> Bool {
        guard let service = keyboardServices().first(where: { $0.id == id })?.service else { return false }
        let list = KeyMappingMerge.propertyList(mapping) as CFArray
        guard IOHIDServiceClientSetProperty(service, kIOHIDUserKeyUsageMapKey as CFString, list) else { return false }
        let readBack = IOHIDServiceClientCopyProperty(service, kIOHIDUserKeyUsageMapKey as CFString)
        return KeyMappingMerge.parse(readBack) == mapping
    }

    private static func keyboardServices() -> [(id: UInt64, service: IOHIDServiceClient)] {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        return services.compactMap { service in
            guard IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop),
                                               UInt32(kHIDUsage_GD_Keyboard)) != 0,
                  let id = IOHIDServiceClientGetRegistryID(service) as? NSNumber else { return nil }
            return (id.uint64Value, service)
        }
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

    /// Turn the Caps Lock state off if it is on. Runs after the remap is
    /// installed, when the key itself no longer can.
    static func turnCapsLockOff() {
        changeCapsLock { isOn in
            guard isOn else { return nil }
            hyprLog(.notice, .lifecycle, "Caps Lock was on when the remap went in — turning it off")
            return false
        }
    }

    /// Flip the Caps Lock state, LED included. For the double tap of the
    /// Hypr key, which is the only way to reach Caps Lock while the key
    /// itself is remapped.
    static func toggleCapsLock() {
        changeCapsLock { !$0 }
    }

    /// Read the Caps Lock state and set the one `next` returns; nil leaves it.
    private static func changeCapsLock(_ next: (Bool) -> Bool?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else {
            hyprLog(.notice, .lifecycle, "could not open the HID system to change the Caps Lock state")
            return
        }
        defer { IOServiceClose(connect) }
        var isOn = false
        guard IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &isOn) == KERN_SUCCESS,
              let wanted = next(isOn) else { return }
        let result = IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), wanted)
        if result == KERN_SUCCESS {
            hyprLog(.notice, .lifecycle, "Caps Lock turned \(wanted ? "on" : "off")")
        } else {
            hyprLog(.error, .lifecycle, "Caps Lock could not be turned \(wanted ? "on" : "off") (\(result))")
        }
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

/// Calls back once keyboards stop arriving: a plug-in, a Bluetooth
/// reconnect, or a keyboard the system rebuilt on wake. The event system
/// gives such a keyboard no copy of `UserKeyMapping` (#103), and it can
/// show up after the wake and unlock notifications. A registry
/// notification, so nothing polls and no permission is needed.
final class KeyboardArrivalWatcher {
    /// the event system makes its own service a beat after the registry
    /// match; a burst of arrivals on wake runs one check
    static let settleDelay: TimeInterval = 1.0

    private let onArrival: () -> Void
    private var port: IONotificationPortRef?
    private var iterator: io_iterator_t = 0
    private var pending: DispatchWorkItem?

    init(onArrival: @escaping () -> Void) {
        self.onArrival = onArrival
    }

    deinit { stop() }

    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, .main)
        let matching = IOServiceMatching("IOHIDEventService") as NSMutableDictionary
        matching[kIOPropertyMatchKey] = [kIOHIDPrimaryUsagePageKey: kHIDPage_GenericDesktop,
                                         kIOHIDPrimaryUsageKey: kHIDUsage_GD_Keyboard]
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matching,
                                                      keyboardArrivalCallback, context, &iterator)
        guard result == KERN_SUCCESS else {
            IONotificationPortDestroy(port)
            hyprLog(.error, .lifecycle, "could not watch for keyboards arriving (\(result))")
            return
        }
        self.port = port
        // the keyboards already here aren't arrivals, but draining arms it
        Self.drain(iterator)
    }

    func stop() {
        pending?.cancel()
        pending = nil
        if iterator != 0 {
            IOObjectRelease(iterator)
            iterator = 0
        }
        if let port {
            IONotificationPortDestroy(port)
            self.port = nil
        }
    }

    fileprivate func keyboardsArrived(_ iterator: io_iterator_t) {
        let count = Self.drain(iterator)
        guard count > 0 else { return }
        hyprLog(.debug, .lifecycle, "\(count) keyboard service(s) arrived")
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onArrival() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    @discardableResult
    private static func drain(_ iterator: io_iterator_t) -> Int {
        var count = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
            count += 1
        }
        return count
    }
}

private func keyboardArrivalCallback(_ context: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    guard let context else { return }
    Unmanaged<KeyboardArrivalWatcher>.fromOpaque(context).takeUnretainedValue().keyboardsArrived(iterator)
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
