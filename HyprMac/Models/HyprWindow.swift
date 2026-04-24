import Cocoa

// private SkyLight APIs for focus-without-raise (used by yabai + Amethyst)
// activates a process without reordering windows
@_silgen_name("_SLPSSetFrontProcessWithOptions") @discardableResult
private func _SLPSSetFrontProcessWithOptions(_ psn: inout ProcessSerialNumber, _ wid: UInt32, _ mode: UInt32) -> CGError

// synthesizes keyboard focus events to a specific window
@_silgen_name("SLPSPostEventRecordTo") @discardableResult
private func SLPSPostEventRecordTo(_ psn: inout ProcessSerialNumber, _ bytes: inout UInt8) -> CGError

// get PSN from PID (deprecated but functional)
@_silgen_name("GetProcessForPID") @discardableResult
private func GetProcessForPID(_ pid: pid_t, _ psn: inout ProcessSerialNumber) -> OSStatus

private let kCPSUserGenerated: UInt32 = 0x200

class HyprWindow: Equatable, Hashable {
    let element: AXUIElement
    let windowID: CGWindowID
    let ownerPID: pid_t
    var isFloating: Bool = false
    // cached from getAllWindows() — avoids redundant AX reads in updatePositionCache.
    // cleared on setFrame/setFrameWithReadback so stale values aren't used.
    var cachedFrame: CGRect?
    // known lower bound for app resizing. seeded from AXMinimumSize/heuristics
    // when available, then refined when layout readback witnesses a refusal.
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

    // resize-move-resize pattern (from yabai) — handles macOS screen-bound constraints.
    // macOS clamps resize based on the current screen, so we must:
    // 1. resize to target (may be clamped by source screen)
    // 2. move to target position (now on destination screen)
    // 3. resize again (now unclamped by destination screen bounds)
    // crossMonitor=false skips step 3 for same-screen tiling (saves 1 AX call per window)
    func setFrame(_ rect: CGRect, crossMonitor: Bool = true) {
        cachedFrame = nil
        size = rect.size
        position = rect.origin
        if crossMonitor { size = rect.size }
    }

    // set frame and read back actual size — returns what the app actually accepted.
    // apps with minimum sizes will refuse to shrink, and the readback catches that.
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

    // focus this window without changing z-order (yabai's focus_without_raise).
    // uses _SLPSSetFrontProcessWithOptions to activate the process without
    // reordering windows, then SLPSPostEventRecordTo to synthesize keyboard
    // focus events. floating windows stay exactly where they are.
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
