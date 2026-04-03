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
    }

    private func cgWindowsByPID() -> [pid_t: [CGWindowInfo]] {
        var result: [pid_t: [CGWindowInfo]] = [:]
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return result
        }
        for info in windowList {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let wid = info[kCGWindowNumber as String] as? CGWindowID,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0
            )
            result[pid, default: []].append(CGWindowInfo(windowID: wid, bounds: bounds))
        }
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

    // get all visible windows across all apps
    // single-pass matching ensures each CGWindowID is assigned to exactly one AXUIElement
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

            // collect all AX windows with their frames for batch matching
            var axEntries: [(element: AXUIElement, frame: CGRect)] = []
            for axWin in axWindows {
                // skip minimized
                var minimized: AnyObject?
                AXUIElementCopyAttributeValue(axWin, kAXMinimizedAttribute as CFString, &minimized)
                if let min = minimized as? Bool, min { continue }

                // verify it's a real window
                var role: AnyObject?
                AXUIElementCopyAttributeValue(axWin, kAXRoleAttribute as CFString, &role)
                guard let roleStr = role as? String, roleStr == kAXWindowRole as String else { continue }

                guard let frame = axFrame(for: axWin) else { continue }
                axEntries.append((element: axWin, frame: frame))
            }

            // single window for this PID — trivial match
            if candidates.count == 1 && axEntries.count == 1 {
                let wid = candidates[0].windowID
                if !usedIDs.contains(wid) {
                    usedIDs.insert(wid)
                    windows.append(HyprWindow(element: axEntries[0].element, windowID: wid, ownerPID: pid))
                }
                continue
            }

            // multiple windows — match by best position+size fit, ensuring unique assignment
            // build a score matrix and greedily assign best matches
            var availableCG = Set(candidates.map { $0.windowID })

            // sort AX entries so we process them deterministically
            for entry in axEntries {
                var bestWID: CGWindowID?
                var bestDist = CGFloat.infinity

                for cg in candidates {
                    guard availableCG.contains(cg.windowID) && !usedIDs.contains(cg.windowID) else { continue }

                    let dx = abs(entry.frame.origin.x - cg.bounds.origin.x)
                    let dy = abs(entry.frame.origin.y - cg.bounds.origin.y)
                    let dw = abs(entry.frame.width - cg.bounds.width)
                    let dh = abs(entry.frame.height - cg.bounds.height)
                    let dist = dx + dy + dw + dh

                    if dist < bestDist {
                        bestDist = dist
                        bestWID = cg.windowID
                    }
                }

                if let wid = bestWID {
                    availableCG.remove(wid)
                    usedIDs.insert(wid)
                    windows.append(HyprWindow(element: entry.element, windowID: wid, ownerPID: pid))
                }
            }
        }
        return windows
    }

    // get the currently focused window
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

        let axWin = val as! AXUIElement
        guard let frame = axFrame(for: axWin) else { return nil }

        let cgWindows = cgWindowsByPID()
        guard let candidates = cgWindows[pid] else { return nil }

        // find best match by position+size
        var bestWID: CGWindowID?
        var bestDist = CGFloat.infinity
        for cg in candidates {
            let dist = abs(frame.origin.x - cg.bounds.origin.x) +
                       abs(frame.origin.y - cg.bounds.origin.y) +
                       abs(frame.width - cg.bounds.width) +
                       abs(frame.height - cg.bounds.height)
            if dist < bestDist {
                bestDist = dist
                bestWID = cg.windowID
            }
        }

        guard let wid = bestWID else { return nil }
        return HyprWindow(element: axWin, windowID: wid, ownerPID: pid)
    }

    // find the nearest window in a direction from a given window
    // uses weighted scoring: strongly prefers windows directly along the axis
    func windowInDirection(_ direction: Direction, from window: HyprWindow, among windows: [HyprWindow]) -> HyprWindow? {
        guard let origin = window.center else { return nil }

        var best: HyprWindow?
        var bestScore = CGFloat.infinity

        for candidate in windows {
            guard candidate != window, let cc = candidate.center else { continue }

            let dx = cc.x - origin.x
            let dy = cc.y - origin.y

            let axial: CGFloat
            let cross: CGFloat

            switch direction {
            case .left:
                guard dx < -1 else { continue }
                axial = -dx
                cross = abs(dy)
            case .right:
                guard dx > 1 else { continue }
                axial = dx
                cross = abs(dy)
            case .up:
                guard dy < -1 else { continue }
                axial = -dy
                cross = abs(dx)
            case .down:
                guard dy > 1 else { continue }
                axial = dy
                cross = abs(dx)
            }

            // reject if more perpendicular than along-axis (> 60 degree cone)
            guard axial > cross * 0.5 else { continue }

            let score = axial + cross * 3.0
            if score < bestScore {
                bestScore = score
                best = candidate
            }
        }
        return best
    }
}
