// Per-window min-size bookkeeping for the tiling subsystem. macOS apps
// do not expose reliable `AXMinimumSize`; this class learns the actual
// floor from `FrameReadbackPoller`'s guarded readback evidence and
// remembers it for subsequent layout decisions.

import Cocoa

/// Where a remembered minimum came from.
///
/// `seeded` is a hint: `AXMinimumSize` or a per-bundle-id guess. Nothing
/// has refused a smaller frame, so it is a starting estimate only.
/// `observed` is a bound the app actually refused to shrink below, on the
/// axis it refused, read back at the origin it was told to sit at.
/// `appHint` is another window of the same app's `observed` bound, carried
/// over so a second Outlook window does not have to prove the same floor
/// with its own visible resize. It is stronger than a guess and weaker than
/// evidence: fit checks honour it, the refusal diagnostics name it as its
/// own `appHint` source, and an explicit user request sets it aside the way
/// it sets an `observed` bound aside — it is somebody else's evidence, and
/// this window has never been asked.
enum MinSizeProvenance: String {
    case seeded, observed, appHint
}

/// A length a window kept on one axis while it took every other part of its
/// frame: a fixed or maximum size no larger slot can hold. Raycast's
/// Settings window stays 960 wide whatever it is asked.
struct FixedSize: Equatable {
    enum Axis: String { case width, height }
    let bundleID: String?
    let axis: Axis
    let length: CGFloat

    func matches(_ size: CGSize) -> Bool {
        abs((axis == .width ? size.width : size.height) - length) <= 1
    }
}

/// Per-window min-size memory.
///
/// macOS apps with hard minimums (Spotify, Messages, Xcode) refuse to
/// shrink past a UI-state-dependent floor that AX does not surface up
/// front. When a readback survives the learning guards in
/// `FrameReadbackPoller`, the observed size becomes the new known min
/// until a later layout witnesses an even tighter accepted resize and
/// lowers the bound.
///
/// Per-axis evidence is kept per axis. Zero on an axis means nothing has
/// refused anything there, and a fit check reads it as no constraint.
///
/// A window with no entry of its own starts from its app's hint when one
/// of the app's other windows has refused something. A hint rises on a
/// refusal and falls on an accepted smaller size, so one stubborn window
/// cannot speak for the app forever. Hints live in memory only and are
/// keyed by bundle id; an empty id names no app, and nothing persists
/// across a restart.
///
/// Hysteresis on both ends:
/// - Record: only raises, and only on the axis the app refused. A seeded
///   hint or an app hint is replaced rather than merged, so an axis nothing
///   refused does not inherit a guess and call it evidence.
/// - Lower: requires an accepted size at least
///   `lowerMinSizeAcceptedDeltaPx` below the current bound — sub-pixel
///   accepts cannot ratchet the floor down.
///
/// The memory is mirrored back onto each `HyprWindow.observedMinSize` and
/// `HyprWindow.minSizeProvenance` so other subsystems (drag-swap fit
/// checks) see consistent values.
class MinSizeMemory {
    /// One remembered minimum and what kind of evidence produced it.
    struct Entry: Equatable {
        var size: CGSize
        var provenance: MinSizeProvenance
    }

    private var known: [CGWindowID: Entry] = [:]
    /// Per-axis max of every `observed` bound this app's windows have
    /// produced, keyed by bundle id. Memory only: a restart starts over,
    /// because a floor depends on the UI state the window was in.
    private var appHints: [String: CGSize] = [:]
    /// Windows that kept their own length on an axis, see `FixedSize`.
    private var fixedWindows: [CGWindowID: FixedSize] = [:]
    /// The same evidence per app: a new window of that app opening at that
    /// length floats without a write. Memory only, oldest out past the cap.
    private(set) var fixedAppHints: [FixedSize] = []
    static let fixedAppHintCap = 64

    /// Everything currently remembered, for the state dump.
    var snapshot: [CGWindowID: Entry] { known }

    func entry(for windowID: CGWindowID) -> Entry? { known[windowID] }

    /// Sync this map and the window's mirror. If we already have a recorded
    /// bound, push it onto the window; otherwise take the app's hint if its
    /// siblings have produced one, and failing that a usable AX-seeded value
    /// as our starting estimate. Both are marked as the hints they are.
    ///
    /// The app's hint outranks the AX seed: one of this app's own windows
    /// actually refused that size, while the seed is a number the app
    /// published without being asked.
    func prime(_ windows: [HyprWindow]) {
        for window in windows {
            if let entry = known[window.windowID] {
                mirror(entry, onto: window)
                continue
            }
            var candidate: Entry?
            if let bundleID = window.bundleID, !bundleID.isEmpty,
               let hint = appHints[bundleID], isUsable(hint) {
                candidate = Entry(size: hint, provenance: .appHint)
            } else if let seeded = window.observedMinSize, isUsable(seeded) {
                candidate = Entry(size: seeded, provenance: window.minSizeProvenance)
            }
            guard let entry = candidate else { continue }
            known[window.windowID] = entry
            mirror(entry, onto: window)
            hyprLog(.debug, .lifecycle, "min-size record: wid=\(window.windowID) "
                    + "old=none new=\(Self.text(entry.size)) axis=width+height "
                    + "source=\(entry.provenance.rawValue)")
        }
    }

    func forget(windowID: CGWindowID) {
        known.removeValue(forKey: windowID)
        fixedWindows.removeValue(forKey: windowID)
    }

    func recordFixedSize(_ window: HyprWindow, axis: FixedSize.Axis, length: CGFloat,
                         target: CGSize) {
        let bundleID = window.bundleID.flatMap { $0.isEmpty ? nil : $0 }
        let fixed = FixedSize(bundleID: bundleID, axis: axis, length: length)
        fixedWindows[window.windowID] = fixed
        if bundleID != nil {
            fixedAppHints.removeAll { $0 == fixed }
            fixedAppHints.append(fixed)
            if fixedAppHints.count > Self.fixedAppHintCap { fixedAppHints.removeFirst() }
        }
        hyprLog(.notice, .tiling, "fixed-size record: wid=\(window.windowID) "
                + "bundle=\(bundleID ?? "none") axis=\(axis.rawValue) "
                + "length=\(String(format: "%g", Double(length))) target=\(Self.text(target))")
    }

    /// What keeps `window` out of a slot: its own record, or its app's hint
    /// for the length it is standing at now.
    func fixedSize(for window: HyprWindow) -> FixedSize? {
        if let own = fixedWindows[window.windowID] { return own }
        guard let bundleID = window.bundleID, !bundleID.isEmpty,
              let size = window.cachedFrame?.size else { return nil }
        return fixedAppHints.last { $0.bundleID == bundleID && $0.matches(size) }
    }

    /// The user tiled the window by hand, so neither it nor its app's hint
    /// for that length speaks for it any more. A refusal records them again.
    func forgetFixedSize(_ window: HyprWindow) {
        guard let fixed = fixedSize(for: window) else { return }
        fixedWindows.removeValue(forKey: window.windowID)
        fixedAppHints.removeAll { $0 == fixed }
    }

    func minimumSize(for window: HyprWindow?) -> CGSize {
        guard let window else { return .zero }
        return known[window.windowID]?.size ?? window.observedMinSize ?? .zero
    }

    /// Record a settled min-size conflict that passed `FrameReadbackPoller`'s
    /// learning guards. Raises the bound on whichever axis the app refused;
    /// never lowers from here.
    ///
    /// A seeded hint is not a floor, so real evidence replaces it instead of
    /// merging with it: the axis this readback did not refuse goes back to
    /// unknown rather than keeping a guess under an `observed` label.
    ///
    /// - Returns: `true` when an entry was written, so the caller can stamp
    ///   when the evidence arrived.
    @discardableResult
    func recordObserved(_ window: HyprWindow,
                        target: CGSize,
                        actual: CGSize,
                        widthConflict: Bool,
                        heightConflict: Bool,
                        phase: FrameSizingPhase,
                        sharedWithApp: Bool = true) -> Bool {
        let existing = known[window.windowID]
        let base = existing?.provenance == .observed ? (existing?.size ?? .zero) : CGSize.zero
        let updated = CGSize(
            width: widthConflict ? max(base.width, actual.width) : base.width,
            height: heightConflict ? max(base.height, actual.height) : base.height
        )
        let axis = FrameReadbackPoller.axis(width: widthConflict, height: heightConflict)
        let old = existing.map { "\(Self.text($0.size)) source=\($0.provenance.rawValue)" } ?? "none"
        guard isUsable(updated) else {
            hyprLog(.debug, .lifecycle, "min-size record: wid=\(window.windowID) "
                    + "old=\(old) target=\(Self.text(target)) actual=\(Self.text(actual)) "
                    + "axis=\(axis) phase=\(phase.rawValue) source=readback refused=unusable")
            return false
        }
        let entry = Entry(size: updated, provenance: .observed)
        known[window.windowID] = entry
        mirror(entry, onto: window)
        if sharedWithApp { rememberAppHint(for: window, entry.size) }
        hyprLog(.debug, .lifecycle, "min-size record: wid=\(window.windowID) "
                + "old=\(old) new=\(Self.text(updated)) target=\(Self.text(target)) "
                + "actual=\(Self.text(actual)) axis=\(axis) phase=\(phase.rawValue) "
                + "source=readback" + (sharedWithApp ? "" : " shared=false"))
        return true
    }

    /// An accepted readback at least `lowerMinSizeAcceptedDeltaPx` smaller than
    /// the recorded bound unlocks a new (lower) bound. without this, a
    /// previously-recorded high mark would never relax even after the app
    /// learns to shrink (e.g., after a window-mode toggle in Xcode).
    ///
    /// Lowering relaxes an estimate, it does not establish a constraint, so
    /// the entry keeps the provenance it had. An accepted size equal to the
    /// bound changes nothing: a window that only ever fits its whole slot
    /// accepts its whole slot, which is not evidence it can be smaller.
    func lowerIfAccepted(_ window: HyprWindow, actual: CGSize) {
        guard let existing = known[window.windowID] else { return }
        // a size this app's window took is evidence about the app, not just
        // about the window. a seeded guess is nobody's evidence.
        if existing.provenance != .seeded { lowerAppHint(for: window, accepted: actual) }
        let knownSize = existing.size
        guard actual.width < knownSize.width - TilingConfig.lowerMinSizeAcceptedDeltaPx
            || actual.height < knownSize.height - TilingConfig.lowerMinSizeAcceptedDeltaPx else { return }
        let updated = CGSize(width: min(knownSize.width, actual.width),
                             height: min(knownSize.height, actual.height))
        let axis = FrameReadbackPoller.axis(width: updated.width < knownSize.width,
                                            height: updated.height < knownSize.height)
        if isUsable(updated) {
            let entry = Entry(size: updated, provenance: existing.provenance)
            known[window.windowID] = entry
            mirror(entry, onto: window)
            hyprLog(.debug, .lifecycle, "min-size lower: wid=\(window.windowID) "
                    + "old=\(Self.text(knownSize)) new=\(Self.text(updated)) "
                    + "actual=\(Self.text(actual)) axis=\(axis) "
                    + "source=accepted was=\(existing.provenance.rawValue)")
        } else {
            known.removeValue(forKey: window.windowID)
            window.observedMinSize = nil
            window.minSizeProvenance = .seeded
            hyprLog(.debug, .lifecycle, "min-size lower: wid=\(window.windowID) "
                    + "old=\(Self.text(knownSize)) new=none "
                    + "actual=\(Self.text(actual)) axis=\(axis) "
                    + "source=accepted was=\(existing.provenance.rawValue)")
        }
    }

    /// The window has been measured under a pass that set its app's hint
    /// aside, and it took `accepted`. Another window's evidence is no longer
    /// the best thing known about it, so the entry becomes its own.
    ///
    /// Per axis, and never upward: acceptance is not a refusal, so an axis
    /// the hint said nothing about stays unknown and one it did say
    /// something about comes down to what this window actually took.
    func adoptOwnEvidence(_ window: HyprWindow, accepted: CGSize) {
        guard let existing = known[window.windowID], existing.provenance == .appHint else { return }
        let old = existing.size
        let updated = CGSize(width: old.width > 0 ? min(old.width, accepted.width) : 0,
                             height: old.height > 0 ? min(old.height, accepted.height) : 0)
        lowerAppHint(for: window, accepted: accepted)
        guard isUsable(updated) else {
            known.removeValue(forKey: window.windowID)
            window.observedMinSize = nil
            window.minSizeProvenance = .seeded
            return
        }
        let entry = Entry(size: updated, provenance: .observed)
        known[window.windowID] = entry
        mirror(entry, onto: window)
        hyprLog(.debug, .lifecycle, "min-size record: wid=\(window.windowID) "
                + "old=\(Self.text(old)) new=\(Self.text(updated)) "
                + "actual=\(Self.text(accepted)) source=own-measurement was=appHint")
    }

    /// Lower the owning app's hint to a size one of its windows accepted.
    ///
    /// A hint rises on refusals and falls on accepted smaller sizes: one
    /// window's floor is not the app's floor, and without this a single
    /// stubborn window would speak for every window the app ever opens.
    /// Per-axis, same delta as the per-window lowering, and an axis the
    /// accept says nothing about (zero) is left alone.
    private func lowerAppHint(for window: HyprWindow, accepted: CGSize) {
        guard let bundleID = window.bundleID, !bundleID.isEmpty,
              let existing = appHints[bundleID] else { return }
        let delta = TilingConfig.lowerMinSizeAcceptedDeltaPx
        let lowered = CGSize(
            width: accepted.width > 0 && accepted.width < existing.width - delta
                ? accepted.width : existing.width,
            height: accepted.height > 0 && accepted.height < existing.height - delta
                ? accepted.height : existing.height)
        guard lowered != existing else { return }
        if isUsable(lowered) {
            appHints[bundleID] = lowered
        } else {
            appHints.removeValue(forKey: bundleID)
        }
        hyprLog(.debug, .lifecycle, "min-size app hint: bundle=\(bundleID) "
                + "old=\(Self.text(existing)) new=\(isUsable(lowered) ? Self.text(lowered) : "none") "
                + "from=\(window.windowID) source=accepted")
    }

    /// Raise the owning app's hint to cover what this window refused.
    ///
    /// Only real evidence feeds the hint — a hint never feeds itself, so an
    /// `appHint` entry cannot ratchet the app's floor upward through window
    /// after window. Per-axis max, because one window may have refused on
    /// width and another on height.
    private func rememberAppHint(for window: HyprWindow, _ size: CGSize) {
        guard let bundleID = window.bundleID, !bundleID.isEmpty else { return }
        let existing = appHints[bundleID] ?? .zero
        let raised = CGSize(width: max(existing.width, size.width),
                            height: max(existing.height, size.height))
        guard raised != existing else { return }
        appHints[bundleID] = raised
        hyprLog(.debug, .lifecycle, "min-size app hint: bundle=\(bundleID) "
                + "old=\(existing == .zero ? "none" : Self.text(existing)) "
                + "new=\(Self.text(raised)) from=\(window.windowID)")
    }

    private func mirror(_ entry: Entry, onto window: HyprWindow) {
        window.observedMinSize = entry.size
        window.minSizeProvenance = entry.provenance
    }

    private static func text(_ size: CGSize) -> String {
        String(format: "%gx%g", Double(size.width), Double(size.height))
    }

    /// Reject NaN, infinities, fully-zero sizes, and bogus AX sentinels.
    private func isUsable(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && (size.width > 0 || size.height > 0)
            && size.width < TilingConfig.usableMinSizeMaxPx
            && size.height < TilingConfig.usableMinSizeMaxPx
    }
}
