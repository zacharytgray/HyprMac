// One window's identity and AX-driven controls. Wraps an
// `AXUIElement` and its stable `CGWindowID`; everything else
// (`frame`, `position`, `size`, `focus`, `setFrame`) is built on AX
// gets/sets. Also holds the SkyLight private-API hooks used for
// focus-without-raise.

import Cocoa

// Private SkyLight APIs. `_SLPSSetFrontProcessWithOptions` activates a
// process without reordering its windows; `SLPSPostEventRecordTo`
// synthesizes keyboard focus events. Same approach yabai and
// AeroSpace use.
@_silgen_name("_SLPSSetFrontProcessWithOptions") @discardableResult
private func _SLPSSetFrontProcessWithOptions(_ psn: inout ProcessSerialNumber, _ wid: UInt32, _ mode: UInt32) -> CGError

@_silgen_name("SLPSPostEventRecordTo") @discardableResult
private func SLPSPostEventRecordTo(_ psn: inout ProcessSerialNumber, _ bytes: inout UInt8) -> CGError

@_silgen_name("GetProcessForPID") @discardableResult
private func GetProcessForPID(_ pid: pid_t, _ psn: inout ProcessSerialNumber) -> OSStatus

private let kCPSUserGenerated: UInt32 = 0x200

/// One window managed by HyprMac, identified by its stable
/// `CGWindowID` and backed by an `AXUIElement`.
///
/// Owns the resize-move-resize pattern (`setFrame` /
/// `setFrameWithReadback`), the focus operations (`focus`,
/// `focusWithoutRaise`), and the per-window `observedMinSize` cache
/// `MinSizeMemory` reads and writes.
///
/// Threading: main-thread only. AX calls block briefly while the OS
/// round-trips to the owning app.
class HyprWindow: Equatable, Hashable {
    let element: AXUIElement
    let windowID: CGWindowID
    let ownerPID: pid_t

    /// `true` when the window is excluded from tiling. Toggled by the
    /// floating controller and by auto-float predicates.
    var isFloating: Bool = false

    /// Most recent AX frame read by `getAllWindows`. Lets
    /// `updatePositionCache` skip redundant AX reads. Cleared by
    /// `setFrame` / `setFrameWithReadback` so stale values are not
    /// reused.
    var cachedFrame: CGRect?

    /// Known lower bound on the window's resizable size. Seeded from
    /// `AXMinimumSize` (or a per-bundle-id heuristic when AX does not
    /// expose one), then refined whenever readback witnesses an
    /// app's refusal to shrink past a tighter bound.
    var observedMinSize: CGSize?

    init(element: AXUIElement, windowID: CGWindowID, ownerPID: pid_t) {
        self.element = element
        self.windowID = windowID
        self.ownerPID = ownerPID
    }

    var title: String? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        return value as? String
    }

    /// Set `observedMinSize` from `AXMinimumSize` (or per-bundle-id
    /// fallback) when AX exposes a usable value. No-op when neither
    /// source produces one — `MinSizeMemory` will learn from readback
    /// later.
    func seedMinimumSize(bundleIdentifier: String?) {
        if let axSize = axMinimumSize() {
            observedMinSize = axSize
            return
        }

        if let bundleIdentifier,
           let heuristic = Self.heuristicMinimumSizes[bundleIdentifier] {
            observedMinSize = heuristic
        }
    }

    private func axMinimumSize() -> CGSize? {
        for attribute in ["AXMinimumSize", "AXMinSize"] {
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                  let value,
                  CFGetTypeID(value) == AXValueGetTypeID() else { continue }

            let axValue = value as! AXValue
            guard AXValueGetType(axValue) == .cgSize else { continue }

            var size = CGSize.zero
            guard AXValueGetValue(axValue, .cgSize, &size) else { continue }
            guard size.width > 0, size.height > 0,
                  size.width.isFinite, size.height.isFinite else { continue }
            return size
        }

        return nil
    }

    private static let heuristicMinimumSizes: [String: CGSize] = [
        "com.apple.Safari": CGSize(width: 420, height: 300),
        "com.google.Chrome": CGSize(width: 500, height: 340),
        "com.apple.finder": CGSize(width: 420, height: 300),
        "com.apple.Terminal": CGSize(width: 400, height: 260),
        "com.anthropic.claudefordesktop": CGSize(width: 600, height: 420),
        "com.apple.MobileSMS": CGSize(width: 520, height: 360),
        "com.apple.FaceTime": CGSize(width: 620, height: 460),
        "com.spotify.client": CGSize(width: 640, height: 420),
        "com.tinyspeck.slackmacgap": CGSize(width: 560, height: 380),
        "com.apple.dt.Xcode": CGSize(width: 700, height: 450),
    ]

    var frame: CGRect? {
        guard let pos = position, let sz = size else { return nil }
        return CGRect(origin: pos, size: sz)
    }

    var position: CGPoint? {
        get {
            var value: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value)
            guard let value else { return nil }
            var point = CGPoint.zero
            // AXValue is a CF type — as? always succeeds, so cast directly after nil check
            AXValueGetValue(value as! AXValue, .cgPoint, &point)
            return point
        }
        set {
            guard var point = newValue,
                  let val = AXValueCreate(.cgPoint, &point) else { return }
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, val)
        }
    }

    var size: CGSize? {
        get {
            var value: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value)
            guard let value else { return nil }
            var size = CGSize.zero
            AXValueGetValue(value as! AXValue, .cgSize, &size)
            return size
        }
        set {
            guard var size = newValue,
                  let val = AXValueCreate(.cgSize, &size) else { return }
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, val)
        }
    }

    /// Apply `rect` to the window using the resize-move-resize
    /// pattern.
    ///
    /// macOS clamps resize against the current screen's bounds, so a
    /// naive set on a cross-monitor move ends up clamped at the source
    /// screen's edge. Three steps:
    /// 1. Resize to target (may be clamped by source screen).
    /// 2. Move to target position (now on destination screen).
    /// 3. Resize again (now unclamped by destination's bounds).
    ///
    /// Same-screen tile updates pass `crossMonitor: false` so step 3
    /// is skipped — one AX call saved per window per retile.
    func setFrame(_ rect: CGRect, crossMonitor: Bool = true) {
        cachedFrame = nil
        withEnhancedUIDisabled {
            size = rect.size
            position = rect.origin
            if crossMonitor { size = rect.size }
        }
    }

    /// Move (without resizing) under the same EnhancedUI guard as
    /// `setFrame`. Used by the hide path so macOS doesn't animate or
    /// reposition the parked window — animations cause apps to snap
    /// to nearby monitors and become half-visible.
    func setPositionOnly(_ point: CGPoint) {
        cachedFrame = nil
        withEnhancedUIDisabled {
            position = point
        }
    }

    /// Disable `AXEnhancedUserInterface` on the owning app for the
    /// duration of `block`, then restore it. Matches yabai's
    /// `AX_ENHANCED_UI_WORKAROUND` and AeroSpace's `disableAnimations`.
    /// On Sequoia+ and especially Tahoe, leaving EnhancedUI on causes
    /// macOS to animate / clamp / reposition AX writes, making them
    /// arrive as something other than what we asked for.
    private func withEnhancedUIDisabled(_ block: () -> Void) {
        let appElement = AXUIElementCreateApplication(ownerPID)
        var prevValue: CFTypeRef?
        let prevRC = AXUIElementCopyAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, &prevValue)
        let wasEnhanced = (prevRC == .success && (prevValue as? Bool) == true)
        if wasEnhanced {
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }
        block()
        if wasEnhanced {
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    /// Apply `rect` and immediately read back the actual frame the
    /// app accepted.
    ///
    /// Apps with hard minimums refuse to shrink past their floor; the
    /// readback returns the actual size the OS settled on, which the
    /// tiling engine compares against the requested size to decide
    /// whether pass 2 is needed.
    @discardableResult
    func setFrameWithReadback(_ rect: CGRect) -> CGRect {
        setFrame(rect)

        // read back what actually happened
        let actualSize = size ?? rect.size
        let actualPos = position ?? rect.origin
        let actual = CGRect(origin: actualPos, size: actualSize)
        cachedFrame = actual
        return actual
    }

    var center: CGPoint? {
        guard let f = frame else { return nil }
        return CGPoint(x: f.midX, y: f.midY)
    }

    /// Bring this window forward and give it keyboard focus, raising
    /// it above the other windows of its app and activating the app
    /// itself if it is not already frontmost.
    ///
    /// Performs the AX raise + main + focused triple, then activates
    /// the app and re-asserts focus 50 ms later — single-pass focus
    /// is unreliable when the app was not already active because the
    /// AX writes can race the activation.
    func focus() {
        let app = NSRunningApplication(processIdentifier: ownerPID)
        let alreadyActive = app?.isActive ?? false

        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)

        if !alreadyActive {
            app?.activate()
            let el = element
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                AXUIElementPerformAction(el, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
        }
    }

    /// Give this window keyboard focus without changing z-order.
    ///
    /// Uses `_SLPSSetFrontProcessWithOptions` to activate the process
    /// in place, then `SLPSPostEventRecordTo` to synthesize the
    /// keyboard-focus events. Floating windows stay exactly where
    /// they are — used by FFM and `Hypr+Arrow` to avoid disturbing
    /// the user's z-stack.
    func focusWithoutRaise() {
        var psn = ProcessSerialNumber()
        guard GetProcessForPID(ownerPID, &psn) == noErr else { return }

        // activate process without reordering windows
        _SLPSSetFrontProcessWithOptions(&psn, UInt32(windowID), kCPSUserGenerated)

        // synthesize keyboard focus events to make this the key window
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xF8  // event type
        bytes[0x08] = 0x01  // key focus event
        bytes[0x8a] = 0x02  // window focus
        SLPSPostEventRecordTo(&psn, &bytes[0])

        bytes[0x08] = 0x02  // second focus event
        SLPSPostEventRecordTo(&psn, &bytes[0])
    }

    static func == (lhs: HyprWindow, rhs: HyprWindow) -> Bool {
        lhs.windowID == rhs.windowID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
    }
}
