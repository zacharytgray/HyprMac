// CGEventTap-based hotkey interceptor. Watches for the Hypr modifier
// (default Caps Lock, remapped to F18 at the HID level) plus chord keys
// and dispatches `Action` values to `WindowManager`.

import Cocoa
import Carbon

/// Global hotkey interceptor.
///
/// Installs a session-level `CGEventTap` that observes keyDown, keyUp,
/// and flagsChanged events. The Hypr key is the modifier substrate —
/// when held, chord keys produce `Action` values via the `keybindMap`.
/// Bare press-and-release of the Hypr key fires `onHyprKeyDown` and
/// `onHyprKeyUp` so the focus border can be re-asserted.
///
/// Threading: the tap is an ACTIVE tap — macOS holds every keystroke
/// system-wide until the callback returns AND the hosting run loop
/// services the source. It therefore lives on its own dedicated thread,
/// not the main run loop: any main-thread stall (retile readback, AX
/// enumeration into a busy app) would otherwise freeze all keyboard
/// input on the machine until macOS kills the tap by timeout. The
/// callback stays O(1) — chord matching only — and dispatches all real
/// work to main. Mutable chord/modifier state is guarded by `stateLock`
/// (written from main on config changes, read per-keystroke on the tap
/// thread). Callbacks (`onAction` etc.) always fire on main.
class HotkeyManager {
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var healthCheckTimer: Timer?
    fileprivate let stateLock = NSLock()

    /// Fires for every recognized chord (Hypr + bound key).
    var onAction: ((Action) -> Void)?

    /// Fires when the Hypr key transitions from up to down.
    var onHyprKeyDown: (() -> Void)?

    /// Fires when the Hypr key transitions from down to up.
    var onHyprKeyUp: (() -> Void)?

    // physical key currently acting as the logical Hypr modifier
    fileprivate var hyprKeyDown = false
    private var hyprKey: HyprKey = .capsLock
    private var pressedModifierKeyCodes: Set<UInt16> = []

    private var keybinds: [Keybind] = Keybind.defaults
    // O(1) lookup: packed key = (keyCode << 16) | modifiers.rawValue
    private var keybindMap: [UInt32: Keybind] = [:]

    private static func packKey(_ keyCode: UInt16, _ modifiers: ModifierFlags) -> UInt32 {
        UInt32(keyCode) << 16 | UInt32(modifiers.rawValue & 0xFFFF)
    }

    /// Replace the active keybind set. Last-wins on duplicate chords —
    /// matches the prior linear-scan behavior. Builds the O(1) lookup
    /// map keyed by packed keyCode + modifiers.
    func updateKeybinds(_ binds: [Keybind]) {
        stateLock.lock()
        defer { stateLock.unlock() }
        keybinds = binds
        // last-wins for duplicate key combos (matches old linear scan behavior)
        keybindMap = [:]
        for bind in binds {
            keybindMap[Self.packKey(bind.keyCode, bind.modifiers)] = bind
        }
    }

    /// Switch the physical key acting as the Hypr modifier. Resets any
    /// in-progress modifier state so a key already down at the moment
    /// of the swap is not misinterpreted.
    func updateHyprKey(_ key: HyprKey) {
        stateLock.lock()
        defer { stateLock.unlock() }
        hyprKey = key
        hyprKeyDown = false
        pressedModifierKeyCodes.removeAll()
        hyprLog(.debug, .lifecycle, "hypr key set to \(key.displayName)")
    }

    /// Install the event tap on a dedicated thread's run loop.
    /// No-op if the tap fails to create — typically means AX
    /// permission is missing; the failure is logged and `isInstalled`
    /// remains `false`.
    func start() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyCallback,
            userInfo: refcon
        ) else {
            hyprLog(.debug, .lifecycle, "event tap creation failed")
            hyprLog(.debug, .lifecycle, "AXIsProcessTrusted=\(AXIsProcessTrusted())")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source

        // dedicated run loop so a busy main thread can never delay
        // keystroke delivery. published before start() returns so stop()
        // always has a run loop to tear down.
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.tapRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "HyprMac.EventTap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
        ready.wait()

        startTapHealthCheck()
        hyprLog(.debug, .lifecycle, "event tap started on dedicated thread, \(keybinds.count) keybinds (\(hyprKey.displayName) = Hypr key)")
    }

    /// Disable the tap, stop its thread, and drop the tap reference.
    /// Idempotent.
    func stop() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let rl = tapRunLoop {
            if let source = runLoopSource {
                CFRunLoopRemoveSource(rl, source, .commonModes)
            }
            CFRunLoopStop(rl)
        }
        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
        stateLock.lock()
        hyprKeyDown = false
        pressedModifierKeyCodes.removeAll()
        stateLock.unlock()
    }

    /// Catch a silently dead tap. The callback re-enables on
    /// `tapDisabledByTimeout`, but a tap can also stop delivering with
    /// no disable event at all (re-sign race after rebuild, TCC flap) —
    /// a non-nil tap is not a healthy tap. Cheap: one flag read per tick.
    private func startTapHealthCheck() {
        healthCheckTimer?.invalidate()
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self, let tap = self.eventTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                hyprLog(.notice, .hotkey, "health check found event tap disabled — re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
                self.resetTrackingAfterTapInterruption()
            }
        }
        timer.tolerance = 1.0
        RunLoop.main.add(timer, forMode: .common)
        healthCheckTimer = timer
    }

    /// Drop tracked modifier state after a tap interruption.
    ///
    /// `tapDisabledByTimeout` / `tapDisabledByUserInput` means we stopped
    /// receiving events for some window of time. Any F18 keyUp that
    /// happened during that window is gone — without this reset, the next
    /// regular keystroke gets packed with the Hypr modifier and triggers
    /// a chord the user didn't intend (the "stuck Caps Lock" bug). The
    /// next legitimate keyDown will re-establish state cleanly.
    ///
    /// Also called from `WindowManager` on sleep/wake/lock notifications,
    /// since those can drop the Hypr keyUp without triggering a tap-disabled
    /// event.
    func resetTrackingAfterTapInterruption() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if hyprKeyDown {
            hyprLog(.notice, .hotkey, "resetting stuck hyprKeyDown after tap interruption")
        }
        setHyprKeyDown(false)
        pressedModifierKeyCodes.removeAll()
    }

    /// `true` when the HID layer currently reports the Hypr key as down.
    /// Cheap syscall — one IOKit query.
    ///
    /// Returns `nil` when the answer can't be trusted — specifically when
    /// the Caps Lock → F18 hidutil remap is active. The remap happens at
    /// the IOKit layer, so the event tap sees F18 events while the session
    /// state still reports F18 as up (no physical F18 is held). Querying
    /// Caps Lock instead doesn't help — `kVK_CapsLock`'s session state
    /// tracks the lock toggle, not the press state.
    private func isHyprKeyActuallyDown() -> Bool? {
        if hyprKey.usesCapsLockRemap { return nil }
        return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(hyprKey.keyCode))
    }

    /// Runs on the tap thread, per keystroke. Holds `stateLock` for the
    /// duration — pure dictionary/set work plus at most one IOKit query,
    /// so hold times are microseconds.
    fileprivate func handleEvent(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        trackModifierState(type, keyCode)

        // track the configured physical key as our logical Hypr modifier
        if keyCode == hyprKey.keyCode {
            if type == .keyDown {
                setHyprKeyDown(true)
            } else if type == .keyUp {
                setHyprKeyDown(false)
            } else if type == .flagsChanged, hyprKey.isNativeModifier {
                setHyprKeyDown(pressedModifierKeyCodes.contains(keyCode))
            }
            return nil // always swallow the Hypr key — it's our internal modifier
        }

        // sanity check on every non-Hypr keyDown: if we think Hypr is held
        // but the HID layer says it isn't, our state is stale (dropped keyUp
        // from sleep, lock, modal sheet, etc.). clear before packing flags
        // so this stroke doesn't get routed as a chord. only runs when the
        // HID query is trustworthy — under the Caps→F18 remap it lies, so
        // we fall back to the sleep/wake/tap-disabled paths there.
        if type == .keyDown, hyprKeyDown, isHyprKeyActuallyDown() == false {
            hyprLog(.notice, .hotkey, "stale hyprKeyDown detected on keyCode=\(keyCode) — HID says \(hyprKey.displayName) is up; clearing")
            setHyprKeyDown(false)
        }

        // only check keybinds on keyDown
        guard type == .keyDown else { return event }

        let flags = ModifierFlags.from(eventFlags(for: event), hyprDown: hyprKeyDown)

        let packed = HotkeyManager.packKey(keyCode, flags)
        if let bind = keybindMap[packed] {
            let action = bind.action
            hyprLog(.debug, .lifecycle, "matched: \(action)")
            DispatchQueue.main.async { [weak self] in
                self?.onAction?(action)
            }
            return nil
        }

        return event
    }

    // assumes stateLock held. the onHyprKeyDown/Up callbacks fire async
    // on main, outside the lock.
    private func setHyprKeyDown(_ isDown: Bool) {
        let wasDown = hyprKeyDown
        hyprKeyDown = isDown
        if isDown && !wasDown {
            hyprLog(.notice, .hotkey, "hypr ↓")
            DispatchQueue.main.async { [weak self] in
                self?.onHyprKeyDown?()
            }
        } else if !isDown && wasDown {
            hyprLog(.notice, .hotkey, "hypr ↑")
            DispatchQueue.main.async { [weak self] in
                self?.onHyprKeyUp?()
            }
        }
    }

    private func eventFlags(for event: CGEvent) -> CGEventFlags {
        var flags = event.flags
        if hyprKeyDown, let nativeFlag = hyprKey.nativeModifierFlag {
            let sameNativeModifierIsDown = pressedModifierKeyCodes.contains { keyCode in
                HyprKey.isKeyCode(keyCode, sameNativeModifierAs: nativeFlag, excluding: hyprKey.keyCode)
            }
            if !sameNativeModifierIsDown {
                flags.remove(nativeFlag)
            }
        }
        return flags
    }

    private func trackModifierState(_ type: CGEventType, _ keyCode: UInt16) {
        guard type == .flagsChanged,
              HyprKey.isNativeModifierKeyCode(keyCode) else { return }

        if pressedModifierKeyCodes.contains(keyCode) {
            pressedModifierKeyCodes.remove(keyCode)
        } else {
            pressedModifierKeyCodes.insert(keyCode)
        }
    }
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let reason = type == .tapDisabledByTimeout ? "timeout" : "user-input"
        hyprLog(.notice, .hotkey, "event tap disabled (\(reason)) — re-enabling and resetting tracked state")
        if let refcon = refcon {
            let mgr = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            if let tap = mgr.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            mgr.resetTrackingAfterTapInterruption()
        }
        return Unmanaged.passRetained(event)
    }

    guard (type == .keyDown || type == .keyUp || type == .flagsChanged), let refcon = refcon else {
        return Unmanaged.passRetained(event)
    }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
    if let passthrough = manager.handleEvent(type, event) {
        return Unmanaged.passRetained(passthrough)
    }
    return nil
}
