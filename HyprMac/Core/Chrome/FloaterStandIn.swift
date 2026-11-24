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
// the moment a click buries it, and keeps its last picture after that.
//
// No window churn: each floater's panel is made once, stays ordered in at
// the floating level, and is shown and hidden with its alpha. A panel goes
// up before a tile can rise (`showPredicted`) and comes down only once the
// window list says the real floater is on top twice in a row.

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

    /// Where the real floater is, from a fresh window-list read.
    enum CoverState {
        /// a tile is stacked above it where they overlap
        case covered
        /// above every tile it overlaps
        case onTop
        /// not on screen
        case gone
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
    var coverState: (CGWindowID) -> CoverState = { _ in .gone }
    var handOffFinished: () -> Void = {}
    /// the mouse button is down: a panel shown on a press stays up
    var isPressDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    /// a press hold ran out: refresh so a wrong guess comes down
    var holdEnded: () -> Void = {}
    /// a panel went up or down, or one got a picture
    var panelsChanged: () -> Void = {}
    /// a confirmed hide or an early show changed what is on top: cut and
    /// order the floaters' chrome again, in the same pass
    var chromeChanged: () -> Void = {}
    /// the Settings switch, "Keep floating windows in front"
    var isOn: () -> Bool = { false }
    var forcesCard: () -> Bool = { FloaterStandInMode.debugForcesCard() }
    var preflightCapture: () -> Bool = { CGPreflightScreenCaptureAccess() }
    var requestCapture: () -> Bool = { CGRequestScreenCaptureAccess() }

    /// how long a hand-off waits for the real window to come up
    static let handOffTimeout: CFAbsoluteTime = 0.4
    /// one display frame
    static let poll: TimeInterval = 1.0 / 60
    /// the least time a panel shown ahead of a raise stays up, for a click
    /// shorter than the clicked app's raise
    static let pressHold: CFAbsoluteTime = 0.25
    /// after the panel goes, before the click is passed on, so the window
    /// server routes it to the real window and not to the panel
    static let passOnDelay: TimeInterval = 0.02
    /// window-list reads in a row that must show the real floater on top
    /// before a panel comes down. one read can be a frame early
    static let confirmReads = 2
    /// polls before a confirm gives up and leaves the panel to the next refresh
    static let confirmLimit = 30
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
        // shown ahead of a raise. a refresh in between still sees the
        // floater in front and must not take it down
        var heldUntil: CFAbsoluteTime?
        // a confirm loop is reading the window list before a hide
        var confirming = false
        // windows stacked above the floater: the picture leaves them out
        var cuts: [ChromeCut] = []
        // a touch on a cut part went through to the window in front
        var passingThrough = false
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

    /// Panels that are down but could go up with a real picture at once
    /// (any card in the card look), by floater, with their window numbers.
    func warmPanels() -> [CGWindowID: Int] {
        var result: [CGWindowID: Int] = [:]
        for (id, entry) in entries where !entry.shown && id != handOff?.id && hasLook(entry) {
            result[id] = entry.panel.windowNumber
        }
        return result
    }

    /// Bring the panels and streams in line with the stack: a panel up on
    /// each covered floater, a stream on each one a tile overlaps. `known`
    /// is every managed floater; a panel for anything else goes for good.
    func apply(covered: Set<CGWindowID>, atRisk: Set<CGWindowID>,
               floaters: [CGWindowID: Floater], known: Set<CGWindowID>) {
        mainThreadOnly()
        let current = currentMode()
        guard current != .off else { return }
        for (id, entry) in entries where !known.contains(id) { destroy(entry, reason: "not a floater") }
        for id in covered.union(atRisk) {
            guard let floater = floaters[id] else { continue }
            entry(for: floater)
        }
        let now = CFAbsoluteTimeGetCurrent()
        for entry in entries.values where entry.floater.id != handOff?.id {
            if covered.contains(entry.floater.id) {
                entry.heldUntil = nil
                show(entry, trigger: "covered")
            } else if entry.shown {
                if let held = entry.heldUntil, now < held || isPressDown() { continue }
                entry.heldUntil = nil
                confirmThenHide(entry, trigger: "refresh")
            }
        }
        let live = current == .live
        for (id, entry) in entries {
            if live, atRisk.contains(id) || covered.contains(id) {
                startStream(entry)
            } else if entry.stream != nil {
                stopStream(entry, reason: live ? "no overlap" : "not live")
            }
        }
    }

    /// A tile is about to rise over these: up now, before the raise. With
    /// `requireWarm` only panels that have a real picture go up; a guess is
    /// worth making only when it can't show the wrong thing.
    func showPredicted(_ ids: Set<CGWindowID>, floaters: [CGWindowID: Floater], trigger: String,
                       requireWarm: Bool = false) {
        mainThreadOnly()
        guard currentMode() != .off else { return }
        var held = false
        for id in ids where id != handOff?.id {
            guard let floater = floaters[id] else { continue }
            let entry = entry(for: floater)
            if requireWarm, !hasLook(entry) { continue }
            if !entry.shown {
                entry.heldUntil = CFAbsoluteTimeGetCurrent() + Self.pressHold
                held = true
            }
            show(entry, trigger: trigger)
        }
        guard held else { return }
        chromeChanged()
        // the mouse-up's refresh decides; this one catches a guess that was
        // wrong when that refresh came inside the hold
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pressHold + 0.02) { [weak self] in
            self?.holdEnded()
        }
    }

    /// Floaters a workspace switch just put back, before its tiles come
    /// back: each panel that kept a picture goes up at once on its last
    /// frame. The refresh after the switch takes down the ones on top.
    func showKept(_ ids: Set<CGWindowID>, trigger: String) {
        mainThreadOnly()
        var floaters: [CGWindowID: Floater] = [:]
        for id in ids { if let entry = entries[id], entry.view.hasPicture { floaters[id] = entry.floater } }
        guard !floaters.isEmpty else { return }
        showPredicted(Set(floaters.keys), floaters: floaters, trigger: trigger, requireWarm: true)
    }

    /// The real floater is being brought up (hover onto the panel, a focus
    /// of the floater). The panel stays until the window list shows it on top.
    func reveal(_ id: CGWindowID, trigger: String) {
        mainThreadOnly()
        guard let entry = entries[id], entry.shown else { return }
        entry.heldUntil = nil
        confirmThenHide(entry, trigger: trigger)
    }

    /// Down now, for a reason that leaves nothing to confirm.
    func hide(_ id: CGWindowID, reason: String) {
        mainThreadOnly()
        guard let entry = entries[id], entry.shown else { return }
        hide(entry, trigger: reason)
    }

    /// Every panel down. Panels and streams stay; the next refresh stops
    /// the streams no longer needed.
    func hideAll(reason: String) {
        mainThreadOnly()
        for entry in entries.values where entry.shown { hide(entry, trigger: reason) }
    }

    /// The floater is gone for good: its panel and stream go.
    func forget(_ id: CGWindowID, reason: String) {
        mainThreadOnly()
        guard let entry = entries[id] else { return }
        destroy(entry, reason: reason)
    }

    /// Every panel and stream gone.
    func reset(reason: String) {
        mainThreadOnly()
        for entry in entries.values { destroy(entry, reason: reason) }
        entries.removeAll()
        handOff = nil
    }

    /// The floater moved or resized: the panel and the picture follow.
    func follow(_ id: CGWindowID, to frame: CGRect) {
        mainThreadOnly()
        guard let entry = entries[id], entry.floater.frame != frame else { return }
        let resized = entry.floater.frame.size != frame.size
        entry.floater.frame = frame
        place(entry)
        if resized { entry.stream?.resize(to: frame.size, scale: scale(for: frame)) }
    }

    /// The floater whose panel is up under `point` (CG), nil when none. A
    /// part cut for a window in front is that window's.
    func floater(at point: CGPoint) -> CGWindowID? {
        entries.values.first {
            $0.shown && $0.floater.id != handOff?.id && $0.floater.frame.contains(point)
                && !FloaterStandInPlan.isCut(point, by: $0.cuts, cornerRadius: WindowCornerRadius.global)
        }?.floater.id
    }

    /// The windows stacked above each floater, from
    /// `FloaterStandInPlan.chromeCuts`: each picture leaves them out.
    func applyCuts(_ cuts: [CGWindowID: [ChromeCut]]) {
        mainThreadOnly()
        for (id, entry) in entries {
            let mine = cuts[id] ?? []
            entry.cuts = mine
            guard let layer = entry.view.layer else { continue }
            ChromeCutMask.apply(to: layer, size: entry.view.bounds.size, topLeftCG: entry.floater.frame.origin,
                                cuts: mine, cornerRadius: WindowCornerRadius.global,
                                scale: entry.panel.backingScaleFactor)
            entry.panel.invalidateShadow()
        }
    }

    /// Put `id`'s panel just below `windowNumber` (its outline), or in
    /// front of the floating level without one. Called back to front.
    func orderPanel(_ id: CGWindowID, below windowNumber: Int?) {
        mainThreadOnly()
        guard let entry = entries[id] else { return }
        if let windowNumber {
            entry.panel.order(.below, relativeTo: windowNumber)
        } else {
            entry.panel.orderFrontRegardless()
        }
    }

    /// The window numbers the mouse tap raised that are not up here. The
    /// tap set the window server's alpha behind AppKit's back.
    func panelsDown(among windowNumbers: [Int]) -> [Int] {
        let up = Set(entries.values.filter(\.shown).map(\.panel.windowNumber))
        return windowNumbers.filter { !up.contains($0) }
    }

    // MARK: - panels

    private func hasLook(_ entry: Entry) -> Bool {
        mode == .card || entry.view.hasPicture
    }

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
        // ordered in once, invisible; shown and hidden with its alpha
        place(entry)
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        if let outline = outlineWindowNumber(id) { panel.order(.below, relativeTo: outline) }
        return entry
    }

    private func show(_ entry: Entry, trigger: String) {
        place(entry)
        if !entry.shown { entry.floater.title = readTitle(entry.floater.id) }
        entry.view.showCard(icon: NSRunningApplication(processIdentifier: entry.floater.pid)?.icon,
                            title: entry.floater.title, tint: outlineColor(),
                            cornerRadius: WindowCornerRadius.resolve(for: entry.floater.id))
        entry.view.setLive(mode == .live)
        guard !entry.shown else { return }
        entry.shown = true
        if let outline = outlineWindowNumber(entry.floater.id) {
            entry.panel.order(.below, relativeTo: outline)
        }
        entry.panel.ignoresMouseEvents = entry.passingThrough
        entry.panel.alphaValue = 1
        // on screen before the app that is about to raise gets its turn
        CATransaction.flush()
        hyprLog(.notice, .floating, "stand-in shown wid=\(entry.floater.id) trigger=\(trigger) "
                + "look=\(entry.view.showsLivePicture ? "live" : "card") frame=\(Self.describe(entry.floater.frame))")
        panelsChanged()
    }

    private func hide(_ entry: Entry, trigger: String) {
        entry.panel.alphaValue = 0
        entry.panel.ignoresMouseEvents = true
        entry.shown = false
        entry.heldUntil = nil
        hyprLog(.notice, .floating, "stand-in hidden wid=\(entry.floater.id) trigger=\(trigger)")
        panelsChanged()
    }

    private func destroy(_ entry: Entry, reason: String) {
        if entry.shown { hide(entry, trigger: reason) }
        if entry.stream != nil { stopStream(entry, reason: reason, keepPicture: false) }
        entry.panel.orderOut(nil)
        entries[entry.floater.id] = nil
    }

    private func place(_ entry: Entry) {
        let f = entry.floater.frame
        let rect = NSRect(x: f.minX, y: primaryScreenHeight() - f.maxY, width: f.width, height: f.height)
        if entry.panel.frame != rect { entry.panel.setFrame(rect, display: true) }
    }

    /// Down once the window list shows the real floater on top (or gone)
    /// `confirmReads` times in a row, one frame apart. A cover seen in
    /// between keeps it up: show, hide, show within a few frames can't happen.
    private func confirmThenHide(_ entry: Entry, trigger: String) {
        guard !entry.confirming else { return }
        entry.confirming = true
        let id = entry.floater.id
        let started = CFAbsoluteTimeGetCurrent()
        var reads = 0
        var polls = 0
        func step() {
            guard let entry = entries[id], entry.confirming else { return }
            guard entry.shown, handOff?.id != id else { entry.confirming = false; return }
            polls += 1
            let state = coverState(id)
            if state == .covered {
                reads = 0
            } else {
                reads += 1
            }
            if reads >= Self.confirmReads {
                entry.confirming = false
                let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
                hide(entry, trigger: (state == .gone ? "gone" : "confirmed-on-top") + " after \(trigger), \(ms) ms")
                chromeChanged()
                return
            }
            guard polls < Self.confirmLimit else {
                // stays up; the next refresh asks again
                entry.confirming = false
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.poll) { step() }
        }
        step()
    }

    // MARK: - hand-off

    /// A touch on the panel: focus the real floater, wait for the window
    /// list to show it on top, take the panel down, then pass a click on at
    /// the same point.
    private func touched(_ id: CGWindowID, touch: Touch, at point: CGPoint) {
        guard handOff == nil, let entry = entries[id], entry.shown else { return }
        if FloaterStandInPlan.isCut(point, by: entry.cuts, cornerRadius: WindowCornerRadius.global) {
            passThrough(entry, touch: touch, at: point)
            return
        }
        let started = CFAbsoluteTimeGetCurrent()
        handOff = (id, started)
        entry.confirming = false
        hyprLog(.notice, .floating, "stand-in hand-off wid=\(id) touch=\(touch.rawValue) at=(\(Int(point.x)),\(Int(point.y)))")
        guard focusFloater(id) else {
            handOff = nil
            hide(entry, trigger: "hand-off: floater gone")
            return
        }
        pollHandOff(id, touch: touch, at: point, started: started, reads: 0)
    }

    private func pollHandOff(_ id: CGWindowID, touch: Touch, at point: CGPoint, started: CFAbsoluteTime,
                             reads: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.poll) { [weak self] in
            guard let self, self.handOff?.id == id else { return }
            let elapsed = CFAbsoluteTimeGetCurrent() - started
            let state = self.coverState(id)
            let onTopReads = state == .covered ? 0 : reads + 1
            guard onTopReads >= Self.confirmReads || elapsed >= Self.handOffTimeout else {
                self.pollHandOff(id, touch: touch, at: point, started: started, reads: onTopReads)
                return
            }
            self.handOff = nil
            let covered = state == .covered
            let ms = Int(elapsed * 1000)
            // still covered, a click would land on the tile: the panel stays
            guard !covered else {
                hyprLog(.notice, .floating, "stand-in hand-off wid=\(id) gave up after \(ms) ms, still covered; "
                        + "touch not passed on")
                self.handOffFinished()
                return
            }
            if let entry = self.entries[id], entry.shown {
                self.hide(entry, trigger: "confirmed-on-top after hand-off, \(ms) ms")
                self.chromeChanged()
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

    /// A touch on a part of the panel cut for a window in front: that
    /// window is real and on top there, so the touch is its. The panel
    /// lets the mouse through and the click is posted again at the point;
    /// it takes the mouse back once the button is up.
    private func passThrough(_ entry: Entry, touch: Touch, at point: CGPoint) {
        guard !entry.passingThrough else { return }
        entry.passingThrough = true
        entry.panel.ignoresMouseEvents = true
        let id = entry.floater.id
        hyprLog(.notice, .floating, "stand-in wid=\(id) touch=\(touch.rawValue) on a cut part, passed through "
                + "at=(\(Int(point.x)),\(Int(point.y)))")
        if touch == .click {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.passOnDelay) {
                Self.postClick(at: point, held: NSEvent.pressedMouseButtons & 1 != 0)
            }
        }
        func restore() {
            guard let entry = entries[id] else { return }
            guard NSEvent.pressedMouseButtons == 0 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { restore() }
                return
            }
            entry.passingThrough = false
            entry.panel.ignoresMouseEvents = !entry.shown
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { restore() }
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
            let first = !entry.view.hasPicture
            entry.view.setSurface(surface)
            entry.view.setLive(self.mode == .live)
            if first { self.panelsChanged() }
        }
        stream.onStop = { [weak entry, weak stream] why in
            guard let entry, let stream, entry.stream === stream else { return }
            entry.stream = nil
            entry.streamRetryAfter = CFAbsoluteTimeGetCurrent() + 5
            entry.view.freezePicture()
            hyprLog(.notice, .floating, "stand-in stream stopped wid=\(id) reason=\(why)")
        }
        entry.stream = stream
        stream.start(size: entry.floater.frame.size, scale: scale(for: entry.floater.frame))
    }

    /// The stream stops; its last picture stays, copied, for the next show.
    private func stopStream(_ entry: Entry, reason: String, keepPicture: Bool = true) {
        guard let stream = entry.stream else { return }
        entry.stream = nil
        if keepPicture { entry.view.freezePicture() }
        stream.stop()
        hyprLog(.notice, .floating, "stand-in stream stopped wid=\(entry.floater.id) reason=\(reason)"
                + (keepPicture && entry.view.hasPicture ? ", picture kept" : ""))
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
        // set outright when shown: a clear window passes clicks through
        // wherever its backing is clear, and the picture is a layer
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
    // the last picture, copied: the stream reuses its surfaces
    private var frozen: CGImage?
    private(set) var showsLivePicture = false
    private var liveState: Bool?

    var hasPicture: Bool { surface != nil || frozen != nil }

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
        // a picture of the old size keeps its shape until the new size comes
        liveLayer.contentsGravity = .resizeAspect
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

    func setSurface(_ surface: IOSurface) {
        self.surface = surface
        frozen = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveLayer.contents = surface
        CATransaction.commit()
    }

    /// The stream is stopping: keep a copy of its last picture.
    func freezePicture() {
        guard let surface else { return }
        self.surface = nil
        frozen = Self.image(from: surface)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveLayer.contents = frozen
        CATransaction.commit()
        if frozen == nil { setLive(false) }
    }

    /// The picture shows once there is one; until then the card does.
    func setLive(_ live: Bool) {
        let showLive = live && hasPicture
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

    /// A copy of a BGRA surface the stream may write into again.
    private static func image(from surface: IOSurface) -> CGImage? {
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let width = surface.width, height = surface.height, bytesPerRow = surface.bytesPerRow
        guard width > 0, height > 0 else { return nil }
        let data = Data(bytes: surface.baseAddress, count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: space, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
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
