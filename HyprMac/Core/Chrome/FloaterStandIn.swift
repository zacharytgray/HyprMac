// The floater stand-in: while a tile covers a floating window, a HyprMac
// panel sits on the floater's frame above the tiles, so the floater looks
// like it stayed on top. macOS won't let HyprMac set another app's window
// level, and raising the floater after each click blinked and took the
// keyboard. Touching the panel brings the real window up and passes the
// click on. `FloaterStandInPlan` decides which floaters get one.
//
// Two looks: `card` (app icon and title, no permission) and `live` (a
// ScreenCaptureKit picture, needs Screen Recording). A live floater keeps
// its stream running while any tile overlaps it, so the picture is ready
// the moment a click buries it.

import Cocoa
import ScreenCaptureKit

/// Owns the stand-in panels and their capture streams.
///
/// Threading: main-thread only.
final class FloaterStandIn {
    /// What the panel needs to know about a floater.
    struct Floater: Equatable {
        let id: CGWindowID
        var frame: CGRect
        let pid: pid_t
        var title: String?
    }

    enum Touch: String {
        case click, scroll, rightClick = "right click"
    }

    // wired by WindowManager
    var primaryScreenHeight: () -> CGFloat = { NSScreen.screens.first?.frame.height ?? 0 }
    /// the floater outline's panel, so the stand-in goes just below it
    var outlineWindowNumber: (CGWindowID) -> Int? = { _ in nil }
    var outlineColor: () -> CGColor = { NSColor.systemPurple.cgColor }
    /// the floater's title for the card, read when a panel goes up
    var readTitle: (CGWindowID) -> String? = { _ in nil }
    /// gives the real floater focus and raises it. false when it is gone
    var focusFloater: (CGWindowID) -> Bool = { _ in false }
    /// a fresh window-list read: does a tile still cover the floater
    var isCovered: (CGWindowID) -> Bool = { _ in false }
    var handOffFinished: () -> Void = {}
    /// the mouse button is down: a panel shown on the press stays up
    var isPressDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    /// a press hold ran out: refresh so a wrong guess comes down
    var holdEnded: () -> Void = {}
    /// the Settings switch, "Keep floating windows in front"
    var isOn: () -> Bool = { false }
    var forcesCard: () -> Bool = { FloaterStandInMode.debugForcesCard() }
    var preflightCapture: () -> Bool = { CGPreflightScreenCaptureAccess() }
    var requestCapture: () -> Bool = { CGRequestScreenCaptureAccess() }

    /// how long a hand-off waits for the real window to come up
    static let handOffTimeout: CFAbsoluteTime = 0.3
    static let handOffPoll: TimeInterval = 0.01
    /// the least time a panel shown on a press stays up, for a click shorter
    /// than the clicked app's raise
    static let pressHold: CFAbsoluteTime = 0.25
    /// after the panel goes, before the click is passed on, so the window
    /// server routes it to the real window and not to the panel
    static let passOnDelay: TimeInterval = 0.02
    /// how often a refresh asks again whether Screen Recording is granted
    static let captureRecheck: CFAbsoluteTime = 2

    private final class Entry {
        var floater: Floater
        let panel: StandInPanel
        let view: StandInView
        var stream: StandInStream?
        // a stream that failed is not retried before this
        var streamRetryAfter: CFAbsoluteTime = 0
        var shown = false
        // shown on a press, before the tile rose. a refresh during the press
        // still sees the floater in front and must not take it down
        var heldUntil: CFAbsoluteTime?
        init(floater: Floater, panel: StandInPanel, view: StandInView) {
            self.floater = floater
            self.panel = panel
            self.view = view
        }
    }

    private var entries: [CGWindowID: Entry] = [:]
    private(set) var mode: FloaterStandInMode?
    private var captureGranted: Bool?
    private var captureCheckedAt: CFAbsoluteTime = -.infinity
    private var handOff: (id: CGWindowID, started: CFAbsoluteTime)?

    var shownIDs: Set<CGWindowID> { Set(entries.values.filter(\.shown).map(\.floater.id)) }
    var isEnabled: Bool { currentMode() != .off }

    /// The mode from the switch and the permission, read on each refresh so
    /// a grant is picked up without a restart when macOS allows it. A change
    /// tears down every panel and stream.
    @discardableResult
    func currentMode() -> FloaterStandInMode {
        let on = isOn()
        let now = FloaterStandInMode.resolve(on: on, captureGranted: on && isCaptureGranted(),
                                             forcesCard: forcesCard())
        if now != mode {
            if mode != nil { reset(reason: "mode \(now.rawValue)") }
            hyprLog(.notice, .floating, "stand-in mode \(now.rawValue)")
            mode = now
        }
        return now
    }

    /// The switch went on: ask for Screen Recording when it isn't granted.
    /// macOS shows its prompt once; later asks return at once.
    func askForCaptureIfNeeded() {
        mainThreadOnly()
        captureCheckedAt = -.infinity
        guard isOn(), !isCaptureGranted() else { return }
        hyprLog(.notice, .floating, "stand-in asking for screen recording")
        let granted = requestCapture()
        hyprLog(.notice, .floating, "stand-in screen recording request returned \(granted)")
        captureCheckedAt = -.infinity
    }

    /// Bring the panels and streams in line with the stack: a panel on each
    /// covered floater, a stream on each one a tile overlaps.
    func apply(covered: Set<CGWindowID>, atRisk: Set<CGWindowID>,
               floaters: [CGWindowID: Floater]) {
        mainThreadOnly()
        let current = currentMode()
        guard current != .off else { return }
        let live = current == .live
        for id in covered.union(atRisk) {
            guard let floater = floaters[id] else { continue }
            entry(for: floater)
        }
        let now = CFAbsoluteTimeGetCurrent()
        for entry in entries.values where entry.floater.id != handOff?.id {
            if covered.contains(entry.floater.id) {
                entry.heldUntil = nil
                show(entry, reason: "covered")
            } else if entry.shown {
                if let held = entry.heldUntil, now < held || isPressDown() { continue }
                entry.heldUntil = nil
                hide(entry, reason: "uncovered")
            }
        }
        for (id, entry) in entries {
            if live, atRisk.contains(id) || covered.contains(id) {
                startStream(entry)
            } else if entry.stream != nil {
                stopStream(entry, reason: live ? "no overlap" : "not live")
            }
        }
        for (id, entry) in entries where !entry.shown && entry.stream == nil && id != handOff?.id {
            entry.panel.orderOut(nil)
            entries[id] = nil
        }
    }

    /// A press on a tile is about to bury these. Up on the mouse-down; the
    /// restack refresh after the mouse-up corrects it.
    func showPredicted(_ ids: Set<CGWindowID>, floaters: [CGWindowID: Floater], tile: CGWindowID) {
        mainThreadOnly()
        guard currentMode() != .off else { return }
        var held = false
        for id in ids where id != handOff?.id {
            guard let floater = floaters[id] else { continue }
            let entry = entry(for: floater)
            if !entry.shown {
                entry.heldUntil = CFAbsoluteTimeGetCurrent() + Self.pressHold
                held = true
            }
            show(entry, reason: "press on tile \(tile)")
        }
        guard held else { return }
        // the mouse-up's refresh decides; this one catches a guess that was
        // wrong when that refresh came inside the hold
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pressHold + 0.02) { [weak self] in
            self?.holdEnded()
        }
    }

    func hide(_ id: CGWindowID, reason: String) {
        mainThreadOnly()
        guard let entry = entries[id] else { return }
        if entry.shown { hide(entry, reason: reason) }
    }

    /// Order out every panel. Streams stay; the next refresh stops the ones
    /// no longer needed.
    func hideAll(reason: String) {
        mainThreadOnly()
        for entry in entries.values where entry.shown { hide(entry, reason: reason) }
    }

    /// Order out every panel and stop every stream.
    func reset(reason: String) {
        mainThreadOnly()
        for entry in entries.values {
            if entry.shown { hide(entry, reason: reason) }
            if entry.stream != nil { stopStream(entry, reason: reason) }
            entry.panel.orderOut(nil)
        }
        entries.removeAll()
        handOff = nil
    }

    /// The floater moved or resized: the panel and the picture follow.
    func follow(_ id: CGWindowID, to frame: CGRect) {
        mainThreadOnly()
        guard let entry = entries[id], entry.floater.frame != frame else { return }
        let resized = entry.floater.frame.size != frame.size
        entry.floater.frame = frame
        if entry.shown { place(entry) }
        if resized { entry.stream?.resize(to: frame.size, scale: scale(for: frame)) }
    }

    /// The floater whose panel is under `point` (CG), nil when none.
    func floater(at point: CGPoint) -> CGWindowID? {
        entries.values.first { $0.shown && $0.floater.id != handOff?.id && $0.floater.frame.contains(point) }?
            .floater.id
    }

    // MARK: - panels

    @discardableResult
    private func entry(for floater: Floater) -> Entry {
        if let existing = entries[floater.id] {
            if existing.floater.frame != floater.frame {
                follow(floater.id, to: floater.frame)
            }
            if let title = floater.title { existing.floater.title = title }
            return existing
        }
        let view = StandInView(frame: .zero)
        let panel = StandInPanel(view: view)
        let entry = Entry(floater: floater, panel: panel, view: view)
        let id = floater.id
        view.onTouch = { [weak self] touch, point in self?.touched(id, touch: touch, at: point) }
        entries[id] = entry
        return entry
    }

    private func show(_ entry: Entry, reason: String) {
        place(entry)
        if !entry.shown { entry.floater.title = readTitle(entry.floater.id) }
        entry.view.showCard(icon: NSRunningApplication(processIdentifier: entry.floater.pid)?.icon,
                            title: entry.floater.title, tint: outlineColor(),
                            cornerRadius: WindowCornerRadius.resolve(for: entry.floater.id))
        entry.view.setLive(mode == .live && entry.stream != nil)
        guard !entry.shown else { return }
        entry.shown = true
        if let outline = outlineWindowNumber(entry.floater.id) {
            entry.panel.order(.below, relativeTo: outline)
        } else {
            entry.panel.orderFrontRegardless()
        }
        hyprLog(.notice, .floating, "stand-in shown wid=\(entry.floater.id) reason=\(reason) "
                + "look=\(entry.view.showsLivePicture ? "live" : "card") frame=\(Self.describe(entry.floater.frame))")
    }

    private func hide(_ entry: Entry, reason: String) {
        entry.panel.orderOut(nil)
        entry.shown = false
        entry.heldUntil = nil
        hyprLog(.notice, .floating, "stand-in hidden wid=\(entry.floater.id) reason=\(reason)")
    }

    private func place(_ entry: Entry) {
        let f = entry.floater.frame
        let rect = NSRect(x: f.minX, y: primaryScreenHeight() - f.maxY, width: f.width, height: f.height)
        if entry.panel.frame != rect { entry.panel.setFrame(rect, display: true) }
    }

    // MARK: - hand-off

    /// A touch on the panel: focus the real floater, wait for it to come
    /// up, hide the panel, then pass a click on at the same point.
    private func touched(_ id: CGWindowID, touch: Touch, at point: CGPoint) {
        guard handOff == nil, let entry = entries[id], entry.shown else { return }
        let started = CFAbsoluteTimeGetCurrent()
        handOff = (id, started)
        hyprLog(.notice, .floating, "stand-in hand-off wid=\(id) touch=\(touch.rawValue) at=(\(Int(point.x)),\(Int(point.y)))")
        guard focusFloater(id) else {
            handOff = nil
            hide(entry, reason: "hand-off: floater gone")
            return
        }
        pollHandOff(id, touch: touch, at: point, started: started)
    }

    private func pollHandOff(_ id: CGWindowID, touch: Touch, at point: CGPoint, started: CFAbsoluteTime) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handOffPoll) { [weak self] in
            guard let self, self.handOff?.id == id else { return }
            let elapsed = CFAbsoluteTimeGetCurrent() - started
            let covered = self.isCovered(id)
            guard !covered || elapsed >= Self.handOffTimeout else {
                self.pollHandOff(id, touch: touch, at: point, started: started)
                return
            }
            self.handOff = nil
            if let entry = self.entries[id], entry.shown {
                self.hide(entry, reason: covered ? "hand-off timed out" : "hand-off")
            }
            let ms = Int(elapsed * 1000)
            // still covered, a click would land on the tile
            guard !covered else {
                hyprLog(.notice, .floating, "stand-in hand-off wid=\(id) gave up after \(ms) ms, still covered; "
                        + "touch not passed on")
                self.handOffFinished()
                return
            }
            guard touch == .click else {
                hyprLog(.notice, .floating, "stand-in hand-off wid=\(id) real window up after \(ms) ms; nothing passed on")
                self.handOffFinished()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.passOnDelay) { [weak self] in
                let held = NSEvent.pressedMouseButtons & 1 != 0
                let target = Self.windowUnder(point)
                Self.postClick(at: point, held: held)
                hyprLog(.notice, .floating, "stand-in hand-off wid=\(id) real window up after \(ms) ms; "
                        + (held ? "press passed on, button still down" : "click passed on")
                        + " to wid=\(target.map(String.init) ?? "?")")
                self?.handOffFinished()
            }
        }
    }

    /// The window a click at `point` reaches, for the log. Our own panels
    /// (the dim) take no clicks.
    private static func windowUnder(_ point: CGPoint) -> CGWindowID? {
        let own = getpid()
        return WindowStacking.onScreen()?.first {
            // the Dock keeps a screen-sized window above layer 0 that takes no clicks
            $0.ownerPID != own && $0.alpha > 0.01 && WindowStacking.isFloaterLayer($0.layer)
                && ($0.bounds?.contains(point) ?? false)
        }?.windowID
    }

    /// The press goes to whatever is under `point` now, the real floater.
    /// With the button still down only the down is posted: the user's own
    /// mouse-up ends it, and a drag that started on the panel drags the window.
    private static func postClick(at point: CGPoint, held: Bool) {
        let types: [CGEventType] = held ? [.leftMouseDown] : [.leftMouseDown, .leftMouseUp]
        for type in types {
            let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                mouseCursorPosition: point, mouseButton: .left)
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
            event?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - capture

    /// Screen Recording, asked again at most every `captureRecheck`.
    private func isCaptureGranted() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if let granted = captureGranted, now - captureCheckedAt < Self.captureRecheck { return granted }
        captureCheckedAt = now
        let granted = preflightCapture()
        if granted != captureGranted {
            captureGranted = granted
            hyprLog(.notice, .floating, "stand-in screen recording \(granted ? "granted" : "not granted")"
                    + (granted ? "" : ", card look until it is"))
        }
        return granted
    }

    private func startStream(_ entry: Entry) {
        guard entry.stream == nil, CFAbsoluteTimeGetCurrent() >= entry.streamRetryAfter else { return }
        let id = entry.floater.id
        let stream = StandInStream(windowID: id)
        stream.onFrame = { [weak self, weak entry, weak stream] surface in
            guard let self, let entry, let stream, entry.stream === stream else { return }
            entry.view.setSurface(surface)
            entry.view.setLive(self.mode == .live)
        }
        stream.onStop = { [weak entry, weak stream] why in
            guard let entry, let stream, entry.stream === stream else { return }
            entry.stream = nil
            entry.streamRetryAfter = CFAbsoluteTimeGetCurrent() + 5
            entry.view.setSurface(nil)
            entry.view.setLive(false)
            hyprLog(.notice, .floating, "stand-in stream stopped wid=\(id) reason=\(why)")
        }
        entry.stream = stream
        stream.start(size: entry.floater.frame.size, scale: scale(for: entry.floater.frame))
    }

    private func stopStream(_ entry: Entry, reason: String) {
        guard let stream = entry.stream else { return }
        entry.stream = nil
        stream.stop()
        entry.view.setSurface(nil)
        entry.view.setLive(false)
        hyprLog(.notice, .floating, "stand-in stream stopped wid=\(entry.floater.id) reason=\(reason)")
    }

    private func scale(for frame: CGRect) -> CGFloat {
        let h = primaryScreenHeight()
        let ns = NSRect(x: frame.minX, y: h - frame.maxY, width: frame.width, height: frame.height)
        let screen = NSScreen.screens.max {
            $0.frame.intersection(ns).width * $0.frame.intersection(ns).height
                < $1.frame.intersection(ns).width * $1.frame.intersection(ns).height
        }
        return screen?.backingScaleFactor ?? 2
    }

    static func describe(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))"
    }
}

// MARK: - panel and view

/// Borderless, non-activating, never key. Out of the window cycle and
/// Mission Control like the other chrome panels.
final class StandInPanel: NSPanel {
    init(view: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        // above the tiles and the dim (.floating - 1). the outline is
        // ordered above it at the same level
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        // set outright: a clear window passes clicks through wherever its
        // backing is clear, and the live picture is a layer, not the backing
        ignoresMouseEvents = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        animationBehavior = .none
        isReleasedWhenClosed = false
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class StandInView: NSView {
    var onTouch: ((FloaterStandIn.Touch, CGPoint) -> Void)?
    private let background = NSVisualEffectView()
    private let tintLayer = CALayer()
    private let liveLayer = CALayer()
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private var surface: IOSurface?
    private(set) var showsLivePicture = false
    private var liveState: Bool?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        background.material = .windowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.masksToBounds = true
        background.layer?.addSublayer(tintLayer)
        addSubview(background)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
        titleField.alignment = .center
        titleField.textColor = .secondaryLabelColor
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        addSubview(titleField)
        liveLayer.contentsGravity = .resize
        liveLayer.isHidden = true
        layer?.addSublayer(liveLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { touch(.click, event) }
    override func rightMouseDown(with event: NSEvent) { touch(.rightClick, event) }
    override func scrollWheel(with event: NSEvent) { touch(.scroll, event) }
    // the drag and the mouse-up belong to the real window once it is up
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    private func touch(_ kind: FloaterStandIn.Touch, _ event: NSEvent) {
        let point = event.cgEvent?.location ?? {
            let ns = NSEvent.mouseLocation
            return CGPoint(x: ns.x, y: (NSScreen.screens.first?.frame.height ?? 0) - ns.y)
        }()
        onTouch?(kind, point)
    }

    func showCard(icon: NSImage?, title: String?, tint: CGColor, cornerRadius: CGFloat) {
        iconView.image = icon
        titleField.stringValue = title ?? ""
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.backgroundColor = NSColor(cgColor: tint)?.withAlphaComponent(0.1).cgColor
        background.layer?.cornerRadius = cornerRadius
        liveLayer.cornerRadius = cornerRadius
        CATransaction.commit()
        needsLayout = true
    }

    func setSurface(_ surface: IOSurface?) {
        self.surface = surface
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveLayer.contents = surface
        CATransaction.commit()
    }

    /// The picture shows once the stream has one; until then the card does.
    func setLive(_ live: Bool) {
        let showLive = live && surface != nil
        guard showLive != liveState else { return }
        liveState = showLive
        showsLivePicture = showLive
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveLayer.isHidden = !showLive
        CATransaction.commit()
        background.isHidden = showLive
        iconView.isHidden = showLive
        needsLayout = true
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.frame = background.bounds
        liveLayer.frame = bounds
        CATransaction.commit()
        let side = max(16, min(64, min(bounds.width, bounds.height) * 0.4))
        let titleHeight: CGFloat = bounds.height > side + 40 ? 18 : 0
        let total = side + (titleHeight > 0 ? 8 + titleHeight : 0)
        let top = (bounds.height + total) / 2
        iconView.frame = NSRect(x: (bounds.width - side) / 2, y: top - side, width: side, height: side)
        titleField.isHidden = showsLivePicture || titleHeight == 0
        titleField.frame = NSRect(x: 12, y: top - side - 8 - titleHeight,
                                  width: max(0, bounds.width - 24), height: titleHeight)
    }
}

// MARK: - capture stream

/// One ScreenCaptureKit stream of one window. The window's own content,
/// whatever covers it. Frames arrive on the main queue.
final class StandInStream: NSObject, SCStreamOutput, SCStreamDelegate {
    let windowID: CGWindowID
    var onFrame: (IOSurface) -> Void = { _ in }
    var onStop: (String) -> Void = { _ in }
    private var stream: SCStream?
    private var stopped = false
    private var frames = 0
    private var startedAt: CFAbsoluteTime = 0

    init(windowID: CGWindowID) {
        self.windowID = windowID
    }

    func start(size: CGSize, scale: CGFloat) {
        startedAt = CFAbsoluteTimeGetCurrent()
        let id = windowID
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                guard let window = content?.windows.first(where: { $0.windowID == id }) else {
                    self.stopped = true
                    self.onStop("no capturable window\(error.map { ": \($0.localizedDescription)" } ?? "")")
                    return
                }
                self.begin(window, size: size, scale: scale)
            }
        }
    }

    private func begin(_ window: SCWindow, size: CGSize, scale: CGFloat) {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = Self.configuration(size: size, scale: scale)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
        } catch {
            stopped = true
            onStop("output: \(error.localizedDescription)")
            return
        }
        self.stream = stream
        stream.startCapture { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                let ms = Int((CFAbsoluteTimeGetCurrent() - self.startedAt) * 1000)
                if let error {
                    self.stopped = true
                    self.stream = nil
                    self.onStop("start failed: \(error.localizedDescription)")
                    return
                }
                hyprLog(.notice, .floating, "stand-in stream started wid=\(self.windowID) in \(ms) ms "
                        + "\(config.width)x\(config.height)")
                if self.stopped { stream.stopCapture(completionHandler: nil) }
            }
        }
    }

    private static func configuration(size: CGSize, scale: CGFloat) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = max(2, Int(size.width * scale))
        config.height = max(2, Int(size.height * scale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 3
        if #available(macOS 14.0, *) { config.ignoreShadowsSingleWindow = true }
        return config
    }

    func resize(to size: CGSize, scale: CGFloat) {
        guard let stream, !stopped else { return }
        stream.updateConfiguration(Self.configuration(size: size, scale: scale)) { _ in }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        stream?.stopCapture(completionHandler: nil)
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, !stopped, let buffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
        frames += 1
        if frames == 1 {
            let ms = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            hyprLog(.notice, .floating, "stand-in stream first picture wid=\(windowID) after \(ms) ms")
        }
        onFrame(surface)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.stopped = true
            self.stream = nil
            self.onStop("error: \(error.localizedDescription)")
        }
    }
}
