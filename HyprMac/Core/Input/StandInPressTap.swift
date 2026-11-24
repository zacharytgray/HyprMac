// A mouse-down on a tile that overlaps a floater makes the clicked app raise
// the tile over it. The NSEvent global monitor hears the press only after
// the app has it, so a stand-in shown from there races the raise. This
// active event tap hears the press first: it puts the floater's stand-in up
// before it hands the event on. It runs on its own thread, so a busy main
// thread never delays a click; it reads only a snapshot the main thread
// keeps current, and the window list, and sets the panel's alpha in the
// window server directly. The main thread then shows the panel properly.
//
// Installed only while "Keep floating windows in front" is on.

import Cocoa

final class StandInPressTap {
    /// A tile and the stand-ins that go up when it is pressed.
    struct Zone: Equatable {
        let tileID: CGWindowID
        let tileFrame: CGRect
        let floaterIDs: Set<CGWindowID>
        let windowNumbers: [Int]
    }

    /// main thread, after the tap raised panels: the tile pressed, the
    /// floaters it covers, the panels raised
    var onPress: (CGWindowID, Set<CGWindowID>, [Int]) -> Void = { _, _, _ in }

    private let lock = NSLock()
    private var zones: [Zone] = []
    private var floaterIDs: Set<CGWindowID> = []
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var source: CFRunLoopSource?

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return tap != nil
    }

    /// The zones the tap acts on, from the main thread.
    func update(zones: [Zone], floaterIDs: Set<CGWindowID>) {
        lock.lock()
        self.zones = zones
        self.floaterIDs = floaterIDs
        lock.unlock()
    }

    func start() {
        guard !isRunning else { return }
        let mask: CGEventMask = 1 << CGEventType.leftMouseDown.rawValue
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: standInPressCallback, userInfo: refcon) else {
            hyprLog(.notice, .floating, "stand-in mouse-down tap could not be created")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        lock.lock()
        self.tap = tap
        self.source = source
        lock.unlock()
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.lock.lock()
            self?.runLoop = CFRunLoopGetCurrent()
            self?.lock.unlock()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "HyprMac.StandInPressTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        hyprLog(.notice, .floating, "stand-in mouse-down tap on")
    }

    func stop() {
        lock.lock()
        let tap = self.tap, runLoop = self.runLoop, source = self.source
        self.tap = nil
        self.runLoop = nil
        self.source = nil
        zones = []
        lock.unlock()
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoop, let source {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFRunLoopStop(runLoop)
        }
        CFMachPortInvalidate(tap)
        hyprLog(.notice, .floating, "stand-in mouse-down tap off")
    }

    fileprivate func reenable() {
        lock.lock()
        let tap = self.tap
        lock.unlock()
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Tap thread. Returns fast when the press is nowhere near a zone.
    fileprivate func handle(_ event: CGEvent) {
        // our own posted clicks (the hand-off) are not the user's
        guard event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) else { return }
        let point = event.location
        lock.lock()
        let candidates = zones.filter { $0.tileFrame.contains(point) }
        let floaters = floaterIDs
        lock.unlock()
        guard !candidates.isEmpty, let windows = WindowStacking.onScreen() else { return }
        // what the press lands on: a raised window of another app does not
        // block, the same way hover sees it
        guard case .window(let hit) = WindowStacking.hitTest(point, in: windows, frontmostPID: nil,
                                                             ownPID: getpid(), managedFloaters: floaters),
              let zone = candidates.first(where: { $0.tileID == hit }) else { return }
        for number in zone.windowNumbers { Self.setAlpha(number, 1) }
        DispatchQueue.main.async { [weak self] in
            self?.onPress(zone.tileID, zone.floaterIDs, zone.windowNumbers)
        }
    }

    // MARK: - SkyLight

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SetWindowAlpha = @convention(c) (Int32, UInt32, Float) -> Int32

    private static let calls: (MainConnectionID, SetWindowAlpha)? = {
        // RTLD_DEFAULT: SkyLight is already linked
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let main = dlsym(handle, "SLSMainConnectionID"),
              let alpha = dlsym(handle, "SLSSetWindowAlpha") else { return nil }
        return (unsafeBitCast(main, to: MainConnectionID.self), unsafeBitCast(alpha, to: SetWindowAlpha.self))
    }()

    /// Our own window's alpha in the window server, behind AppKit's back.
    /// The main thread puts AppKit's value back in line right after.
    static func setAlpha(_ windowNumber: Int, _ alpha: Float) {
        guard let (main, setAlpha) = calls, windowNumber > 0 else { return }
        _ = setAlpha(main(), UInt32(windowNumber), alpha)
    }
}

private func standInPressCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                  refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<StandInPressTap>.fromOpaque(refcon).takeUnretainedValue()
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        tap.reenable()
    case .leftMouseDown:
        tap.handle(event)
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}
