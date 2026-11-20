// AX bridge: enumerates visible windows across every running app, returns
// the focused window, and exposes `windowInDirection` for swap/focus
// pickers. Windows from this layer come back as `HyprWindow` handles
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

    /// Windows the last `getAllWindows` walk could not read: every visible
    /// window of an app whose window list did not answer, and each window
    /// whose frame did not. The window server still lists them on screen,
    /// so their absence from the snapshot says nothing about them, and
    /// discovery holds them instead of marking them gone.
    private(set) var unreadableWindowIDs: Set<CGWindowID> = []
    /// Windows the last `getAllWindows` walk read. Newer evidence than a
    /// hold discovery took in an earlier poll: a window in it is readable
    /// and on screen, whatever that poll said.
    private(set) var readWindowIDs: Set<CGWindowID> = []

    /// Messaging timeout for the discovery walk. The process-wide default is
    /// one second, which is what one stalled app costs the main thread per
    /// call; the walk asks every app on every poll, and an app that does not
    /// answer in this time is held rather than judged, so the short budget
    /// loses nothing.
    static let discoveryMessagingTimeout: Float = 0.25

    /// Apps whose window list did not answer, and when the walk may ask
    /// them again. Every walk asked every stalled app anew, and a walk runs
    /// on every poll, every window event and before every switch and move:
    /// with three apps stalled at once each of those paid three quarters of
    /// a second on the main thread, for two days. The windows of a stalled
    /// app stay held meanwhile, so nothing on screen depends on the answer.
    /// internal so a test can stall an app
    var stallBackoff = StallBackoff()
    /// The walk's time budget and what each app cost to read.
    private var pacing = WalkPacing()
    /// how long the last walk took, and what it skipped, for the trace line
    private(set) var lastWalkDuration: TimeInterval = 0
    /// injected so tests can move time
    var now: () -> Date = { Date() }

    /// Windows the last walk found listed by their app, as standard
    /// windows with an id the SPI named, that it could not bind: the
    /// window server shows nothing of the app, or that window is not on
    /// screen, or another element holds it. A window its app lists before
    /// the window server shows it ends up here, and discovery gives it
    /// another look soon instead of at the ten-second reconcile.
    var unboundWindowIDs: Set<CGWindowID> = []

    /// Per app, the keys of the walk lines last logged for it (unbound
    /// windows, position-fallback binds), so each logs once per episode.
    private var walkLines: [pid_t: Set<String>] = [:]

    /// How long until the walk can next ask an app it is skipping: a
    /// stalled app whose backoff runs out, a stalled app that was due but
    /// not the one asked, or an app the walk budget left out. The caller
    /// polls then, so a window that app opened, or one held while it did
    /// not answer, is not left for the ten-second reconcile. nil with none.
    var secondsUntilABackoffEnds: TimeInterval? {
        [stallBackoff.secondsUntilNextProbe(now: now()), pacing.secondsUntilRetry].compactMap { $0 }.min()
    }

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

    /// `CGWindowID` of `pid`'s AX-focused window, or nil when AX cannot
    /// say. Two round-trips to that one app, no walk.
    func focusedWindowID(ofPID pid: pid_t) -> CGWindowID? {
        // a stalled app would time out here on every hover; nil polls, and
        // the walk skips it
        if stallBackoff.isBackingOff(pid, now: now()) { return nil }
        let appRef = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appRef, Self.discoveryMessagingTimeout)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let val = value,
              CFGetTypeID(val) == AXUIElementGetTypeID() else { return nil }
        return windowID(for: val as! AXUIElement)
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

    /// Messaging timeout for a reveal retry. Short, because the retry asks
    /// again every 100 ms while the app is busy: a longer one would park the
    /// main thread most of that time for an answer the next ask gets anyway.
    static let revealRetryMessagingTimeout: Float = 0.05

    /// `ids` among `pid`'s AX windows, read with the reveal retry's short
    /// timeout. Ignores the walk's stall backoff: a switch that could not
    /// reveal a window asks its app again sooner than the walk would. A
    /// failure leaves the backoff as it is; an answer ends it, so the walk
    /// that retiles a held tile asks the app instead of skipping it.
    /// - Returns: the windows found, or nil when the window list did not answer.
    func revealRetryWindows(_ ids: Set<CGWindowID>, ofPID pid: pid_t) -> [HyprWindow]? {
        let appRef = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appRef, Self.revealRetryMessagingTimeout)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &value) == .success,
              let axWindows = value as? [AXUIElement] else { return nil }
        noteWindowListAnswered(pid)
        return axWindows.compactMap { element in
            guard let id = windowID(for: element), ids.contains(id) else { return nil }
            return HyprWindow(element: element, windowID: id, ownerPID: pid)
        }
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

    /// `pid` answered its window list outside the walk. It is not stalled
    /// any more: the next walk asks it like any other app. The walk logs
    /// the recovery when it reads the app itself.
    func noteWindowListAnswered(_ pid: pid_t) {
        stallBackoff.noteSuccess(pid)
    }

    /// Whether the walk is backing off from `pid`: its window list timed
    /// out and is not asked again yet. A read of it now would time out
    /// too, so callers that keep a budget of asks skip it without spending
    /// one.
    func isBackingOff(pid: pid_t) -> Bool {
        stallBackoff.isBackingOff(pid, now: now())
    }

    /// Classify a hidden window. Returns nil when the AX list can't be
    /// read (caller treats unknown as still-around, the conservative side).
    func hiddenWindowState(windowID target: CGWindowID, pid: pid_t) -> HiddenWindowState? {
        if NSRunningApplication(processIdentifier: pid)?.isHidden == true { return .appHidden }
        // an app the walk is backing off from would not answer this either;
        // nil is what a timed-out read returns, without the wait
        if stallBackoff.isBackingOff(pid, now: now()) { return nil }
        let appRef = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appRef, Self.discoveryMessagingTimeout)
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
    /// other panels do not. `AXWindowMatcher` pairs each standard window
    /// with its `CGWindowID`: the id `_AXUIElementGetWindow` names, when
    /// that window is on screen and free, and never another id when the
    /// named window is real; the nearest unused on-screen window, within a
    /// distance limit, only when the SPI fails. A Quick Look panel is
    /// matched by the SPI alone, and its id is claimed before the fallback
    /// runs. A standard window that ends the walk unbound logs why, once.
    ///
    /// The walk keeps a time budget (`WalkPacing`): once it is spent, apps
    /// not known to answer fast are skipped, their windows held, and asked
    /// first on the next walk.
    ///
    /// Returns an empty array when AX permission has not been granted.
    /// Whether discovery asks an app for its windows: a regular app that is
    /// not a Quick Look helper and not HyprMac. With Show in Dock on HyprMac
    /// is a regular app too, and its normal-level windows (the updater's)
    /// would be tiled like anyone else's.
    static func isWalked(policy: NSApplication.ActivationPolicy, pid: pid_t, bundleID: String?,
                         excludedBundleIDs: Set<String>, ownPID: pid_t = getpid()) -> Bool {
        policy == .regular && pid != ownPID && !excludedBundleIDs.contains(bundleID ?? "")
    }

    func getAllWindows() -> [HyprWindow] {
        guard AXIsProcessTrusted() else { return [] }

        let walkStarted = now()
        let cgWindows = cgWindowsByPID()
        var windows: [HyprWindow] = []
        var usedIDs: Set<CGWindowID> = []
        var unreadable: Set<CGWindowID> = []
        var unbound: Set<CGWindowID> = []
        var skipped: [String] = []
        var overBudget: [pid_t] = []
        var overBudgetBundles: [String] = []

        // quick look processes, never walked
        let excludedBundleIDs: Set<String> = [
            "com.apple.quicklook.QuickLookUIService",
            "com.apple.QuickLookDaemon",
        ]

        let running = NSWorkspace.shared.runningApplications.filter {
            Self.isWalked(policy: $0.activationPolicy, pid: $0.processIdentifier,
                          bundleID: $0.bundleIdentifier, excludedBundleIDs: excludedBundleIDs)
        }
        // apps the last walk's budget left out go first
        let byPID = Dictionary(running.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let apps = pacing.order(running.map(\.processIdentifier)).compactMap { byPID[$0] }
        // one stalled app whose backoff is up is asked per walk, so a walk
        // pays one timeout however many apps are stalled. the one asked
        // longest ago goes, so an app that always stalls can't starve one
        // that recovered
        let probe = stallBackoff.probeTarget(among: apps.map(\.processIdentifier), now: walkStarted)

        // quick look panel ids seen this pass, so a panel that went away
        // logs again the next time it opens
        var quickLookSeen: Set<CGWindowID> = []

        for app in apps {
            let pid = app.processIdentifier
            let bundle = app.bundleIdentifier ?? "pid \(pid)"
            // layer-0 entries feed ordinary matching. the
            // floating layer is only ever matched to a quick look panel, by
            // that panel's own id.
            let cgEntries = cgWindows[pid] ?? []
            let candidates = cgEntries.filter { $0.layer == 0 }
            let visible = candidates.filter { $0.alpha > 0.01 }
            // a stalled app is not asked until its backoff is up, and only
            // one of them per walk; its windows stay held meanwhile
            let appStarted = now()
            if stallBackoff.isBackingOff(pid, now: appStarted)
                || (stallBackoff.isDue(pid, now: appStarted) && pid != probe) {
                unreadable.formUnion(visible.map(\.windowID))
                skipped.append(bundle)
                continue
            }
            // past the budget only apps that answered fast last time are
            // asked. the rest are held, the same as a stalled app's
            if pacing.shouldSkip(pid, elapsed: appStarted.timeIntervalSince(walkStarted)) {
                unreadable.formUnion(visible.map(\.windowID))
                skipped.append(bundle)
                overBudget.append(pid)
                overBudgetBundles.append(bundle)
                continue
            }
            if pid == probe { stallBackoff.noteProbe(pid, now: appStarted) }
            defer { pacing.noteCost(pid, now().timeIntervalSince(appStarted)) }

            let appRef = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appRef, Self.discoveryMessagingTimeout)
            var value: AnyObject?
            let result = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &value)
            guard result == .success, let axWindows = value as? [AXUIElement] else {
                // a busy app (main thread stalled) fails this read wholesale
                // and every one of its windows drops from the snapshot for
                // the cycle. the window server still shows them, so they are
                // reported unreadable and discovery holds them in place.
                // log the outage edges only, not every cycle. an app opening
                // its first window has none on screen yet, and logs too
                unreadable.formUnion(visible.map(\.windowID))
                let wait = stallBackoff.noteListReadFailure(pid, error: result, now: appStarted)
                let n = (axListFailures[pid] ?? 0) + 1
                axListFailures[pid] = n
                if n == 1 {
                    hyprLog(.notice, .discovery, "AX window-list read FAILED for \(bundle) (err \(result.rawValue)) — \(candidates.count) on-screen window(s) drop from this snapshot"
                            + (wait.map { "; asked again in \(Int(($0 * 1000).rounded()))ms" } ?? ""))
                }
                continue
            }
            stallBackoff.noteSuccess(pid)
            if let n = axListFailures.removeValue(forKey: pid) {
                hyprLog(.notice, .discovery, "AX window-list read recovered for \(bundle) after \(n) failed cycle(s)")
            }

            // an app hidden with Cmd-H has nothing on screen and nothing to
            // say about it. a quick look panel opened from the desktop can
            // be the app's only on-screen window, on the floating layer
            if cgEntries.isEmpty && app.isHidden {
                noteWalkLines([:], pid: pid)
                continue
            }

            // collect the AX windows discovery keeps. WindowAdmissionFilter
            // decides: standard windows, plus quick look panels (which always
            // float). sheets, dialogs and other panels stay out and never
            // claim a CG id.
            var axEntries: [(element: AXUIElement, frame: CGRect, spiID: CGWindowID?)] = []
            var quickLookEntries: [(element: AXUIElement, windowID: CGWindowID, frame: CGRect)] = []
            // every quick look panel's own id, admitted or not. none of them
            // may be handed to another window by the position fallback.
            var quickLookOwnIDs: Set<CGWindowID> = []
            var frameDropCount = 0
            // why each standard window that stays out of the snapshot does,
            // keyed so a window logs once while the reason lasts
            var lines: [String: String] = [:]
            func noteUnbound(_ reason: String, id: CGWindowID?, frame: CGRect?, detail: String = "") {
                let key = "unbound:\(reason):\(id.map { "\($0)" } ?? Self.text(frame))"
                lines[key] = "AX window unbound: bundle=\(bundle) pid=\(pid) wid=\(id.map { "\($0)" } ?? "none")"
                    + " reason=\(reason)\(detail) frame=\(Self.text(frame))"
            }
            for axWin in axWindows {
                AXUIElementSetMessagingTimeout(axWin, Self.discoveryMessagingTimeout)
                var minimized: AnyObject?
                AXUIElementCopyAttributeValue(axWin, kAXMinimizedAttribute as CFString, &minimized)
                if let min = minimized as? Bool, min { continue }

                // subrole and modal only matter for a window, so a role drop
                // costs one read
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
                    let spiID = windowID(for: axWin)
                    // listed, but the window server shows nothing of the
                    // app: not on screen yet, or on another Space
                    guard !cgEntries.isEmpty else {
                        if let spiID { unbound.insert(spiID) }
                        noteUnbound("noOnScreenWindow", id: spiID, frame: nil)
                        continue
                    }
                    guard let frame = axFrame(for: axWin) else {
                        // the window is listed but its frame did not answer:
                        // unreadable, not absent
                        if let spiID { unreadable.insert(spiID) }
                        frameDropCount += 1
                        noteUnbound("frameUnreadable", id: spiID, frame: nil)
                        continue
                    }
                    axEntries.append((element: axWin, frame: frame, spiID: spiID))
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

            // an id the SPI names is real when the window server knows it
            // for this app, on screen or off
            let match = AXWindowMatcher.match(
                axEntries.map { AXWindowMatcher.Element(frame: $0.frame, spiID: $0.spiID) },
                candidates: visible.map { AXWindowMatcher.Candidate(windowID: $0.windowID, bounds: $0.bounds) },
                used: usedIDs,
                isRealWindow: { id in cgEntries.contains { $0.windowID == id } || self.cgWindowOwner(id) == pid }
            )
            for bound in match.bound {
                let entry = axEntries[bound.index]
                usedIDs.insert(bound.windowID)
                let hw = HyprWindow(element: entry.element, windowID: bound.windowID, ownerPID: pid)
                hw.cachedFrame = entry.frame
                hw.seedMinimumSize(bundleIdentifier: app.bundleIdentifier)
                windows.append(hw)
                if let distance = bound.fallbackDistance {
                    let cg = visible.first { $0.windowID == bound.windowID }
                    lines["fallback:\(bound.windowID)"] = "AX position fallback bound: bundle=\(bundle) pid=\(pid)"
                        + " wid=\(bound.windowID) spi=\(entry.spiID.map { "\($0) (not a window)" } ?? "failed")"
                        + " distance=\(Int(distance.rounded())) frame=\(Self.text(entry.frame))"
                        + " cg=\(Self.text(cg?.bounds))"
                }
            }
            for miss in match.unbound {
                let entry = axEntries[miss.index]
                switch miss.reason {
                case .offScreen(let id):
                    unbound.insert(id)
                    noteUnbound("idOffScreen", id: id, frame: entry.frame)
                case .taken(let id):
                    noteUnbound("idTaken", id: id, frame: entry.frame)
                case .noCandidate:
                    noteUnbound("noFallbackCandidate", id: nil, frame: entry.frame)
                case .tooFar(let nearest, let distance):
                    noteUnbound("fallbackTooFar", id: nil, frame: entry.frame,
                                detail: " nearest=\(nearest) distance=\(Int(distance.rounded()))")
                }
            }
            noteWalkLines(lines, pid: pid)
        }
        quickLookVerdicts = quickLookVerdicts.filter { quickLookSeen.contains($0.key) }
        let runningPIDs = Set(apps.map(\.processIdentifier))
        stallBackoff.retain(runningPIDs)
        walkLines = walkLines.filter { runningPIDs.contains($0.key) }
        if Set(overBudget) != Set(pacing.skippedLastWalk) {
            if overBudget.isEmpty {
                hyprLog(.notice, .discovery, "AX walk within its budget again")
            } else {
                hyprLog(.notice, .discovery, "AX walk over its \(Int(WalkPacing.budget * 1000))ms budget:"
                        + " skipped \(overBudgetBundles) — their windows are held, and they are asked first next walk")
            }
        }
        pacing.finishWalk(skipped: overBudget, running: runningPIDs)
        unreadableWindowIDs = unreadable
        readWindowIDs = Set(windows.map(\.windowID))
        unboundWindowIDs = unbound
        lastWalkDuration = now().timeIntervalSince(walkStarted)
        hyprLog(.debug, .discovery, "AX walk: apps=\(apps.count) windows=\(windows.count) unreadable=\(unreadable.count) \(Int((lastWalkDuration * 1000).rounded()))ms"
                + (skipped.isEmpty ? "" : " skipped=\(skipped)"))
        return windows
    }

    /// Log one app's walk lines that are new since its last read, and
    /// remember the set: each logs when its condition begins, not every walk.
    private func noteWalkLines(_ lines: [String: String], pid: pid_t) {
        let before = walkLines[pid] ?? []
        for key in lines.keys.sorted() where !before.contains(key) {
            hyprLog(.notice, .discovery, lines[key]!)
        }
        walkLines[pid] = Set(lines.keys)
    }

    /// The owner of any window the window server knows, on screen or not.
    private func cgWindowOwner(_ id: CGWindowID) -> pid_t? {
        var values: [UnsafeRawPointer?] = [UnsafeRawPointer(bitPattern: UInt(id))]
        let array = values.withUnsafeMutableBufferPointer {
            CFArrayCreate(nil, $0.baseAddress, 1, nil)
        }
        guard let array,
              let info = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] else { return nil }
        return info.first?[kCGWindowOwnerPID as String] as? pid_t
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
              app.activationPolicy == .regular,
              app.processIdentifier != getpid() else { return nil }
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


/// When the discovery walk may ask a stalled app again. An app whose
/// window list timed out is skipped for a growing interval, from half a
/// second to eight, and asked again once it is up; an answer ends the
/// backoff. Nothing on screen waits on it: the app's windows are held in
/// place until it answers, and a window it opens meanwhile is discovered
/// when it does. One due app is asked per walk, the one asked longest ago,
/// and the caller polls when the next one comes due.
struct StallBackoff {
    var initial: TimeInterval = 0.5
    var cap: TimeInterval = 8
    /// how soon to poll again when an app is due but another was asked
    static let dueRetry: TimeInterval = 1.0
    private var until: [pid_t: Date] = [:]
    private var interval: [pid_t: TimeInterval] = [:]
    private var lastProbe: [pid_t: Date] = [:]

    /// pids with a backoff on record, up or not
    var stalledPIDs: Set<pid_t> { Set(until.keys) }

    /// the app is not to be asked yet
    func isBackingOff(_ pid: pid_t, now: Date) -> Bool {
        guard let until = until[pid] else { return false }
        return now < until
    }

    /// the app is stalled on record and its backoff is up: one probe is due
    func isDue(_ pid: pid_t, now: Date) -> Bool {
        guard let until = until[pid] else { return false }
        return now >= until
    }

    /// The due app to ask this walk: the one asked longest ago, never-asked
    /// first, then the one due longest. Enumeration order plays no part, so
    /// an app that always stalls can't starve one that recovered.
    func probeTarget(among pids: [pid_t], now: Date) -> pid_t? {
        pids.filter { isDue($0, now: now) }.min { a, b in
            let probedA = lastProbe[a] ?? .distantPast
            let probedB = lastProbe[b] ?? .distantPast
            if probedA != probedB { return probedA < probedB }
            return (until[a] ?? now, a) < (until[b] ?? now, b)
        }
    }

    mutating func noteProbe(_ pid: pid_t, now: Date) {
        lastProbe[pid] = now
    }

    /// How long until the walk should ask a stalled app again: the next
    /// backoff to run out, or `dueRetry` when one is already due. nil when
    /// no app is stalled.
    func secondsUntilNextProbe(now: Date) -> TimeInterval? {
        guard !until.isEmpty else { return nil }
        let ahead = until.values.filter { $0 > now }.map { $0.timeIntervalSince(now) }.min()
        let due = until.values.contains { $0 <= now } ? Self.dueRetry : nil
        return [ahead, due].compactMap { $0 }.min().map { max(0.05, $0) }
    }

    /// - Returns: how long the app is skipped from now.
    @discardableResult
    mutating func noteFailure(_ pid: pid_t, now: Date) -> TimeInterval {
        let next = min((interval[pid] ?? initial / 2) * 2, cap)
        interval[pid] = next
        until[pid] = now.addingTimeInterval(next)
        return next
    }

    /// A failed window-list read. Only a timeout earns the backoff: the app
    /// has a window list and did not answer for it in time. Any other error
    /// (an app still launching, one whose accessibility is not up yet) is
    /// asked again on the next walk, so it tiles as soon as it can and not
    /// up to eight seconds later.
    /// - Returns: how long the app is skipped from now, or nil for no backoff.
    mutating func noteListReadFailure(_ pid: pid_t, error: AXError, now: Date) -> TimeInterval? {
        error == .cannotComplete ? noteFailure(pid, now: now) : nil
    }

    mutating func noteSuccess(_ pid: pid_t) {
        until.removeValue(forKey: pid)
        interval.removeValue(forKey: pid)
        lastProbe.removeValue(forKey: pid)
    }

    /// Drop the record of apps no longer running.
    mutating func retain(_ running: Set<pid_t>) {
        until = until.filter { running.contains($0.key) }
        interval = interval.filter { running.contains($0.key) }
        lastProbe = lastProbe.filter { running.contains($0.key) }
    }
}

/// The discovery walk's time budget. The messaging timeout bounds one AX
/// call, not a walk: several apps stalling for the first time, or an app
/// whose window list answers fast and whose windows answer slowly, could
/// keep the main thread for seconds. Once a walk has spent `budget`, it
/// asks only apps whose last read took under `slowApp`; the rest are
/// skipped, their windows held like a stalled app's, and asked first on
/// the next walk, which the caller schedules after `skippedRetry`.
struct WalkPacing {
    static let budget: TimeInterval = 0.5
    static let slowApp: TimeInterval = 0.1
    static let skippedRetry: TimeInterval = 1.0

    /// what each app's last read cost, list and windows together
    private(set) var cost: [pid_t: TimeInterval] = [:]
    /// apps the last walk skipped for the budget, in walk order
    private(set) var skippedLastWalk: [pid_t] = []

    /// The walk order: apps the last walk skipped first, then the rest as given.
    func order(_ pids: [pid_t]) -> [pid_t] {
        let present = Set(pids)
        let first = skippedLastWalk.filter { present.contains($0) }
        let firstSet = Set(first)
        return first + pids.filter { !firstSet.contains($0) }
    }

    /// Whether to skip `pid` with `elapsed` of the walk spent. An app not
    /// read yet counts as slow: it might be.
    func shouldSkip(_ pid: pid_t, elapsed: TimeInterval) -> Bool {
        guard elapsed >= Self.budget else { return false }
        guard let cost = cost[pid] else { return true }
        return cost >= Self.slowApp
    }

    mutating func noteCost(_ pid: pid_t, _ seconds: TimeInterval) {
        cost[pid] = seconds
    }

    mutating func finishWalk(skipped: [pid_t], running: Set<pid_t>) {
        skippedLastWalk = skipped
        cost = cost.filter { running.contains($0.key) }
    }

    /// when to walk again for the apps the budget left out, or nil
    var secondsUntilRetry: TimeInterval? {
        skippedLastWalk.isEmpty ? nil : Self.skippedRetry
    }
}

/// Pairs one app's standard AX windows with its on-screen CG windows.
///
/// The id `_AXUIElementGetWindow` names is the window's own. When that id
/// is on screen and free, the element gets it. When it is a real window
/// that is off screen (another Space, alpha 0, not shown yet) or already
/// held, the element stays unbound: binding it to some other id would send
/// that window's frame writes to this one. Only an element whose SPI
/// failed, or named no window the app has, falls back to the nearest
/// unused on-screen window, and only within `maxFallbackDistance`.
///
/// Threading: pure; no state.
enum AXWindowMatcher {
    /// summed difference of origin and size, in points. a window the SPI
    /// can't name is still where the window server shows it, give or take
    /// a stale read mid-move
    static let maxFallbackDistance: CGFloat = 64

    struct Element: Equatable {
        let frame: CGRect
        let spiID: CGWindowID?
    }

    struct Candidate: Equatable {
        let windowID: CGWindowID
        let bounds: CGRect
    }

    enum Unbound: Equatable {
        /// the SPI named a real window that is not on screen
        case offScreen(CGWindowID)
        /// the SPI named an on-screen window another element already holds
        case taken(CGWindowID)
        /// no SPI id, and no unused on-screen window is left
        case noCandidate
        /// no SPI id, and the nearest unused on-screen window is too far
        case tooFar(nearest: CGWindowID, distance: CGFloat)
    }

    struct Bound: Equatable {
        let index: Int
        let windowID: CGWindowID
        /// how far the position fallback reached, or nil for an SPI bind
        let fallbackDistance: CGFloat?
    }

    struct Result: Equatable {
        var bound: [Bound] = []
        var unbound: [(index: Int, reason: Unbound)] = []

        static func == (a: Result, b: Result) -> Bool {
            a.bound == b.bound && a.unbound.map(\.index) == b.unbound.map(\.index)
                && a.unbound.map(\.reason) == b.unbound.map(\.reason)
        }
    }

    static func distance(_ frame: CGRect, _ bounds: CGRect) -> CGFloat {
        abs(frame.origin.x - bounds.origin.x) + abs(frame.origin.y - bounds.origin.y)
            + abs(frame.width - bounds.width) + abs(frame.height - bounds.height)
    }

    /// - Parameters:
    ///   - candidates: the app's visible on-screen windows
    ///   - used: ids already bound this walk, never handed out again
    ///   - isRealWindow: whether the window server knows the id for this
    ///     app, on screen or off
    /// - Returns: binds in element order, and every element left unbound
    static func match(_ elements: [Element], candidates: [Candidate], used: Set<CGWindowID>,
                      isRealWindow: (CGWindowID) -> Bool) -> Result {
        var result = Result()
        var used = used
        let onScreen = Set(candidates.map(\.windowID))
        var fallback: [Int] = []
        for (index, element) in elements.enumerated() {
            guard let id = element.spiID else {
                fallback.append(index)
                continue
            }
            if onScreen.contains(id) {
                if used.insert(id).inserted {
                    result.bound.append(Bound(index: index, windowID: id, fallbackDistance: nil))
                } else {
                    result.unbound.append((index, .taken(id)))
                }
            } else if isRealWindow(id) {
                result.unbound.append((index, .offScreen(id)))
            } else {
                fallback.append(index)
            }
        }

        // closest pairs first, so the order the app lists its windows in
        // can't hand a near window's id to a far element
        var pairs: [(index: Int, windowID: CGWindowID, distance: CGFloat)] = []
        for index in fallback {
            for candidate in candidates where !used.contains(candidate.windowID) {
                pairs.append((index, candidate.windowID, distance(elements[index].frame, candidate.bounds)))
            }
        }
        pairs.sort { ($0.distance, $0.index, $0.windowID) < ($1.distance, $1.index, $1.windowID) }
        var placed: Set<Int> = []
        for pair in pairs {
            guard pair.distance <= maxFallbackDistance,
                  !placed.contains(pair.index), !used.contains(pair.windowID) else { continue }
            placed.insert(pair.index)
            used.insert(pair.windowID)
            result.bound.append(Bound(index: pair.index, windowID: pair.windowID, fallbackDistance: pair.distance))
        }
        // pairs is sorted, so the first still-unused candidate is the
        // nearest one left, and it is past the limit or it would be bound
        for index in fallback where !placed.contains(index) {
            if let near = pairs.first(where: { $0.index == index && !used.contains($0.windowID) }) {
                result.unbound.append((index, .tooFar(nearest: near.windowID, distance: near.distance)))
            } else {
                result.unbound.append((index, .noCandidate))
            }
        }
        result.bound.sort { $0.index < $1.index }
        result.unbound.sort { $0.index < $1.index }
        return result
    }
}
