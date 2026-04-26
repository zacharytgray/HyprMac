import Cocoa

class AccessibilityManager {

    static func isAccessibilityEnabled() -> Bool {
        AXIsProcessTrusted()
    }

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

    // get all visible windows across all apps. AX→CG mapping is deterministic
    // via _AXUIElementGetWindow (private SPI). position-based matching is kept
    // only as a defensive fallback — should never fire in practice.
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
            let appRef = AXUIElementCreateApplication(pid)
            var value: AnyObject?
            let result = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &value)
            guard result == .success, let axWindows = value as? [AXUIElement] else { continue }

            guard let candidates = cgWindows[pid], !candidates.isEmpty else { continue }

            // collect all real AX windows for this app. skip minimized, modal,
            // and non-standard subroles — those are sheets/dialogs/quick-look
            // hosts that shouldn't enter tiling or claim a CG window ID.
            var axEntries: [(element: AXUIElement, frame: CGRect)] = []
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

                guard let frame = axFrame(for: axWin) else { continue }
                axEntries.append((element: axWin, frame: frame))
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

    // get the currently focused window. routes through getAllWindows so the
    // AX→CG matching is identical — without this, multi-window apps (Finder,
    // Teams, etc.) could resolve the focused window to a *sibling* window's
    // CGWindowID, which then makes swap/move/etc. operate on the wrong window.
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

        // look up by AX element identity — same matching pass as getAllWindows
        return getAllWindows().first { CFEqual($0.element, focusedAX) }
    }

    // find the nearest window in a direction from a given window.
    //
    // edge-based scoring (not center-based): measures the gap between the
    // source's leading edge and each candidate's trailing edge along the
    // movement axis, then perpendicular overlap. center-based scoring
    // produced non-deterministic ties when the source spanned multiple
    // candidates (e.g., a full-width window going down with two
    // half-width windows directly below — both have identical center
    // distance, and AX ordering chose between them arbitrarily).
    //
    // ranking, lexicographic:
    //   1. smaller edge-to-edge axial gap (closer along the movement axis)
    //   2. containsRay first — candidate whose perpendicular span contains
    //      the source's center coord on the perpendicular axis (i.e., the
    //      candidate the user "naturally falls into" extending the source)
    //   3. larger perpendicular overlap
    //   4. stable reading order — for vertical moves choose lowest minX,
    //      for horizontal moves choose lowest minY. used only when source
    //      spans the perpendicular gap between two candidates so that
    //      neither uniquely contains the ray; ensures the same arrow
    //      always picks the same target.
    func windowInDirection(_ direction: Direction, from window: HyprWindow, among windows: [HyprWindow]) -> HyprWindow? {
        guard let sourceFrame = window.frame else { return nil }

        struct Scored {
            let window: HyprWindow
            let edgeGap: CGFloat
            let perpOverlap: CGFloat
            let containsRay: Bool
            let perpReadingOrder: CGFloat
        }

        var candidates: [Scored] = []

        for candidate in windows where candidate != window {
            guard let cf = candidate.frame else { continue }

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
