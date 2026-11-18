// Physical Caps Lock state, read from the keyboard devices through
// IOHIDManager. This sits below the event system's key remapping, so it
// reports the key itself, not the F18 it becomes. macOS sends an F18
// release while Caps Lock is still held when Control comes up (#81);
// this is the answer the event tap can't give. Reading a keyboard needs
// the ListenEvent (Input Monitoring) access, and macOS gives that to an
// app with Accessibility, so HyprMac never asks for it separately.

import Foundation
import IOKit.hid

/// Which keyboards hold the key right now. Pure, so the multi-device
/// rules are testable without a keyboard.
struct PhysicalKeyHoldState: Equatable {
    private(set) var holders: Set<UInt> = []

    var isHeld: Bool { !holders.isEmpty }

    /// true when this change let go of the last holder
    @discardableResult
    mutating func keyChanged(device: UInt, isDown: Bool) -> Bool {
        let wasHeld = isHeld
        if isDown {
            holders.insert(device)
        } else {
            holders.remove(device)
        }
        return wasHeld && !isHeld
    }

    /// An unplugged keyboard can't send its up. true when it was the last holder.
    @discardableResult
    mutating func deviceRemoved(_ device: UInt) -> Bool {
        keyChanged(device: device, isDown: false)
    }

    mutating func reset() {
        holders.removeAll()
    }
}

/// What `HotkeyManager` needs from the physical Caps Lock reader. A
/// protocol so tests can drive the held state.
protocol PhysicalCapsLockReading: AnyObject {
    var isActive: Bool { get }
    var isCapsLockDown: Bool { get }
    /// Fires when the last held Caps Lock comes up or its keyboard goes away.
    var onRelease: (() -> Void)? { get set }
    @discardableResult func start(on runLoop: CFRunLoop) -> IOReturn
    func stop()
    func reset()
}

final class PhysicalKeyMonitor: PhysicalCapsLockReading {
    static let capsLockUsage = UInt32(kHIDUsage_KeyboardCapsLock)

    /// Whether this process may read keyboards. Follows Accessibility.
    static var hasAccess: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// The raw TCC answer, for logs and `--check-input-monitoring`.
    static var accessDescription: String {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return "granted"
        case kIOHIDAccessTypeDenied: return "denied"
        default: return "unknown"
        }
    }

    private let lock = NSLock()
    private var manager: IOHIDManager?
    private var runLoop: CFRunLoop?
    private var hold = PhysicalKeyHoldState()

    /// Fires on the scheduled run loop.
    var onRelease: (() -> Void)?

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return manager != nil
    }

    var isCapsLockDown: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hold.isHeld
    }

    /// Opens every keyboard without seizing it, matched to Caps Lock only,
    /// so no other key reaches us. Returns the open result; anything but
    /// success leaves the monitor off and the caller on the old behavior.
    @discardableResult
    func start(on runLoop: CFRunLoop) -> IOReturn {
        // IOKit calls stay outside the lock: open and close can call back
        // into handle(), which takes it
        guard !isActive else { return kIOReturnSuccess }

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
            return result
        }
        lock.lock()
        manager = mgr
        self.runLoop = runLoop
        hold.reset()
        lock.unlock()
        return result
    }

    func stop() {
        lock.lock()
        let mgr = manager
        let rl = runLoop
        manager = nil
        runLoop = nil
        hold.reset()
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
        hold.reset()
        lock.unlock()
    }

    fileprivate func handle(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad),
              IOHIDElementGetUsage(element) == Self.capsLockUsage else { return }
        let device = UInt(bitPattern: Unmanaged.passUnretained(IOHIDElementGetDevice(element)).toOpaque())
        let isDown = IOHIDValueGetIntegerValue(value) != 0

        lock.lock()
        let active = manager != nil
        let released = active && hold.keyChanged(device: device, isDown: isDown)
        let held = hold.isHeld
        lock.unlock()
        // a value queued before stop() lands after it; don't track that
        guard active else { return }

        hyprLog(.debug, .hotkey, "physical Caps Lock \(isDown ? "down" : "up") (held=\(held))")
        if released {
            onRelease?()
        }
    }

    fileprivate func handleRemoval(device: IOHIDDevice) {
        let key = UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
        lock.lock()
        let released = hold.deviceRemoved(key)
        lock.unlock()
        if released {
            hyprLog(.notice, .hotkey, "keyboard holding Caps Lock was removed — treating it as released")
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
