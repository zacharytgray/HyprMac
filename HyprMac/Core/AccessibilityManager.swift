// AX bridge: enumerates visible windows across every running app, returns
// the focused window, and exposes `windowInDirection` for swap/focus
// pickers. Windows from this layer come back as `HyprWindow` values
// keyed by stable `CGWindowID`.

import Cocoa

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
        let layer: Int
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

    // windows the AX filter dropped that have been logged once this launch.
    // keyed by window id, or by pid+role+subrole when the id is unreadable.
    private var loggedDrops: Set<String> = []
    // last logged verdict per quick look panel id, so a panel logs when it
    // is admitted or refused, not on every poll
    private var quickLookVerdicts: [CGWindowID: String] = [:]

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
            // layer 0 for ordinary windows. a quick look panel also sits at
            // the floating layer while its app is active; getAllWindows keeps
            // those entries for that panel alone.
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let wid = info[kCGWindowNumber as String] as? CGWindowID,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  WindowAdmissionFilter.quickLookLayers.contains(layer),
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }

            let alpha = info[kCGWindowAlpha as String] as? CGFloat ?? 1.0
            let name = info[kCGWindowName as String] as? String

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0
            )
            result[pid, default: []].append(CGWindowInfo(windowID: wid, bounds: bounds, alpha: alpha,
                                                         name: name, layer: layer))
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

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
    }

    private static func text(_ frame: CGRect?) -> String {
        guard let f = frame else { return "none" }
        return "(\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height)))"
    }

    /// Log a window the AX filter kept out, once per window id per launch.
    ///
    /// This is how an unknown window kind gets identified on a real machine:
    /// the line carries everything the filter looked at, plus the role
    /// description, identifier, title and CG layer for context. Each pass
    /// pays one `_AXUIElementGetWindow` call per dropped window for the key;
    /// the rest is read only the first time.
    private func logDropOnce(_ element: AXUIElement, pid: pid_t, bundle: String,
                             role: String?, subrole: String?, isModal: Bool,
                             reason: WindowAdmissionFilter.DropReason,
                             cgEntries: [CGWindowInfo]) {
        let wid = windowID(for: element)
        let key = wid.map { "\($0)" } ?? "\(pid):\(role ?? "nil"):\(subrole ?? "nil")"
        guard loggedDrops.insert(key).inserted else { return }
        let title = stringAttribute(element, kAXTitleAttribute).map { String($0.prefix(80)) } ?? ""
        let roleDescription = stringAttribute(element, kAXRoleDescriptionAttribute) ?? "nil"
        let identifier = stringAttribute(element, kAXIdentifierAttribute) ?? "nil"
        let cg = wid.flatMap { id in cgEntries.first { $0.windowID == id } }
        let cgText = cg.map { String(format: "layer%d alpha=%.2f", $0.layer, Double($0.alpha)) } ?? "none"
        // a role drop skipped the subrole and modal reads; the log reads them
        let subroleText = reason == .role ? stringAttribute(element, kAXSubroleAttribute) : subrole
        let modal = reason == .role ? (boolAttribute(element, kAXModalAttribute) ?? false) : isModal
        hyprLog(.notice, .discovery, "AX filter dropped: wid=\(wid.map { "\($0)" } ?? "none") pid=\(pid) "
                + "bundle=\(bundle) reason=\(reason.rawValue) role=\(role ?? "nil") "
                + "subrole=\(subroleText ?? "nil") roleDesc=\(roleDescription) ident=\(identifier) "
                + "modal=\(modal) title='\(title)' frame=\(Self.text(axFrame(for: element))) cg=\(cgText)")
    }

    /// Log a Quick Look panel's verdict when it changes: on the first pass
    /// that sees it, and whenever it goes from admitted to refused or back.
    /// A panel that stays admitted logs once per opening.
    private func noteQuickLookVerdict(_ verdict: WindowAdmissionFilter.Verdict,
                                      windowID: CGWindowID, pid: pid_t, bundle: String,
                                      frame: () -> CGRect?, cg: CGWindowInfo?) {
        let key: String
        switch verdict {
        case .quickLookPanel: key = "admitted"
        case .dropped(let reason): key = reason.rawValue
        case .standard: return
        }
        guard quickLookVerdicts[windowID] != key else { return }
        quickLookVerdicts[windowID] = key
        let cgText = cg.map { String(format: "layer%d alpha=%.2f", $0.layer, Double($0.alpha)) } ?? "none"
        if key == "admitted" {
            hyprLog(.notice, .discovery, "quick look panel admitted: wid=\(windowID) pid=\(pid) "
                    + "bundle=\(bundle) cg=\(cgText) frame=\(Self.text(frame())) — floats")
        } else {
            hyprLog(.notice, .discovery, "quick look panel not admitted: wid=\(windowID) pid=\(pid) "
                    + "bundle=\(bundle) reason=\(key) cg=\(cgText) frame=\(Self.text(frame()))")
        }
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

    /// Resolve one `CGWindowID` to its AX element and owner pid.
    ///
    /// Same pairing path as `getAllWindows` — owner from the CG window
    /// list, then the owning app's AX window whose `_AXUIElementGetWindow`
    /// matches — but for a single id and without the discovery filters.
    /// Used by the `--probe-frame` diagnostic.
    func axWindow(forWindowID target: CGWindowID) -> (element: AXUIElement, ownerPID: pid_t)? {
        let owner = cgWindowsByPID().first { _, windows in
            windows.contains { $0.windowID == target }
        }
        guard let pid = owner?.key else { return nil }
        let appRef = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &value) == .success,
              let axWindows = value as? [AXUIElement],
              let element = axWindows.first(where: { windowID(for: $0) == target }) else { return nil }
        return (element, pid)
    }

    /// Where a window that left the on-screen snapshot actually is.
    /// `present` means the app still lists it and it is not minimized —
    /// another Space or native full-screen — so it can come back on its
    /// own. `absent` means the app enumerated fine and the id is gone:
    /// genuinely closed.
    enum HiddenWindowState {
        case minimized
        case appHidden
        case present
        case absent
    }

    /// Classify a hidden window. Returns nil when the AX list can't be
    /// read (caller treats unknown as still-around, the conservative side).
    func hiddenWindowState(windowID target: CGWindowID, pid: pid_t) -> HiddenWindowState? {
        if NSRunningApplication(processIdentifier: pid)?.isHidden == true { return .appHidden }
        let appRef = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let axWindows = value as? [AXUIElement] else { return nil }
        for axWin in axWindows {
            guard windowID(for: axWin) == target else { continue }
            var minimized: AnyObject?
            AXUIElementCopyAttributeValue(axWin, kAXMinimizedAttribute as CFString, &minimized)
            return (minimized as? Bool) == true ? .minimized : .present
        }
        return .absent
    }

    /// Snapshot every visible normal window across all running apps.
    ///
    /// Walks every regular-activation app's `kAXWindowsAttribute`, skips
    /// minimized windows, and lets `WindowAdmissionFilter` decide the rest:
    /// standard windows and Quick Look panels get in; sheets, dialogs and
    /// other panels do not. Each standard window maps to a `CGWindowID` by
    /// calling `_AXUIElementGetWindow` first and falling back to greedy
    /// nearest-position matching only when the SPI fails. The fallback is
    /// defensive — it should not fire in practice. A Quick Look panel is
    /// matched by the SPI alone, and its id is claimed before the fallback
    /// runs.
    ///
    /// Returns an empty array when AX permission has not been granted.
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

        // quick look panel ids seen this pass, so a panel that went away
        // logs again the next time it opens
        var quickLookSeen: Set<CGWindowID> = []

        for app in apps {
            let pid = app.processIdentifier
            let bundle = app.bundleIdentifier ?? "pid \(pid)"
            // layer-0 entries feed ordinary matching exactly as before. the
            // floating layer is only ever matched to a quick look panel, by
            // that panel's own id.
            let cgEntries = cgWindows[pid] ?? []
            let candidates = cgEntries.filter { $0.layer == 0 }
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
                        hyprLog(.notice, .discovery, "AX window-list read FAILED for \(bundle) (err \(result.rawValue)) — \(candidates.count) on-screen window(s) drop from this snapshot")
                    }
                }
                continue
            }
            if let n = axListFailures.removeValue(forKey: pid) {
                hyprLog(.notice, .discovery, "AX window-list read recovered for \(bundle) after \(n) failed cycle(s)")
            }

            // a quick look panel opened from the desktop can be the app's
            // only on-screen window, and it may sit on the floating layer
            guard !cgEntries.isEmpty else { continue }

            // collect the AX windows discovery keeps. WindowAdmissionFilter
            // decides: standard windows, plus quick look panels (which always
            // float). sheets, dialogs and other panels stay out and never
            // claim a CG id.
            var axEntries: [(element: AXUIElement, frame: CGRect)] = []
            var quickLookEntries: [(element: AXUIElement, windowID: CGWindowID, frame: CGRect)] = []
            // every quick look panel's own id, admitted or not. none of them
            // may be handed to another window by the position fallback.
            var quickLookOwnIDs: Set<CGWindowID> = []
            var frameDropCount = 0
            for axWin in axWindows {
                var minimized: AnyObject?
                AXUIElementCopyAttributeValue(axWin, kAXMinimizedAttribute as CFString, &minimized)
                if let min = minimized as? Bool, min { continue }

                // subrole and modal only matter for a window, so a role drop
                // costs one read, as before
                let role = stringAttribute(axWin, kAXRoleAttribute)
                let isWindowRole = role == kAXWindowRole as String
                let subrole = isWindowRole ? stringAttribute(axWin, kAXSubroleAttribute) : nil
                let isModal = isWindowRole ? (boolAttribute(axWin, kAXModalAttribute) ?? false) : false
                let isQuickLook = WindowAdmissionFilter.isQuickLookSubrole(subrole)
                // the panel is matched by its own id only, never by position
                let ownID = isQuickLook ? windowID(for: axWin) : nil
                let ownCG = ownID.flatMap { id in cgEntries.first { $0.windowID == id } }
                if let ownID { quickLookOwnIDs.insert(ownID) }

                let verdict = WindowAdmissionFilter.classify(
                    role: role, subrole: subrole, isModal: isModal,
                    isFullScreen: { self.boolAttribute(axWin, "AXFullScreen") == true },
                    cgWindow: { ownCG.map { .init(layer: $0.layer, alpha: $0.alpha) } }
                )

                switch verdict {
                case .standard:
                    guard let frame = axFrame(for: axWin) else {
                        frameDropCount += 1
                        continue
                    }
                    axEntries.append((element: axWin, frame: frame))
                case .quickLookPanel:
                    guard let id = ownID, let frame = axFrame(for: axWin) else {
                        frameDropCount += 1
                        continue
                    }
                    quickLookSeen.insert(id)
                    noteQuickLookVerdict(verdict, windowID: id, pid: pid, bundle: bundle,
                                         frame: { frame }, cg: ownCG)
                    quickLookEntries.append((element: axWin, windowID: id, frame: frame))
                case .dropped(let reason):
                    if isQuickLook, let id = ownID {
                        quickLookSeen.insert(id)
                        noteQuickLookVerdict(verdict, windowID: id, pid: pid, bundle: bundle,
                                             frame: { self.axFrame(for: axWin) }, cg: ownCG)
                    } else {
                        logDropOnce(axWin, pid: pid, bundle: bundle, role: role, subrole: subrole,
                                    isModal: isModal, reason: reason, cgEntries: cgEntries)
                    }
                }
            }

            // same flap risk as a failed window-list read, but per-window:
            // a standard window whose position/size read fails silently
            // vanishes from the snapshot. edge-logged like above.
            if frameDropCount > 0 {
                let n = (axFrameDrops[pid] ?? 0) + 1
                axFrameDrops[pid] = n
                if n == 1 {
                    hyprLog(.notice, .discovery, "AX frame read FAILED for \(frameDropCount) window(s) of \(bundle) — dropped from this snapshot")
                }
            } else if let n = axFrameDrops.removeValue(forKey: pid) {
                hyprLog(.notice, .discovery, "AX frame reads recovered for \(bundle) after \(n) affected cycle(s)")
            }

            // quick look panels first, so the position fallback below can
            // never hand a panel's id to another window
            for entry in quickLookEntries where !usedIDs.contains(entry.windowID) {
                let hw = HyprWindow(element: entry.element, windowID: entry.windowID, ownerPID: pid)
                hw.isQuickLookPanel = true
                hw.cachedFrame = entry.frame
                hw.seedMinimumSize(bundleIdentifier: app.bundleIdentifier)
                windows.append(hw)
                usedIDs.insert(entry.windowID)
            }
            usedIDs.formUnion(quickLookOwnIDs)

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
        quickLookVerdicts = quickLookVerdicts.filter { quickLookSeen.contains($0.key) }
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

    /// Resolve the keyboard-focused window without consulting discovery's
    /// cache. Workspace transfer uses this stricter path because the cursor
    /// and the internal focus tracker may belong to another display.
    func getActualFocusedStandardWindow() -> HyprWindow? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &raw
        ) == .success,
        let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = raw as! AXUIElement

        func string(_ attribute: String) -> String? {
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
                return nil
            }
            return value as? String
        }
        func flag(_ attribute: String) -> Bool? {
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                  let number = value as? NSNumber else { return nil }
            return number.boolValue
        }

        guard string(kAXRoleAttribute as String) == kAXWindowRole as String,
              string(kAXSubroleAttribute as String) == kAXStandardWindowSubrole as String,
              flag(kAXModalAttribute as String) == false,
              flag(kAXMinimizedAttribute as String) == false,
              flag("AXFullScreen") == false,
              let id = windowID(for: element), let frame = axFrame(for: element) else { return nil }
        let window = HyprWindow(element: element, windowID: id, ownerPID: app.processIdentifier)
        window.cachedFrame = frame
        window.seedMinimumSize(bundleIdentifier: app.bundleIdentifier)
        return window
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
