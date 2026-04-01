import Cocoa
import Carbon

class HotkeyManager {
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    var onAction: ((Action) -> Void)?

    // F18 = our Hypr key (Caps Lock is remapped to F18 at the driver level)
    fileprivate var hyprKeyDown = false
    private static let f18KeyCode: UInt16 = 79 // 0x4F

    private var keybinds: [Keybind] = Keybind.defaults

    func updateKeybinds(_ binds: [Keybind]) {
        keybinds = binds
    }

    func start() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyCallback,
            userInfo: refcon
        ) else {
            print("[HyprMac] event tap creation failed")
            print("[HyprMac] AXIsProcessTrusted=\(AXIsProcessTrusted())")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[HyprMac] event tap started, \(keybinds.count) keybinds (Caps Lock → F18 = Hypr key)")
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
    }

    fileprivate func handleEvent(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        // track F18 (remapped Caps Lock) as our Hypr modifier
        if keyCode == HotkeyManager.f18KeyCode {
            if type == .keyDown {
                hyprKeyDown = true
            } else if type == .keyUp {
                hyprKeyDown = false
            }
            return nil // always swallow F18 — it's our internal modifier
        }

        // only check keybinds on keyDown
        guard type == .keyDown else { return event }

        let flags = ModifierFlags.from(event.flags, hyprDown: hyprKeyDown)

        for bind in keybinds {
            if bind.keyCode == keyCode && bind.modifiers == flags {
                let action = bind.action.toAction()
                print("[HyprMac] matched: \(action)")
                DispatchQueue.main.async { [weak self] in
                    self?.onAction?(action)
                }
                return nil
            }
        }

        return event
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

    guard (type == .keyDown || type == .keyUp), let refcon = refcon else {
        return Unmanaged.passRetained(event)
    }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
    if let passthrough = manager.handleEvent(type, event) {
        return Unmanaged.passRetained(passthrough)
    }
    return nil
}
