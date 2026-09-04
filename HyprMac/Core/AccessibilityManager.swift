// AX bridge: enumerates visible windows across every running app, returns
// the focused window, and exposes `windowInDirection` for swap/focus
// pickers. Windows from this layer come back as `HyprWindow` values
// keyed by stable `CGWindowID`.

import Cocoa

/// A window visible to the app-activation workflow, including windows that
/// are currently minimized or belong to a hidden application.
struct ApplicationWindowCandidate: Equatable {
    let windowID: CGWindowID
    let isMinimized: Bool
    let isMain: Bool
    let isFocused: Bool
}

/// AX distinguishes a confirmed empty window list from an unreadable one.
/// The activation workflow must never reopen an app merely because AX was
/// temporarily unavailable; doing so can create duplicate documents.
enum ApplicationWindowInventory: Equatable {
    // Includes non-standard/modal windows: a filtered list is not evidence
    // that the app has no window and should receive another reopen event.
    case available(windows: [ApplicationWindowCandidate], hasUnaddressableWindows: Bool)
    case unavailable
}

/// Wrapper around the macOS Accessibility (AX) API.
///
/// Owns the AX↔CG mapping path: each visible window is enumerated via
/// AX, paired with its `CGWindowID` through the `_AXUIElementGetWindow`
/// private SPI (same approach as yabai/AeroSpace/Amethyst), and
/// returned as a `HyprWindow`. A short-lived cache fronts
/// `CGWindowListCopyWindowInfo` so back-to-back calls in the same cycle
/// do not duplicate the system call.
///
/// Threading: main-thread only.
class AccessibilityManager {

    /// `true` when the running process has been granted Accessibility
    /// permission in System Settings → Privacy → Accessibility.
    static func isAccessibilityEnabled() -> Bool {
        AXIsProcessTrusted()
    }

    /// Show the macOS Accessibility prompt that takes the user to
    /// System Settings to grant the app permission.
    static func promptForAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    // snapshot of all on-screen CGWindows: pid -> [(wid, bounds)]
    private struct CGWindowInfo {
        let windowID: CGWindowID
        let bounds: CGRect
        let alpha: CGFloat
        let name: String?
    }

    // short-lived cache for CGWindowListCopyWindowInfo — avoids duplicate
    // system calls when getAllWindows() and getFocusedWindow() run in the same cycle
    private var cgWindowCacheTime: CFAbsoluteTime = 0
    private var cgWindowCacheData: [pid_t: [CGWindowInfo]] = [:]
    private let cgWindowCacheTTL: CFAbsoluteTime = 0.05  // 50ms

    // consecutive getAllWindows cycles where an app's AX reads dropped
    // windows that CG says are on screen. diag for the retile-flap
    // investigation — logs fire on outage start/end, not per cycle.
    private var axListFailures: [pid_t: Int] = [:]
    private var axFrameDrops: [pid_t: Int] = [:]

    /// Look up a window in the last discovery snapshot by `CGWindowID`.
    /// Wired by `WindowManager` to `stateCache.cachedWindows[id]`. Lets
    /// `getFocusedWindow` skip a full AX walk when the focused window was
    /// already matched on a prior pass. `nil` (unwired) forces the walk.
    var cachedWindowLookup: ((CGWindowID) -> HyprWindow?)?

    private func cgWindowsByPID() -> [pid_t: [CGWindowInfo]] {
        let now = CFAbsoluteTimeGetCurrent()
        if now - cgWindowCacheTime < cgWindowCacheTTL && !cgWindowCacheData.isEmpty {
            return cgWindowCacheData
        }
        var result: [pid_t: [CGWindowInfo]] = [:]
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return result
        }
        for info in windowList {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let wid = info[kCGWindowNumber as String] as? CGWindowID,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }

            let alpha = info[kCGWindowAlpha as String] as? CGFloat ?? 1.0
            let name = info[kCGWindowName as String] as? String

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0
            )
            result[pid, default: []].append(CGWindowInfo(windowID: wid, bounds: bounds, alpha: alpha, name: name))
        }
        cgWindowCacheData = result
        cgWindowCacheTime = now
        return result
    }

    // get AX position+size for an element
    private func axFrame(for element: AXUIElement) -> CGRect? {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let posVal = posValue, let sizeVal = sizeValue else {
            return nil
        }
        var pos = CGPoint.zero
        var size = CGSize.zero
        // AXValue is a CF type — as? always succeeds, so cast directly after nil check
        AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    // ask the AX system directly for the CGWindowID backing this element.
    // private SPI — same one yabai/AeroSpace/Amethyst use. eliminates the
    // ambiguity of position-based matching (which silently swapped same-app
    // windows when their AX positions were stale or coincidentally identical).
    private func windowID(for element: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        let err = _AXUIElementGetWindow(element, &wid)
        return err == .success && wid != 0 ? wid : nil
    }

    /// Enumerate standard windows for one app without requiring them to be
    /// on-screen. This is intentionally separate from `getAllWindows()`: the
    /// latter is the visible-desktop discovery source, while activation also
    /// needs to reason about Cmd-H and minimized windows.
    func activationWindowInventory(for pid: pid_t) -> ApplicationWindowInventory {
        guard AXIsProcessTrusted() else { return .unavailable }

        let appElement = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &value
        ) == .success, let windows = value as? [AXUIElement] else {
            return .unavailable
        }

        var candidates: [ApplicationWindowCandidate] = []
        var hasUnaddressableWindows = false
        for window in windows {
            guard isStandardActivationWindow(window) else {
                hasUnaddressableWindows = true
                continue
            }
            guard let id = windowID(for: window) else {
                // A real standard window exists, but cannot safely be routed.
                // Preserve that distinction from a confirmed empty list.
                hasUnaddressableWindows = true
                continue
            }
            candidates.append(ApplicationWindowCandidate(
                windowID: id,
                isMinimized: boolAttribute(kAXMinimizedAttribute, of: window),
                isMain: boolAttribute(kAXMainAttribute, of: window),
                isFocused: boolAttribute(kAXFocusedAttribute, of: window)
            ))
        }

        candidates.sort { $0.windowID < $1.windowID }
        return .available(windows: candidates, hasUnaddressableWindows: hasUnaddressableWindows)
    }

    /// Resolve selected activation candidates back to `HyprWindow` values.
    /// Unlike `getAllWindows()`, this works while the app is hidden or its
    /// windows are minimized, which lets the normal discovery/tiling pipeline
    /// prepare them before a controlled reveal.
    func activationWindows(for pid: pid_t,
                           matching ids: Set<CGWindowID>) -> [HyprWindow] {
        guard AXIsProcessTrusted(), !ids.isEmpty else { return [] }

        let appElement = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &value
        ) == .success, let windows = value as? [AXUIElement] else {
            return []
        }

        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        var result: [HyprWindow] = []
        for element in windows where isStandardActivationWindow(element) {
            guard let id = windowID(for: element), ids.contains(id) else { continue }
            let window = HyprWindow(element: element, windowID: id, ownerPID: pid)
            window.cachedFrame = axFrame(for: element)
            window.seedMinimumSize(bundleIdentifier: bundleID)
            result.append(window)
        }
        return result.sorted { $0.windowID < $1.windowID }
    }

    /// Resolve one selected window after reveal without walking every app's
    /// AX tree on each retry. Keep normal discovery's on-screen/alpha checks;
    /// a window on a different native Space is not ready for this route.
    func visibleActivationWindow(for pid: pid_t, windowID: CGWindowID) -> HyprWindow? {
        guard let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular, !app.isHidden, !app.isTerminated,
              cgWindowsByPID()[pid]?.contains(where: {
                  $0.windowID == windowID && $0.alpha > 0.01
              }) == true,
              let window = activationWindows(for: pid, matching: [windowID]).first,
              window.cachedFrame != nil,
              !boolAttribute(kAXMinimizedAttribute, of: window.element) else { return nil }
        return window
    }

    /// Whether both geometry attributes can be set for a window. A hidden
    /// pre-layout is attempted only when AX explicitly confirms this.
    func canSetFrame(of window: HyprWindow) -> Bool {
        var positionSettable = DarwinBoolean(false)
        var sizeSettable = DarwinBoolean(false)
        let positionResult = AXUIElementIsAttributeSettable(
            window.element, kAXPositionAttribute as CFString, &positionSettable
        )
        let sizeResult = AXUIElementIsAttributeSettable(
            window.element, kAXSizeAttribute as CFString, &sizeSettable
        )
        return positionResult == .success && positionSettable.boolValue
            && sizeResult == .success && sizeSettable.boolValue
    }

    private func boolAttribute(_ name: String, of element: AXUIElement) -> Bool {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return false
        }
        return (value as? NSNumber)?.boolValue ?? false
    }

    private func isStandardActivationWindow(_ element: AXUIElement) -> Bool {
        var roleValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &roleValue
        ) == .success, roleValue as? String == kAXWindowRole as String else {
            return false
        }

        var subroleValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
        if let subrole = subroleValue as? String,
           subrole != kAXStandardWindowSubrole as String {
            return false
        }

        var modalValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXModalAttribute as CFString, &modalValue)
        return !((modalValue as? NSNumber)?.boolValue ?? false)
    }

    /// Snapshot every visible normal window across all running apps.
    ///
    /// Walks every regular-activation app's `kAXWindowsAttribute`,
    /// filters out minimized / non-standard / modal windows, then maps
    /// each AX element to a `CGWindowID` by calling
    /// `_AXUIElementGetWindow` first and falling back to greedy
    /// nearest-position matching only when the SPI fails. The fallback
    /// is defensive — it should not fire in practice.
    ///
    /// Returns an empty array when AX permission has not been granted.
    /// Whether `windowID` is still alive in `pid`'s AX window list as a
    /// minimized window, or the app itself is hidden (Cmd-H). Used by the
    /// discovery gone path to distinguish user-hidden windows — which must
    /// keep their workspace on return — from closed windows whose id a
    /// later reopen may recycle. Returns nil when the AX list can't be
    /// read (caller treats unknown as user-hidden, the conservative side).
    func isWindowMinimizedOrAppHidden(windowID target: CGWindowID, pid: pid_t) -> Bool? {
        if NSRunningApplication(processIdentifier: pid)?.isHidden == true { return true }
        let appRef = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let axWindows = value as? [AXUIElement] else { return nil }
        for axWin in axWindows {
            guard windowID(for: axWin) == target else { continue }
            var minimized: AnyObject?
            AXUIElementCopyAttributeValue(axWin, kAXMinimizedAttribute as CFString, &minimized)
            return (minimized as? Bool) ?? false
        }
        // enumerated fine and the id is gone — genuinely closed
        return false
    }

    func getAllWindows() -> [HyprWindow] {
        guard AXIsProcessTrusted() else { return [] }

        let cgWindows = cgWindowsByPID()
        var windows: [HyprWindow] = []
        var usedIDs: Set<CGWindowID> = []

        // apps to never tile
        let excludedBundleIDs: Set<String> = [
            "com.apple.quicklook.QuickLookUIService",
            "com.apple.QuickLookDaemon",
        ]

        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular &&
            !excludedBundleIDs.contains($0.bundleIdentifier ?? "")
        }

        for app in apps {
            let pid = app.processIdentifier
            let candidates = cgWindows[pid] ?? []
            let appRef = AXUIElementCreateApplication(pid)
            var value: AnyObject?
            let result = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &value)
            guard result == .success, let axWindows = value as? [AXUIElement] else {
                // a busy app (main thread stalled) fails this read wholesale
                // and every one of its windows drops from the snapshot for
                // the cycle — discovery reads them as gone, the sibling tile
                // expands full-screen, and the next cycle flaps them back.
                // log the outage edges only, not every 1 Hz cycle.
                if candidates.contains(where: { $0.alpha > 0.01 }) {
                    let n = (axListFailures[pid] ?? 0) + 1
                    axListFailures[pid] = n
                    if n == 1 {
                        hyprLog(.notice, .discovery, "AX window-list read FAILED for \(app.bundleIdentifier ?? "pid \(pid)") (err \(result.rawValue)) — \(candidates.count) on-screen window(s) drop from this snapshot")
                    }
                }
                continue
            }
            if let n = axListFailures.removeValue(forKey: pid) {
                hyprLog(.notice, .discovery, "AX window-list read recovered for \(app.bundleIdentifier ?? "pid \(pid)") after \(n) failed cycle(s)")
            }

            guard !candidates.isEmpty else { continue }

            // collect all real AX windows for this app. skip minimized, modal,
            // and non-standard subroles — those are sheets/dialogs/quick-look
            // hosts that shouldn't enter tiling or claim a CG window ID.
            var axEntries: [(element: AXUIElement, frame: CGRect)] = []
            var frameDropCount = 0
            for axWin in axWindows {
                var minimized: AnyObject?
                AXUIElementCopyAttributeValue(axWin, kAXMinimizedAttribute as CFString, &minimized)
                if let min = minimized as? Bool, min { continue }

                var role: AnyObject?
                AXUIElementCopyAttributeValue(axWin, kAXRoleAttribute as CFString, &role)
                guard let roleStr = role as? String, roleStr == kAXWindowRole as String else { continue }

                var subrole: AnyObject?
                AXUIElementCopyAttributeValue(axWin, kAXSubroleAttribute as CFString, &subrole)
                let subroleStr = subrole as? String
                let subroleNonStandard = subroleStr != nil && subroleStr != (kAXStandardWindowSubrole as String)

                var modalValue: AnyObject?
                AXUIElementCopyAttributeValue(axWin, kAXModalAttribute as CFString, &modalValue)
                let isModal = (modalValue as? Bool) ?? false

                if subroleNonStandard || isModal { continue }

                guard let frame = axFrame(for: axWin) else {
                    frameDropCount += 1
                    continue
                }
                axEntries.append((element: axWin, frame: frame))
            }

            // same flap risk as a failed window-list read, but per-window:
            // a standard window whose position/size read fails silently
            // vanishes from the snapshot. edge-logged like above.
            if frameDropCount > 0 {
                let n = (axFrameDrops[pid] ?? 0) + 1
                axFrameDrops[pid] = n
                if n == 1 {
                    hyprLog(.notice, .discovery, "AX frame read FAILED for \(frameDropCount) window(s) of \(app.bundleIdentifier ?? "pid \(pid)") — dropped from this snapshot")
                }
            } else if let n = axFrameDrops.removeValue(forKey: pid) {
                hyprLog(.notice, .discovery, "AX frame reads recovered for \(app.bundleIdentifier ?? "pid \(pid)") after \(n) affected cycle(s)")
            }

            let visibleCandidates = candidates.filter { $0.alpha > 0.01 }
            let validCGIDs = Set(visibleCandidates.map { $0.windowID })

            // primary path: ask AX directly for each element's CGWindowID
            var unmatchedAX: [(element: AXUIElement, frame: CGRect)] = []
            for entry in axEntries {
                guard let wid = windowID(for: entry.element),
                      validCGIDs.contains(wid),
                      !usedIDs.contains(wid) else {
                    unmatchedAX.append(entry)
                    continue
                }
                usedIDs.insert(wid)
                let hw = HyprWindow(element: entry.element, windowID: wid, ownerPID: pid)
                hw.cachedFrame = entry.frame
                hw.seedMinimumSize(bundleIdentifier: app.bundleIdentifier)
                windows.append(hw)
            }

            // fallback path: SPI failed for some element (shouldn't normally
            // happen — kept so a future AX/SDK change doesn't blank everything).
            // greedy nearest-position match against unused candidates.
            guard !unmatchedAX.isEmpty else { continue }
            var availableCG = validCGIDs.subtracting(usedIDs)
            for entry in unmatchedAX {
                var bestWID: CGWindowID?
                var bestDist = CGFloat.infinity
                for cg in visibleCandidates where availableCG.contains(cg.windowID) {
                    let dist = abs(entry.frame.origin.x - cg.bounds.origin.x)
                             + abs(entry.frame.origin.y - cg.bounds.origin.y)
                             + abs(entry.frame.width - cg.bounds.width)
                             + abs(entry.frame.height - cg.bounds.height)
                    if dist < bestDist { bestDist = dist; bestWID = cg.windowID }
                }
                if let wid = bestWID {
                    availableCG.remove(wid)
                    usedIDs.insert(wid)
                    let hw = HyprWindow(element: entry.element, windowID: wid, ownerPID: pid)
                    hw.cachedFrame = entry.frame
                    hw.seedMinimumSize(bundleIdentifier: app.bundleIdentifier)
                    windows.append(hw)
                }
            }
        }
        return windows
    }

    /// Resolve the AX-focused window of the frontmost app to a
    /// `HyprWindow`.
    ///
    /// Two paths:
    /// - **Fast path:** ask AX for the focused element's `CGWindowID`
    ///   (`_AXUIElementGetWindow`) and look it up in the last discovery
    ///   snapshot via `cachedWindowLookup`. The snapshot came from a prior
    ///   `getAllWindows` matching pass, so the result is identical to the
    ///   full walk — without the ~100+ cross-process AX round-trips.
    /// - **Fallback:** on a miss (the focused window is newer than the last
    ///   discovery, or the SPI/lookup is unavailable) run the full
    ///   `getAllWindows` walk and match by AX element identity. This is the
    ///   path that avoids the sibling-window misresolution multi-window apps
    ///   (Finder, Teams) hit when matched by position.
    func getFocusedWindow() -> HyprWindow? {
        guard AXIsProcessTrusted() else { return nil }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontApp.processIdentifier
        let appRef = AXUIElementCreateApplication(pid)

        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &value)
        guard result == .success,
              let val = value,
              CFGetTypeID(val) == AXUIElementGetTypeID() else { return nil }
        let focusedAX = val as! AXUIElement

        // fast path: resolve the CGWindowID directly and hit the snapshot.
        if let wid = windowID(for: focusedAX), let cached = cachedWindowLookup?(wid) {
            return cached
        }

        // fallback: full walk, matched by AX element identity — same matching
        // pass as getAllWindows so sibling windows don't misresolve.
        return getAllWindows().first { CFEqual($0.element, focusedAX) }
    }

    /// Find the nearest window in `direction` relative to `window`.
    ///
    /// Edge-based scoring: measures the axial gap between the source's
    /// leading edge and each candidate's trailing edge, then
    /// perpendicular overlap. Center-based scoring produced
    /// non-deterministic ties when the source spanned multiple
    /// candidates — for example, a full-width window going down with
    /// two half-width windows directly below has identical center
    /// distance to both, and AX iteration chose arbitrarily.
    ///
    /// Ranking, lexicographic:
    /// 1. Smaller edge-to-edge axial gap (closer along the movement
    ///    axis).
    /// 2. `containsRay` first — candidate whose perpendicular span
    ///    contains the source's center coord on the perpendicular axis.
    /// 3. Larger perpendicular overlap.
    /// 4. Stable reading order: vertical moves pick lowest `minX`,
    ///    horizontal moves pick lowest `minY`. Used only when neither
    ///    candidate uniquely contains the ray; guarantees the same
    ///    arrow always picks the same target.
    func windowInDirection(
        _ direction: Direction,
        from window: HyprWindow,
        among windows: [HyprWindow],
        frameFor: (HyprWindow) -> CGRect? = { $0.frame }
    ) -> HyprWindow? {
        guard let sourceFrame = frameFor(window) else { return nil }

        struct Scored {
            let window: HyprWindow
            let edgeGap: CGFloat
            let perpOverlap: CGFloat
            let containsRay: Bool
            let perpReadingOrder: CGFloat
        }

        var candidates: [Scored] = []

        for candidate in windows where candidate != window {
            guard let cf = frameFor(candidate) else { continue }

            let edgeGap: CGFloat
            let perpOverlap: CGFloat
            let containsRay: Bool
            let perpReadingOrder: CGFloat

            // CG coords throughout: y grows downward (minY = top edge).
            switch direction {
            case .left:
                guard cf.maxX <= sourceFrame.minX + 1 else { continue }
                edgeGap = sourceFrame.minX - cf.maxX
                perpOverlap = max(0, min(cf.maxY, sourceFrame.maxY) - max(cf.minY, sourceFrame.minY))
                let centerY = sourceFrame.midY
                containsRay = cf.minY <= centerY && centerY <= cf.maxY
                perpReadingOrder = cf.minY
            case .right:
                guard cf.minX >= sourceFrame.maxX - 1 else { continue }
                edgeGap = cf.minX - sourceFrame.maxX
                perpOverlap = max(0, min(cf.maxY, sourceFrame.maxY) - max(cf.minY, sourceFrame.minY))
                let centerY = sourceFrame.midY
                containsRay = cf.minY <= centerY && centerY <= cf.maxY
                perpReadingOrder = cf.minY
            case .up:
                guard cf.maxY <= sourceFrame.minY + 1 else { continue }
                edgeGap = sourceFrame.minY - cf.maxY
                perpOverlap = max(0, min(cf.maxX, sourceFrame.maxX) - max(cf.minX, sourceFrame.minX))
                let centerX = sourceFrame.midX
                containsRay = cf.minX <= centerX && centerX <= cf.maxX
                perpReadingOrder = cf.minX
            case .down:
                guard cf.minY >= sourceFrame.maxY - 1 else { continue }
                edgeGap = cf.minY - sourceFrame.maxY
                perpOverlap = max(0, min(cf.maxX, sourceFrame.maxX) - max(cf.minX, sourceFrame.minX))
                let centerX = sourceFrame.midX
                containsRay = cf.minX <= centerX && centerX <= cf.maxX
                perpReadingOrder = cf.minX
            }

            // require some perpendicular alignment — either rect overlap or
            // the source's center ray hits the candidate's perp span.
            // filters diagonal-only neighbors that aren't "in line."
            guard perpOverlap > 0 || containsRay else { continue }

            candidates.append(Scored(
                window: candidate,
                edgeGap: edgeGap,
                perpOverlap: perpOverlap,
                containsRay: containsRay,
                perpReadingOrder: perpReadingOrder
            ))
        }

        guard !candidates.isEmpty else { return nil }

        // 0.5px slack on float comparisons absorbs sub-pixel rounding so
        // visually-equivalent layouts produce the same picker output.
        candidates.sort { a, b in
            if abs(a.edgeGap - b.edgeGap) > 0.5 {
                return a.edgeGap < b.edgeGap
            }
            if a.containsRay != b.containsRay {
                return a.containsRay && !b.containsRay
            }
            if abs(a.perpOverlap - b.perpOverlap) > 0.5 {
                return a.perpOverlap > b.perpOverlap
            }
            return a.perpReadingOrder < b.perpReadingOrder
        }

        return candidates.first?.window
    }
}
