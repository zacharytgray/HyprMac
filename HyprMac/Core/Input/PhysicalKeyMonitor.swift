// Physical Caps Lock state, read from the keyboard devices through
// IOHIDManager. This sits below the event system's key remapping, so it
// reports the key itself, not the F18 it becomes. macOS sends an F18
// release while Caps Lock is still held when Control comes up (#81);
// this is the answer the event tap can't give. Needs Input Monitoring.

import Foundation
import IOKit.hid

final class PhysicalKeyMonitor {
    static let capsLockUsage = UInt32(kHIDUsage_KeyboardCapsLock)

    private let lock = NSLock()
    private var manager: IOHIDManager?
    private var runLoop: CFRunLoop?
    // devices holding caps lock right now
    private var downDevices: Set<UnsafeMutableRawPointer> = []

    /// Fires on the scheduled run loop when the last held Caps Lock comes up.
    var onRelease: (() -> Void)?

    static var hasAccess: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Shows the system prompt the first time. true when already granted.
    @discardableResult
    static func requestAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return manager != nil
    }

    var isCapsLockDown: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !downDevices.isEmpty
    }

    /// Opens every keyboard without seizing it. false when access is
    /// missing or the open fails; the caller keeps the old behavior then.
    @discardableResult
    func start(on runLoop: CFRunLoop) -> Bool {
        // IOKit calls stay outside the lock: open and close can call back
        // into handle(), which takes it
        guard !isActive else { return true }

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let devices: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ]
        IOHIDManagerSetDeviceMatching(mgr, devices as CFDictionary)
        let values: [String: Any] = [
            kIOHIDElementUsagePageKey: kHIDPage_KeyboardOrKeypad,
            kIOHIDElementUsageKey: Self.capsLockUsage,
        ]
        IOHIDManagerSetInputValueMatching(mgr, values as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(mgr, physicalKeyValueCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, physicalKeyRemovalCallback, context)
        IOHIDManagerScheduleWithRunLoop(mgr, runLoop, CFRunLoopMode.defaultMode.rawValue)

        let result = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(mgr, runLoop, CFRunLoopMode.defaultMode.rawValue)
            hyprLog(.notice, .hotkey, "physical key monitor did not open (0x\(String(UInt32(bitPattern: result), radix: 16))) — Input Monitoring granted: \(Self.hasAccess)")
            return false
        }
        lock.lock()
        manager = mgr
        self.runLoop = runLoop
        lock.unlock()
        hyprLog(.notice, .hotkey, "physical key monitor started")
        return true
    }

    func stop() {
        lock.lock()
        let mgr = manager
        let rl = runLoop
        manager = nil
        runLoop = nil
        downDevices.removeAll()
        lock.unlock()
        guard let mgr else { return }
        if let rl {
            IOHIDManagerUnscheduleFromRunLoop(mgr, rl, CFRunLoopMode.defaultMode.rawValue)
        }
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Forget held state after sleep or a tap interruption, where an up
    /// can go missing. Worst case is the old behavior until the next press.
    func reset() {
        lock.lock()
        downDevices.removeAll()
        lock.unlock()
    }

    fileprivate func handle(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad),
              IOHIDElementGetUsage(element) == Self.capsLockUsage else { return }
        let device = Unmanaged.passUnretained(IOHIDElementGetDevice(element)).toOpaque()
        let isDown = IOHIDValueGetIntegerValue(value) != 0

        lock.lock()
        let wasDown = !downDevices.isEmpty
        if isDown {
            downDevices.insert(device)
        } else {
            downDevices.remove(device)
        }
        let nowDown = !downDevices.isEmpty
        lock.unlock()

        hyprLog(.notice, .hotkey, "diag81 physical caps \(isDown ? "down" : "up") held=\(nowDown)")
        if wasDown && !nowDown {
            onRelease?()
        }
    }

    fileprivate func handleRemoval(device: IOHIDDevice) {
        let key = Unmanaged.passUnretained(device).toOpaque()
        lock.lock()
        let wasDown = !downDevices.isEmpty
        downDevices.remove(key)
        let nowDown = !downDevices.isEmpty
        lock.unlock()
        if wasDown && !nowDown {
            onRelease?()
        }
    }
}

private func physicalKeyValueCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard let context else { return }
    Unmanaged<PhysicalKeyMonitor>.fromOpaque(context).takeUnretainedValue().handle(value: value)
}

private func physicalKeyRemovalCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    Unmanaged<PhysicalKeyMonitor>.fromOpaque(context).takeUnretainedValue().handleRemoval(device: device)
}
