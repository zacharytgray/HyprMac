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
/// The Hypr key going down or up fires `onHyprKeyDown` and
/// `onHyprKeyUp`, so the owner can show the focus brackets and
/// re-assert the focus border.
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
///
/// With Caps Lock as the Hypr key, a `PhysicalKeyMonitor` on the same
/// thread reads the key itself. macOS
/// sends an F18 release when Control comes up while Caps Lock is still
/// held (#81); the monitor's answer lets the tap ignore it and end Hypr
/// on the real release instead.
class HotkeyManager {
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var healthCheckTimer: Timer?
    fileprivate let stateLock = NSLock()
    // physical caps lock, for the F18 release macOS sends while it's held
    private let physicalKeys: PhysicalCapsLockReading
    private let hasKeyboardAccess: () -> Bool
    // main thread only: last open failure logged, so retries stay quiet
    private var lastPhysicalOpenFailure: IOReturn?

    // "Double-tap Hypr to toggle Caps Lock". guarded by stateLock
    private var doubleTapCapsLock = false
    private var doubleTap = HyprDoubleTap()
    private let now: () -> TimeInterval
    private let toggleCapsLock: () -> Void

    init(physicalKeys: PhysicalCapsLockReading = PhysicalKeyMonitor(),
         hasKeyboardAccess: @escaping () -> Bool = { PhysicalKeyMonitor.hasAccess },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         toggleCapsLock: @escaping () -> Void = { DispatchQueue.main.async { KeyRemapper.toggleCapsLock() } }) {
        self.physicalKeys = physicalKeys
        self.hasKeyboardAccess = hasKeyboardAccess
        self.now = now
        self.toggleCapsLock = toggleCapsLock
        physicalKeys.onRelease = { [weak self] in self?.physicalCapsLockReleased() }
    }

    /// Fires for every recognized chord (Hypr + bound key).
    var onAction: ((Action) -> Void)?

    /// Main thread: whether two workspaces share a home monitor, so a
    /// queued switch can give way to a later one there. Unset = never.
    var sharesHomeMonitor: ((Int, Int) -> Bool)?
    private let switchCoalescer = SwitchCoalescer()

    /// Fires when the Hypr key transitions from up to down.
    var onHyprKeyDown: (() -> Void)?

    /// Fires when the Hypr key transitions from down to up.
    var onHyprKeyUp: (() -> Void)?

    // physical key currently acting as the logical Hypr modifier
    fileprivate var hyprKeyDown = false
    // an F18 release was ignored because Caps Lock was still held; the
    // physical release ends this press
    private var ignoredHyprRelease = false
    private var hyprKey: HyprKey = .capsLock
    private var pressedModifierKeyCodes: Set<UInt16> = []

    private var keybinds: [Keybind] = Keybind.defaults
    private var tilingEnabled = true
    // O(1) lookup: packed key = (keyCode << 16) | modifiers.rawValue
    private var keybindMap: [UInt32: Keybind] = [:]

    private static func packKey(_ keyCode: UInt16, _ modifiers: ModifierFlags) -> UInt32 {
        UInt32(keyCode) << 16 | UInt32(modifiers.rawValue & 0xFFFF)
    }

    /// Replace the active keybind set. Last-wins on duplicate chords.
    /// Builds the O(1) lookup map keyed by packed keyCode + modifiers.
    func updateKeybinds(_ binds: [Keybind]) {
        stateLock.lock()
        defer { stateLock.unlock() }
        keybinds = binds
        // last-wins for duplicate key combos
        keybindMap = [:]
        for bind in binds {
            keybindMap[Self.packKey(bind.keyCode, bind.modifiers)] = bind
        }
    }

    /// Paused, the Hypr key is no longer swallowed (see `handleEvent`).
    /// A key that stops being Hypr while paused also drops a press in
    /// progress: its release may never arrive (Caps Lock's remap is being
    /// removed), and a stuck Hypr would turn a typed P into a resume.
    func updateTilingEnabled(_ enabled: Bool) {
        stateLock.lock()
        tilingEnabled = enabled
        if !enabled, !hyprKey.keepsShortcutsWhilePaused {
            setHyprKeyDown(false)
            ignoredHyprRelease = false
        }
        stateLock.unlock()
    }

    /// The "Double-tap Hypr to toggle Caps Lock" setting.
    func updateDoubleTapCapsLock(_ on: Bool) {
        stateLock.lock()
        doubleTapCapsLock = on
        doubleTap.reset()
        stateLock.unlock()
    }

    static func actionIsAvailable(_ action: Action, tilingEnabled: Bool) -> Bool {
        tilingEnabled || action == .toggleTiling || action == .showKeybinds
            || action == .showWorkspaceOverview
    }

    /// Actions that fire once per physical press. Holding the chord down
    /// must not repeat them — a repeated pause toggle flaps, and a
    /// repeated command spawns a process per autorepeat tick.
    static func ignoresAutorepeat(_ action: Action) -> Bool {
        switch action {
        case .toggleTiling, .moveToNextEmptyWorkspace, .toggleMaximize, .runCommand, .retileAll:
            return true
        default:
            return false
        }
    }

    static func shouldDispatchAction(
        _ action: Action,
        tilingEnabled: Bool,
        isRepeat: Bool
    ) -> Bool {
        actionIsAvailable(action, tilingEnabled: tilingEnabled)
            && !(ignoresAutorepeat(action) && isRepeat)
    }

    /// Switch the physical key acting as the Hypr modifier. Resets any
    /// in-progress modifier state so a key already down at the moment
    /// of the swap is not misinterpreted.
    func updateHyprKey(_ key: HyprKey) {
        stateLock.lock()
        hyprKey = key
        hyprKeyDown = false
        ignoredHyprRelease = false
        pressedModifierKeyCodes.removeAll()
        doubleTap.reset()
        stateLock.unlock()
        hyprLog(.debug, .lifecycle, "hypr key set to \(key.displayName)")
        refreshPhysicalKeyMonitor()
    }

    /// Run the physical Caps Lock monitor only while it matters: Caps Lock
    /// is the Hypr key, the tap is running, and macOS lets us read
    /// keyboards (it does whenever Accessibility is granted). Otherwise no
    /// keyboard is opened and the tap behaves as it always has. Never asks
    /// for access. Main thread, never under `stateLock`: closing the
    /// manager can call back into `physicalCapsLockReleased`.
    ///
    /// `runLoop` defaults to the tap thread's; tests pass their own.
    func refreshPhysicalKeyMonitor(runLoop: CFRunLoop? = nil) {
        stateLock.lock()
        let key = hyprKey
        stateLock.unlock()
        let loop = runLoop ?? tapRunLoop

        guard key.usesCapsLockRemap, let loop else {
            if physicalKeys.isActive {
                stopPhysicalKeyMonitor(reason: "Hypr key is \(key.displayName)")
            }
            return
        }

        let granted = hasKeyboardAccess()
        if physicalKeys.isActive {
            // turned off while running: values may stop arriving, and a
            // stale held state would swallow the real release
            if !granted {
                stopPhysicalKeyMonitor(reason: "keyboard access was revoked")
            }
            return
        }
        // no access: the old behavior, no prompt, no log
        guard granted else { return }

        let result = physicalKeys.start(on: loop)
        if result == kIOReturnSuccess {
            lastPhysicalOpenFailure = nil
            hyprLog(.notice, .hotkey, "physical key monitor started")
        } else {
            // the old behavior until a later tick opens it
            if lastPhysicalOpenFailure != result {
                hyprLog(.notice, .hotkey, "physical key monitor failed to open (0x\(String(UInt32(bitPattern: result), radix: 16)))")
            }
            lastPhysicalOpenFailure = result
        }
    }

    private func stopPhysicalKeyMonitor(reason: String) {
        physicalKeys.stop()
        hyprLog(.notice, .hotkey, "physical key monitor stopped — \(reason)")
        // a release ignored before the stop would leave Hypr held with no
        // physical up left to end it
        stateLock.lock()
        if ignoredHyprRelease {
            ignoredHyprRelease = false
            setHyprKeyDown(false)
        }
        stateLock.unlock()
    }

    /// Install the event tap on a dedicated thread's run loop.
    /// No-op if the tap fails to create — typically means AX
    /// permission is missing; the failure is logged and `eventTap`
    /// stays nil.
    func start() {
        stateLock.lock()
        let alreadyStarted = eventTap != nil
        stateLock.unlock()
        guard !alreadyStarted else { return }

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

        stateLock.lock()
        eventTap = tap
        stateLock.unlock()
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

        // scheduled on the tap's run loop, so a busy main thread can't
        // delay a release either
        refreshPhysicalKeyMonitor()
        startTapHealthCheck()
        hyprLog(.debug, .lifecycle, "event tap started on dedicated thread, \(keybinds.count) keybinds (\(hyprKey.displayName) = Hypr key)")
    }

    /// Disable the tap, stop its thread, and drop the tap reference.
    /// Idempotent.
    func stop() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        physicalKeys.stop()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let rl = tapRunLoop {
            if let source = runLoopSource {
                CFRunLoopRemoveSource(rl, source, .commonModes)
            }
            CFRunLoopStop(rl)
        }
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
        stateLock.lock()
        eventTap = nil
        hyprKeyDown = false
        ignoredHyprRelease = false
        pressedModifierKeyCodes.removeAll()
        stateLock.unlock()
    }

    /// Lock-guarded tap access for the callback — it runs on the tap
    /// thread while `eventTap` is written from main in start()/stop().
    fileprivate func tapForCallback() -> CFMachPort? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return eventTap
    }

    /// Catch a silently dead tap. The callback re-enables on
    /// `tapDisabledByTimeout`, but a tap can also stop delivering with
    /// no disable event at all (re-sign race after rebuild, TCC flap) —
    /// a non-nil tap is not a healthy tap. Cheap: one flag read per tick,
    /// plus a keyboard access check while Caps Lock is the Hypr key, so
    /// revoked access stops the physical monitor and a later grant starts it.
    private func startTapHealthCheck() {
        healthCheckTimer?.invalidate()
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self, let tap = self.eventTap else { return }
            self.refreshPhysicalKeyMonitor()
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
        ignoredHyprRelease = false
        pressedModifierKeyCodes.removeAll()
        physicalKeys.reset()
    }

    /// The last physical Caps Lock came up, or its keyboard went away.
    /// Ends a press whose F18 release was ignored. On a normal press this
    /// lands a few ms before the F18 release and ends it a touch early.
    /// Runs on the tap thread.
    private func physicalCapsLockReleased() {
        stateLock.lock()
        defer { stateLock.unlock() }
        let wasIgnored = ignoredHyprRelease
        ignoredHyprRelease = false
        guard hyprKey.usesCapsLockRemap, hyprKeyDown else { return }
        if wasIgnored {
            hyprLog(.notice, .hotkey, "Caps Lock physically released — ending Hypr")
        }
        setHyprKeyDown(false, released: true)
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
    ///
    /// Native modifier Hypr keys answer from the keyDown's own flags. The
    /// tap swallows their flagsChanged, and `combinedSessionState` then
    /// often reports them up mid-chord (54 of 151 Left Control chords were
    /// dropped on 0.18.0). The keyDown flags come from the HID layer, so a
    /// dropped keyUp still shows as the flag missing.
    private func isHyprKeyActuallyDown(eventFlags: CGEventFlags) -> Bool? {
        if hyprKey.usesCapsLockRemap { return nil }
        if let nativeFlag = hyprKey.nativeModifierFlag {
            return eventFlags.contains(nativeFlag)
        }
        return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(hyprKey.keyCode))
    }

    /// Runs on the tap thread, per keystroke. Holds `stateLock` for the
    /// duration — pure dictionary/set work plus at most one IOKit query,
    /// so hold times are microseconds.
    func handleEvent(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        trackModifierState(type, keyCode)

        // track the configured physical key as our logical Hypr modifier
        if keyCode == hyprKey.keyCode {
            // paused: the key belongs to macOS again (#94). one that types
            // is not Hypr at all until tiling resumes
            if !tilingEnabled, !hyprKey.keepsShortcutsWhilePaused { return event }
            if type == .keyDown {
                setHyprKeyDown(true)
            } else if type == .keyUp {
                // macOS sends this F18 release when Control comes up, even
                // with Caps Lock still held. the keyboard itself knows better
                if hyprKey.usesCapsLockRemap, physicalKeys.isActive, physicalKeys.isCapsLockDown {
                    if hyprKeyDown && !ignoredHyprRelease {
                        hyprLog(.notice, .hotkey, "ignoring Hypr release — Caps Lock is still physically held")
                    }
                    ignoredHyprRelease = hyprKeyDown
                } else {
                    ignoredHyprRelease = false
                    setHyprKeyDown(false, released: true)
                }
            } else if type == .flagsChanged, hyprKey.isNativeModifier {
                setHyprKeyDown(pressedModifierKeyCodes.contains(keyCode), released: true)
            }
            // swallowed while tiling is on: it's our internal modifier.
            // paused it passes through and is only watched, so Hypr+P can resume
            return tilingEnabled ? nil : event
        }

        // another key or modifier going down makes this Hypr press a chord,
        // and breaks up a double tap
        if type != .keyUp { doubleTap.otherKeyDown() }

        // sanity check on every non-Hypr keyDown: if we think Hypr is held
        // but the HID layer says it isn't, our state is stale (dropped keyUp
        // from sleep, lock, modal sheet, etc.). clear before packing flags
        // so this stroke doesn't get routed as a chord. only runs when the
        // HID query is trustworthy — under the Caps→F18 remap it lies, so
        // we fall back to the sleep/wake/tap-disabled paths there.
        if type == .keyDown, hyprKeyDown, isHyprKeyActuallyDown(eventFlags: event.flags) == false {
            hyprLog(.notice, .hotkey, "stale hyprKeyDown detected on keyCode=\(keyCode) — HID says \(hyprKey.displayName) is up; clearing")
            setHyprKeyDown(false)
        }

        // only check keybinds on keyDown
        guard type == .keyDown else { return event }

        let flags = ModifierFlags.from(eventFlags(for: event), hyprDown: hyprKeyDown)

        let packed = HotkeyManager.packKey(keyCode, flags)
        if let bind = keybindMap[packed] {
            let action = bind.action
            guard Self.actionIsAvailable(action, tilingEnabled: tilingEnabled) else {
                return event
            }
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            guard Self.shouldDispatchAction(
                action, tilingEnabled: tilingEnabled, isRepeat: isRepeat) else {
                return nil
            }
            // case tag only — interpolating the Action would put payload
            // text (a runCommand command line) in the file log.
            hyprLog(.debug, .lifecycle,
                    "matched: \(ActionDispatcher.discriminator(for: action))")
            let token = switchCoalescer.enqueue(action)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let (run, merged) = self.switchCoalescer.admit(action, token: token, sameMonitor: { a, b in
                    self.sharesHomeMonitor?(a, b) ?? false
                }) else {
                    // skipped cycles are counted in the merged line instead
                    if case .switchWorkspace = action {
                        hyprLog(.debug, .lifecycle, "coalesced: \(ActionDispatcher.discriminator(for: action))")
                    }
                    return
                }
                if merged > 1, case .cycleWorkspace(let delta) = run {
                    hyprLog(.debug, .lifecycle, "coalesced: cycleWorkspace n=\(merged) delta=\(delta)")
                }
                self.onAction?(run)
            }
            return nil
        }

        return event
    }

    // assumes stateLock held. the onHyprKeyDown/Up callbacks fire async
    // on main, outside the lock. `released` marks the key really coming up;
    // every other false is a reset and can't finish a double tap.
    private func setHyprKeyDown(_ isDown: Bool, released: Bool = false) {
        let wasDown = hyprKeyDown
        hyprKeyDown = isDown
        if isDown && !wasDown {
            doubleTap.hyprDown(at: now())
        } else if !isDown && wasDown {
            if released {
                // paused, Hypr shortcuts are all that is left of the key
                if doubleTap.hyprUp(at: now()), doubleTapCapsLock, tilingEnabled {
                    hyprLog(.notice, .hotkey, "double tap — toggling Caps Lock")
                    toggleCapsLock()
                }
            } else {
                doubleTap.reset()
            }
        }
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

/// Spots two lone taps of the Hypr key for "Double-tap Hypr to toggle
/// Caps Lock". A tap is a press and release within `window` with no other
/// key or modifier going down. Two taps count when the second press starts
/// within `window` of the first release. A chord, a hold or a key in
/// between starts over. Mouse buttons are not seen.
struct HyprDoubleTap {
    static let window: TimeInterval = 0.3

    private var pressStart: TimeInterval?
    private var used = false
    private var lastTapEnd: TimeInterval?

    mutating func hyprDown(at time: TimeInterval) {
        pressStart = time
        used = false
    }

    mutating func otherKeyDown() {
        used = true
        lastTapEnd = nil
    }

    /// true when this release completes a double tap
    mutating func hyprUp(at time: TimeInterval) -> Bool {
        guard let start = pressStart else { return false }
        pressStart = nil
        guard !used, time - start <= Self.window else {
            lastTapEnd = nil
            return false
        }
        if let last = lastTapEnd, start - last <= Self.window {
            lastTapEnd = nil
            return true
        }
        lastTapEnd = time
        return false
    }

    mutating func reset() {
        pressStart = nil
        used = false
        lastTapEnd = nil
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
            if let tap = mgr.tapForCallback() {
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
