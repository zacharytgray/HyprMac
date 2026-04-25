import Cocoa
import Carbon

class HotkeyManager {
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    var onAction: ((Action) -> Void)?
    var onHyprKeyDown: (() -> Void)?
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

    func updateKeybinds(_ binds: [Keybind]) {
        keybinds = binds
        // last-wins for duplicate key combos (matches old linear scan behavior)
        keybindMap = [:]
        for bind in binds {
            keybindMap[Self.packKey(bind.keyCode, bind.modifiers)] = bind
        }
    }

    func updateHyprKey(_ key: HyprKey) {
        hyprKey = key
        hyprKeyDown = false
        pressedModifierKeyCodes.removeAll()
        hyprLog("hypr key set to \(key.displayName)")
    }

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
            hyprLog("event tap creation failed")
            hyprLog("AXIsProcessTrusted=\(AXIsProcessTrusted())")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        hyprLog("event tap started, \(keybinds.count) keybinds (\(hyprKey.displayName) = Hypr key)")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        hyprKeyDown = false
        pressedModifierKeyCodes.removeAll()
    }

    fileprivate func handleEvent(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
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

        // only check keybinds on keyDown
        guard type == .keyDown else { return event }

        let flags = ModifierFlags.from(eventFlags(for: event), hyprDown: hyprKeyDown)

        let packed = HotkeyManager.packKey(keyCode, flags)
        if let bind = keybindMap[packed] {
            let action = bind.action.toAction()
            hyprLog("matched: \(action)")
            DispatchQueue.main.async { [weak self] in
                self?.onAction?(action)
            }
            return nil
        }

        return event
    }

    private func setHyprKeyDown(_ isDown: Bool) {
        let wasDown = hyprKeyDown
        hyprKeyDown = isDown
        if isDown && !wasDown {
            DispatchQueue.main.async { [weak self] in
                self?.onHyprKeyDown?()
            }
        } else if !isDown && wasDown {
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
        if let refcon = refcon {
            let mgr = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            if let tap = mgr.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
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
