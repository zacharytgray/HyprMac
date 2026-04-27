import Cocoa

private struct TilingKey: Hashable {
    let workspace: Int
    let screenID: Int

    init(workspace: Int, screen: NSScreen) {
        self.workspace = workspace
        self.screenID = Int(screen.frame.origin.x * 10000 + screen.frame.origin.y)
    }
}

class TilingEngine {
    private var trees: [TilingKey: BSPTree] = [:]
    private var pendingInsertedWindowIDs: [TilingKey: [CGWindowID]] = [:]
    let displayManager: DisplayManager

    var gapSize: CGFloat = TilingConfig.defaultGap
    var outerPadding: CGFloat = TilingConfig.defaultOuterPadding

    // per-screen max BSP depth overrides, keyed by NSScreen.localizedName
    var maxSplitsPerMonitor: [String: Int] = [:]

    func maxDepth(for screen: NSScreen) -> Int {
        maxSplitsPerMonitor[screen.localizedName] ?? TilingConfig.defaultMaxDepth
    }

    // minimum child dimension (px) for smart insert backtracking
    var minSlotDimension: CGFloat = TilingConfig.minSlotDimension

    // callback when a window can't fit (exceeds max depth)
    var onAutoFloat: ((HyprWindow) -> Void)?

    private let minSizes = MinSizeMemory()

    init(displayManager: DisplayManager) {
        self.displayManager = displayManager
    }

    func primeMinimumSizes(_ windows: [HyprWindow]) { minSizes.prime(windows) }
    func forgetMinimumSize(windowID: CGWindowID) { minSizes.forget(windowID: windowID) }
    private func minimumSize(for window: HyprWindow?) -> CGSize { minSizes.minimumSize(for: window) }

    private func tree(for key: TilingKey) -> BSPTree {
        if let existing = trees[key] { return existing }
        let tree = BSPTree()
        trees[key] = tree
        return tree
    }

    // non-creating accessor for tests — returns the live tree if one exists for
    // (workspace, screen), nil otherwise. production callers go through tree(for:).
    internal func existingTree(forWorkspace workspace: Int, screen: NSScreen) -> BSPTree? {
        trees[TilingKey(workspace: workspace, screen: screen)]
    }

    /// Reconcile `trees` with the current monitor topology.
    ///
    /// When a screen is disconnected (e.g., laptop lid close, dock unplug), every
    /// `(workspace, screen)` tree keyed to the vanished screen must either move
    /// to the workspace's new home screen or be pruned. Without this, vanished
    /// trees linger forever, leaking memory and producing stale layouts when the
    /// monitor reconnects with the same physical position.
    ///
    /// - Parameters:
    ///   - currentScreens: the live screens (after `DisplayManager.refresh()`).
    ///   - homeScreenForWorkspace: closure that returns a workspace's current
    ///     home screen, or nil if the workspace has no live home. Caller is
    ///     responsible for running `WorkspaceManager.initializeMonitors()`
    ///     **before** calling this — otherwise the home-screen map is stale and
    ///     migrations target vanished destinations.
    ///
    /// - Note: TilingKey currently keys on screen-origin coordinates. If two
    ///   monitors swap positions during a reconnect, trees follow the position,
    ///   not the physical display. Migrating to `displayID` keying is a future
    ///   change (see plan §4.2 — deferred for risk reasons).
    func handleDisplayChange(currentScreens: [NSScreen],
                             homeScreenForWorkspace: (Int) -> NSScreen?) {
        let currentKeys = Set(currentScreens.map { TilingKey(workspace: 0, screen: $0).screenID })

        var migrations: [(old: TilingKey, dest: NSScreen)] = []
        var orphans: [TilingKey] = []

        for key in trees.keys {
            if currentKeys.contains(key.screenID) { continue }
            if let dest = homeScreenForWorkspace(key.workspace) {
                migrations.append((key, dest))
            } else {
                orphans.append(key)
            }
        }

        for (oldKey, newScreen) in migrations {
            guard let tree = trees.removeValue(forKey: oldKey) else { continue }
            let newKey = TilingKey(workspace: oldKey.workspace, screen: newScreen)
            // a tree may already exist on the destination if the workspace had
            // been visited there before. prefer the larger one — it's most
            // likely the active one the user expects to keep.
            if let existing = trees[newKey], existing.allWindows.count >= tree.allWindows.count {
                hyprLog(.debug, .lifecycle, "display change: kept existing tree for ws \(oldKey.workspace) on dest screen, dropped vanished tree (\(tree.allWindows.count) windows)")
                continue
            }
            trees[newKey] = tree
            hyprLog(.debug, .lifecycle, "display change: migrated tree for ws \(oldKey.workspace) (\(tree.allWindows.count) windows)")
        }

        for key in orphans {
            let count = trees[key]?.allWindows.count ?? 0
            trees.removeValue(forKey: key)
            hyprLog(.debug, .lifecycle, "display change: pruned orphaned tree for ws \(key.workspace) (\(count) windows)")
        }
    }

    private var layoutEngine: LayoutEngine {
        LayoutEngine(gapSize: gapSize, outerPadding: outerPadding,
                     minSlotDimension: minSlotDimension)
    }

    private let readbackPoller = FrameReadbackPoller()

    // delegate to FrameReadbackPoller and reconcile its result against our
    // min-size memory. returns the conflicts the engine should pass into
    // BSPTree.adjustForMinSizes.
    private func applyLayout(_ layouts: [(HyprWindow, CGRect)]) -> [FrameReadbackPoller.Conflict] {
        let result = readbackPoller.applyLayout(layouts)
        for obs in result.observations {
            minSizes.recordObserved(obs.window, actual: obs.actual,
                                    widthConflict: obs.widthConflict,
                                    heightConflict: obs.heightConflict)
        }
        for (window, size) in result.accepted {
            minSizes.lowerIfAccepted(window, actual: size)
        }
        return result.conflicts
    }

    private func applyLayoutFinal(_ layouts: [(HyprWindow, CGRect)]) {
        readbackPoller.applyFinal(layouts)
    }

    private func overflowingWindows(in layouts: [(HyprWindow, CGRect)]) -> [HyprWindow] {
        layouts.compactMap { window, frame in
            let minSize = minimumSize(for: window)
            if minSize.width > frame.width + TilingConfig.frameToleranceXPx || minSize.height > frame.height + TilingConfig.frameToleranceXPx {
                return window
            }
            return nil
        }
    }

    private func layoutCanAccommodateKnownMinimums(_ tree: BSPTree, rect: CGRect) -> Bool {
        let initial = tree.layout(in: rect, gap: gapSize, padding: outerPadding)
        let conflicts = initial.compactMap { window, frame -> (window: HyprWindow, actual: CGSize)? in
            let minSize = minimumSize(for: window)
            if minSize.width > frame.width + TilingConfig.frameToleranceXPx || minSize.height > frame.height + TilingConfig.frameToleranceXPx {
                return (window: window, actual: minSize)
            }
            return nil
        }

        guard !conflicts.isEmpty else { return true }

        tree.adjustForMinSizes(conflicts, in: rect, gap: gapSize, padding: outerPadding)
        let adjusted = tree.layout(in: rect, gap: gapSize, padding: outerPadding)
        return overflowingWindows(in: adjusted).isEmpty
    }

    private func autoFloatOverflow(_ overflow: [HyprWindow],
                                   inserted: [HyprWindow],
                                   tree: BSPTree,
                                   key: TilingKey,
                                   screen: NSScreen) -> Bool {
        guard !overflow.isEmpty, !inserted.isEmpty else { return false }
        let overflowIDs = Set(overflow.map { $0.windowID })
        let target = inserted.reversed().first { overflowIDs.contains($0.windowID) }
            ?? inserted.last
        guard let target else { return false }

        hyprLog(.debug, .lifecycle, "overflow after min-size adjustment — auto-floating '\(target.title ?? "?")'")
        tree.remove(target)
        tree.root.pruneEmptyNodes()
        onAutoFloat?(target)
        retile(key: key, screen: screen)
        return true
    }

    private func rememberPendingInserted(_ windows: [HyprWindow], for key: TilingKey) {
        guard !windows.isEmpty else { return }
        pendingInsertedWindowIDs[key, default: []].append(contentsOf: windows.map(\.windowID))
    }

    private func consumePendingInserted(for key: TilingKey, in tree: BSPTree) -> [HyprWindow] {
        guard let ids = pendingInsertedWindowIDs.removeValue(forKey: key), !ids.isEmpty else { return [] }
        let windowsByID = Dictionary(uniqueKeysWithValues: tree.allWindows.map { ($0.windowID, $0) })
        return ids.compactMap { windowsByID[$0] }
    }

    private func mergedInserted(_ inserted: [HyprWindow], pending: [HyprWindow]) -> [HyprWindow] {
        var seen: Set<CGWindowID> = []
        var result: [HyprWindow] = []
        for window in inserted + pending where !seen.contains(window.windowID) {
            seen.insert(window.windowID)
            result.append(window)
        }
        return result
    }


    @discardableResult
    private func smartInsertFitting(_ window: HyprWindow, into tree: BSPTree,
                                    maxDepth: Int, rect: CGRect) -> Bool {
        layoutEngine.smartInsertFitting(window, into: tree, maxDepth: maxDepth,
                                        rect: rect, minimumSize: minimumSize(for:))
    }

    private func fittingLeaf(for window: HyprWindow?, in tree: BSPTree,
                             maxDepth: Int, rect: CGRect) -> BSPNode? {
        layoutEngine.fittingLeaf(for: window, in: tree, maxDepth: maxDepth,
                                 rect: rect, minimumSize: minimumSize(for:))
    }

    private struct TileMembershipResult {
        let key: TilingKey
        let tree: BSPTree
        let rect: CGRect
        let insertedWindows: [HyprWindow]
    }

    // shared tree-update path between tileWindows and prepareTileLayout.
    // primes min-sizes, removes gone windows (compacting if any vanished),
    // smart-inserts new windows (auto-floating those that don't fit),
    // clears userSetRatios on structural change, and resets split ratios.
    // pure with respect to AX — only mutates the tree and engine state.
    private func updateTreeMembership(_ windows: [HyprWindow],
                                      onWorkspace workspace: Int,
                                      screen: NSScreen) -> TileMembershipResult {
        primeMinimumSizes(windows)
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        let rect = displayManager.cgRect(for: screen)

        let tileWindows = windows.filter { !$0.isFloating }
        let treeWindows = t.allWindows
        let currentIDs = Set(tileWindows.map { $0.windowID })
        let treeIDs = Set(treeWindows.map { $0.windowID })

        let removedAny = treeWindows.contains { !currentIDs.contains($0.windowID) }
        for w in treeWindows where !currentIDs.contains(w.windowID) { t.remove(w) }

        t.root.pruneEmptyNodes()

        if removedAny {
            t.compact(maxDepth: maxDepth(for: screen), in: rect, gap: gapSize,
                      padding: outerPadding, minSlotDimension: minSlotDimension)
        }

        var insertedWindows: [HyprWindow] = []
        for w in tileWindows where !treeIDs.contains(w.windowID) {
            if !smartInsertFitting(w, into: t, maxDepth: maxDepth(for: screen), rect: rect) {
                hyprLog(.debug, .lifecycle, "no fitting tile slot — auto-floating '\(w.title ?? "?")'")
                onAutoFloat?(w)
            } else {
                insertedWindows.append(w)
            }
        }

        if removedAny || !insertedWindows.isEmpty {
            t.root.clearUserSetRatios()
        }

        t.root.resetSplitRatios()
        return TileMembershipResult(key: key, tree: t, rect: rect, insertedWindows: insertedWindows)
    }

    // tile windows for a workspace on a specific screen.
    // screen is provided explicitly — don't trust window physical position (may be hidden in corner)
    func tileWindows(_ windows: [HyprWindow], onWorkspace workspace: Int, screen: NSScreen) {
        let m = updateTreeMembership(windows, onWorkspace: workspace, screen: screen)
        let key = m.key
        let t = m.tree
        let rect = m.rect

        // pass 1: layout + readback
        let layouts = t.layout(in: rect, gap: gapSize, padding: outerPadding)
        hyprLog(.debug, .lifecycle, "tiling \(layouts.count) windows on workspace \(workspace) screen \(Int(screen.frame.width))x\(Int(screen.frame.height))")
        let conflicts = applyLayout(layouts)
        let insertedForOverflow = mergedInserted(m.insertedWindows, pending: consumePendingInserted(for: key, in: t))

        if !conflicts.isEmpty {
            // pass 2: adjust ratios and re-layout
            let mapped = conflicts.map { (window: $0.window, actual: $0.actual) }
            t.adjustForMinSizes(mapped, in: rect, gap: gapSize, padding: outerPadding)
            let adjusted = t.layout(in: rect, gap: gapSize, padding: outerPadding)
            let overflow = overflowingWindows(in: adjusted)
            if autoFloatOverflow(overflow, inserted: insertedForOverflow,
                                 tree: t, key: key, screen: screen) {
                return
            }
            if !overflow.isEmpty {
                hyprLog(.debug, .lifecycle, "overflow persisted with no inserted target — discarding min-size adjustment")
                minSizes.clear(for: overflow)
                t.root.resetSplitRatios()
                applyLayoutFinal(layouts)
                return
            }
            for (window, frame) in adjusted {
                hyprLog(.debug, .lifecycle, "  '\(window.title ?? "?")' → \(frame)")
            }
            applyLayoutFinal(adjusted)
        } else {
            for (window, frame) in layouts {
                hyprLog(.debug, .lifecycle, "  '\(window.title ?? "?")' → \(frame)")
            }
        }

        // clean up empty trees for this workspace on other screens
        for (key, t) in trees where key.workspace == workspace {
            if !t.allWindows.isEmpty { continue }
            if TilingKey(workspace: workspace, screen: screen) != key {
                trees.removeValue(forKey: key)
            }
        }
    }

    /// Mutate the (workspace, screen) tree to reflect `windows` and return
    /// the resulting per-window layout rects WITHOUT applying frames.
    ///
    /// - Important: This call **mutates the tree** before returning — windows
    ///   missing from the input are removed (with `compact`), new windows are
    ///   added via `smartInsertFitting`, structural-change ratio flags are
    ///   cleared, and `resetSplitRatios` is run. The caller is committed to
    ///   either applying the returned layout (via `applyComputedLayout`) or
    ///   accepting that the tree is now in its post-tile state regardless of
    ///   what the caller does with the returned rects. This is intentional —
    ///   animation paths need post-mutation geometry to interpolate toward.
    /// - Returns: `[(window, frame)]` pairs in tree iteration order. Empty
    ///   array if the tree ends up empty.
    func prepareTileLayout(_ windows: [HyprWindow], onWorkspace workspace: Int, screen: NSScreen) -> [(HyprWindow, CGRect)] {
        let m = updateTreeMembership(windows, onWorkspace: workspace, screen: screen)
        rememberPendingInserted(m.insertedWindows, for: m.key)
        return m.tree.layout(in: m.rect, gap: gapSize, padding: outerPadding)
    }

    // add a single window to the tree for its workspace+screen and retile
    func addWindow(_ window: HyprWindow, toWorkspace workspace: Int, on screen: NSScreen) {
        guard !window.isFloating else { return }
        primeMinimumSizes([window])
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        let rect = displayManager.cgRect(for: screen)
        var inserted: [HyprWindow] = []
        if !t.contains(window) {
            if !smartInsertFitting(window, into: t, maxDepth: maxDepth(for: screen), rect: rect) {
                hyprLog(.debug, .lifecycle, "no fitting tile slot — auto-floating '\(window.title ?? "?")'")
                onAutoFloat?(window)
                return
            }
            inserted.append(window)
        }
        retile(key: key, screen: screen, inserted: inserted)
    }

    func removeWindow(_ window: HyprWindow, fromWorkspace workspace: Int) {
        // search all trees for this workspace
        for (key, t) in trees where key.workspace == workspace {
            if t.contains(window) {
                t.remove(window)
                t.root.pruneEmptyNodes()
                if let screen = displayManager.screens.first(where: {
                    TilingKey(workspace: workspace, screen: $0) == key
                }) {
                    let rect = displayManager.cgRect(for: screen)
                    t.compact(maxDepth: maxDepth(for: screen), in: rect, gap: gapSize,
                              padding: outerPadding, minSlotDimension: minSlotDimension)
                    retile(key: key, screen: screen)
                }
                return
            }
        }
    }

    // preserveMinSizesOnOverflow:
    //   true  → swap-rejection callers (swapWindows + applyComputedLayout's
    //           animated swap revert) need the readback-confirmed mins to
    //           survive past this retile so their post-retile fit check sees
    //           the real bound and can reject the swap.
    //   false → all other callers want the pre-0f24775 behavior. preserving
    //           mins here ratchets every visible app's recorded minimum up to
    //           whatever-it-couldn't-shrink-to-this-attempt and keeps it
    //           sticky. forceInsertWindow's smart-insert pre-check then
    //           reads those bumped values via pairFits and false-rejects
    //           legitimate slots, dropping forceInsertWindow into its
    //           eviction fallback — which is supposed to fire only when the
    //           tree is full. user-observed bug: Caps+Shift+T on a floating
    //           window kicks an existing tile out instead of slotting in.
    private func retile(key: TilingKey, screen: NSScreen,
                        inserted: [HyprWindow] = [],
                        preserveMinSizesOnOverflow: Bool = false) {
        let t = tree(for: key)
        primeMinimumSizes(t.allWindows)
        let rect = displayManager.cgRect(for: screen)
        let insertedForOverflow = mergedInserted(inserted, pending: consumePendingInserted(for: key, in: t))

        t.root.resetSplitRatios()

        let layouts = t.layout(in: rect, gap: gapSize, padding: outerPadding)
        let conflicts = applyLayout(layouts)

        if !conflicts.isEmpty {
            let mapped = conflicts.map { (window: $0.window, actual: $0.actual) }
            t.adjustForMinSizes(mapped, in: rect, gap: gapSize, padding: outerPadding)
            let adjusted = t.layout(in: rect, gap: gapSize, padding: outerPadding)
            let overflow = overflowingWindows(in: adjusted)
            if autoFloatOverflow(overflow, inserted: insertedForOverflow,
                                 tree: t, key: key, screen: screen) {
                return
            }
            if !overflow.isEmpty {
                if preserveMinSizesOnOverflow {
                    hyprLog(.debug, .lifecycle, "overflow persisted with no inserted target — preserving recorded min sizes for caller's post-retile fit check")
                } else {
                    hyprLog(.debug, .lifecycle, "overflow persisted with no inserted target — discarding min-size adjustment")
                    minSizes.clear(for: overflow)
                }
                t.root.resetSplitRatios()
                applyLayoutFinal(layouts)
                return
            }
            applyLayoutFinal(adjusted)
        }
    }

    // apply a manual resize: update split ratios from the new frame, then retile
    func applyResize(_ window: HyprWindow, newFrame: CGRect, onWorkspace workspace: Int, screen: NSScreen) {
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        let rect = displayManager.cgRect(for: screen)

        t.applyResizeDelta(for: window, newFrame: newFrame, in: rect, gap: gapSize, padding: outerPadding)
        retile(key: key, screen: screen)
    }

    func canSwapWindows(_ a: HyprWindow, _ b: HyprWindow,
                        onWorkspace workspace: Int, screen: NSScreen) -> Bool {
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        // prime ALL tree windows, not just [a, b]. siblings still influence
        // whether adjustForMinSizes can resolve conflicts post-swap; if their
        // min sizes are stale or missing in the memory, the fit check produces
        // inconsistent rejections (e.g., a swap that should reject when a
        // sibling has a hard minimum sneaks through because its min wasn't
        // re-synced).
        primeMinimumSizes(t.allWindows)
        guard t.contains(a) && t.contains(b) else { return false }

        let snapshot = t.snapshot()
        defer { t.restore(snapshot) }

        let rect = displayManager.cgRect(for: screen)
        t.swap(a, b)
        // clear userSetRatio + reset to 50/50 for the test layout. matches
        // what the actual swap does below, so canSwapWindows and the
        // post-acceptance retile evaluate against the same baseline. without
        // this, a previously user-resized split that favored Spotify's old
        // slot biases the test in favor of *whatever lands in that slot
        // post-swap*, masking conflicts that the actual retile would hit.
        t.root.clearUserSetRatios()
        t.root.resetSplitRatios()
        return layoutCanAccommodateKnownMinimums(t, rect: rect)
    }

    @discardableResult
    func swapWindows(_ a: HyprWindow, _ b: HyprWindow, onWorkspace workspace: Int, screen: NSScreen) -> Bool {
        guard canSwapWindows(a, b, onWorkspace: workspace, screen: screen) else { return false }
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)

        // canSwapWindows uses the recorded min sizes which can be seeded
        // (AX-static) rather than confirmed via readback. for windows like
        // Spotify whose actual min depends on current UI state, the seeded
        // values can be too small — canSwapWindows accepts, but the real
        // pass-1 readback after the swap reveals overflow. snapshot the
        // tree first so we can revert on that case.
        let snapshot = t.snapshot()
        t.swap(a, b)
        // see canSwapWindows — swap is a structural change, prior manual
        // ratios applied to the OLD occupant of a slot, not the new one.
        t.root.clearUserSetRatios()
        // preserveMinSizesOnOverflow: the post-retile check below reads
        // minimumSize against the retile's freshly-recorded mins. if retile
        // cleared them on the no-inserted-target overflow branch, the
        // post-retile check would false-pass.
        retile(key: key, screen: screen, preserveMinSizesOnOverflow: true)

        // post-retile fit check: minSizes was updated by pass-1 readback
        // during retile. if the resulting layout still overflows the
        // freshly-recorded mins, the swap doesn't actually fit — revert.
        let rect = displayManager.cgRect(for: screen)
        let postLayout = t.layout(in: rect, gap: gapSize, padding: outerPadding)
        if !overflowingWindows(in: postLayout).isEmpty {
            hyprLog(.debug, .lifecycle, "swap overflow detected post-readback — reverting")
            t.restore(snapshot)
            retile(key: key, screen: screen)
            return false
        }
        return true
    }

    /// Pending pre-swap snapshot for the animated swap path. Set by
    /// `prepareSwapLayout`, consumed (or cleared) by `applyComputedLayout`.
    /// Defensively cleared by `prepareToggleSplitLayout` to prevent leakage
    /// across consecutive prepare-then-apply cycles when the user triggers
    /// a non-swap action between the two halves.
    private var pendingSwapRevert: (key: TilingKey, snapshot: BSPTree.Snapshot)?

    /// Swap two windows' positions in the tree and return post-swap layout
    /// rects without applying frames.
    ///
    /// - Important: **Mutates the tree** before returning — `BSPTree.swap`
    ///   exchanges leaf window references and `resetSplitRatios` runs. If the
    ///   caller does nothing with the returned layout, the tree is still in
    ///   its post-swap state. Captures a pre-swap snapshot for revert; the
    ///   matching `applyComputedLayout` call consumes it.
    /// - Returns: `nil` if either window is missing from the tree or the
    ///   pair fails the cross-axis fit check; otherwise the new layout.
    func prepareSwapLayout(_ a: HyprWindow, _ b: HyprWindow,
                           onWorkspace workspace: Int, screen: NSScreen) -> [(HyprWindow, CGRect)]? {
        guard canSwapWindows(a, b, onWorkspace: workspace, screen: screen) else { return nil }
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        guard t.contains(a) && t.contains(b) else { return nil }
        let rect = displayManager.cgRect(for: screen)

        // capture snapshot for post-readback overflow revert (animated swap
        // path). canSwapWindows uses the recorded min size which can be
        // seeded rather than confirmed via readback — for windows like
        // Spotify whose actual min depends on UI state, the seed lies and
        // canSwapWindows false-accepts. The real readback during retile
        // (triggered by applyComputedLayout) is the ground truth, and
        // applyComputedLayout reverts via this snapshot if overflow persists.
        pendingSwapRevert = (key: key, snapshot: t.snapshot())
        t.swap(a, b)
        // clear userSetRatio + reset to 50/50 so the test layout matches
        // canSwapWindows's evaluation baseline (see canSwapWindows).
        t.root.clearUserSetRatios()
        t.root.resetSplitRatios()
        return t.layout(in: rect, gap: gapSize, padding: outerPadding)
    }

    /// Re-apply the current tree state to AX frames using the two-pass
    /// min-size resolution. Pairs with `prepare*Layout`: caller mutates the
    /// tree (via prepare), drives an animation against the returned rects,
    /// then calls `applyComputedLayout` on completion to settle frames.
    ///
    /// If the prepare call was `prepareSwapLayout` (which captures a
    /// pre-swap snapshot), the post-retile layout is checked for overflow
    /// against the freshly-recorded min sizes; on overflow the snapshot is
    /// restored and a clean retile applied. Returns `false` in that case so
    /// the caller can `flashError`. For non-swap callers (toggleSplit etc.)
    /// the return is always `true`.
    @discardableResult
    func applyComputedLayout(onWorkspace workspace: Int, screen: NSScreen) -> Bool {
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        // when a swap is pending, the post-retile fit check below relies on
        // freshly-recorded mins surviving past retile (same contract as
        // swapWindows above). otherwise — toggleSplit, animated retile from
        // tileAllVisibleSpaces, etc. — fall through to the default which
        // matches forceInsertWindow's expectations.
        let preserve = (pendingSwapRevert?.key == key)
        retile(key: key, screen: screen, preserveMinSizesOnOverflow: preserve)

        // consume any pending swap snapshot for this key. only the swap
        // path sets this — toggleSplit etc. leave it nil.
        guard let pending = pendingSwapRevert, pending.key == key else { return true }
        pendingSwapRevert = nil

        let rect = displayManager.cgRect(for: screen)
        let postLayout = t.layout(in: rect, gap: gapSize, padding: outerPadding)
        if !overflowingWindows(in: postLayout).isEmpty {
            hyprLog(.debug, .lifecycle, "animated swap overflow detected post-readback — reverting")
            t.restore(pending.snapshot)
            retile(key: key, screen: screen)
            return false
        }
        return true
    }

    func crossSwapWindows(_ a: HyprWindow, _ b: HyprWindow) {
        primeMinimumSizes([a, b])
        var keyA: TilingKey?
        var keyB: TilingKey?
        var treeA: BSPTree?
        var treeB: BSPTree?

        for (key, t) in trees {
            if t.contains(a) { keyA = key; treeA = t }
            if t.contains(b) { keyB = key; treeB = t }
        }

        guard let kA = keyA, let kB = keyB, let tA = treeA, let tB = treeB else { return }

        if let nodeA = tA.root.find(a) { nodeA.window = b }
        if let nodeB = tB.root.find(b) { nodeB.window = a }

        let screenA = displayManager.screens.first { TilingKey(workspace: kA.workspace, screen: $0) == kA }
        let screenB = displayManager.screens.first { TilingKey(workspace: kB.workspace, screen: $0) == kB }

        if let sA = screenA { retile(key: kA, screen: sA) }
        if let sB = screenB { retile(key: kB, screen: sB) }
    }

    func toggleSplit(_ window: HyprWindow, onWorkspace workspace: Int, screen: NSScreen) {
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        let rect = displayManager.cgRect(for: screen)
        t.toggleSplit(for: window, in: rect, gap: gapSize, padding: outerPadding)
        retile(key: key, screen: screen)
    }

    /// Toggle the split direction of `window`'s parent and return post-toggle
    /// layout rects without applying frames.
    ///
    /// - Important: **Mutates the tree** before returning. `splitOverride`
    ///   flips on the parent and `resetSplitRatios` runs. Calling this twice
    ///   in succession reverts the toggle — that footgun is exactly what the
    ///   `WindowManager.toggleSplit()` fallthrough fix prevents (see plan
    ///   §4.2 + commit ee9e2df).
    /// - Returns: `nil` if `window` isn't in the tree (no toggle performed);
    ///   otherwise the post-toggle layout.
    func prepareToggleSplitLayout(_ window: HyprWindow,
                                  onWorkspace workspace: Int, screen: NSScreen) -> [(HyprWindow, CGRect)]? {
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        guard t.contains(window) else { return nil }
        // defensive: clear any stale pending swap snapshot so the next
        // applyComputedLayout doesn't try to revert this toggleSplit.
        pendingSwapRevert = nil
        let rect = displayManager.cgRect(for: screen)
        t.toggleSplit(for: window, in: rect, gap: gapSize, padding: outerPadding)
        t.root.resetSplitRatios()
        return t.layout(in: rect, gap: gapSize, padding: outerPadding)
    }

    func canFitWindow(_ window: HyprWindow? = nil,
                      onWorkspace workspace: Int,
                      screen: NSScreen) -> Bool {
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        if t.root.isEmpty { return true }
        // prime tree tenants AND incoming window — pairFits reads
        // minimumSize for both leaf occupant and incoming, so both must be
        // synced against the latest known/observed values.
        var toPrime = t.allWindows
        if let window { toPrime.append(window) }
        primeMinimumSizes(toPrime)

        let rect = displayManager.cgRect(for: screen)
        return fittingLeaf(for: window,
                           in: t,
                           maxDepth: maxDepth(for: screen),
                           rect: rect) != nil
    }

    // force-insert a window on an explicit screen, evicting deepest-right if full
    func forceInsertWindow(_ window: HyprWindow, toWorkspace workspace: Int, on screen: NSScreen) -> HyprWindow? {
        primeMinimumSizes([window])
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        let rect = displayManager.cgRect(for: screen)

        if t.contains(window) { return nil }

        if smartInsertFitting(window, into: t, maxDepth: maxDepth(for: screen), rect: rect) {
            retile(key: key, screen: screen, inserted: [window])
            return nil
        }

        guard let evicted = t.deepestRightLeafWindow() else { return nil }
        t.remove(evicted)

        if smartInsertFitting(window, into: t, maxDepth: maxDepth(for: screen), rect: rect) {
            retile(key: key, screen: screen, inserted: [window])
            return evicted
        }

        _ = t.insert(evicted, maxDepth: maxDepth(for: screen))
        retile(key: key, screen: screen)
        return nil
    }
}
