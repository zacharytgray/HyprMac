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

    private var knownMinSizes: [CGWindowID: CGSize] = [:]

    init(displayManager: DisplayManager) {
        self.displayManager = displayManager
    }

    func primeMinimumSizes(_ windows: [HyprWindow]) {
        for window in windows {
            if let known = knownMinSizes[window.windowID] {
                window.observedMinSize = known
            } else if let seeded = window.observedMinSize, isUsableMinimumSize(seeded) {
                knownMinSizes[window.windowID] = seeded
            }
        }
    }

    func forgetMinimumSize(windowID: CGWindowID) {
        knownMinSizes.removeValue(forKey: windowID)
    }

    private func minimumSize(for window: HyprWindow?) -> CGSize {
        guard let window else { return .zero }
        return knownMinSizes[window.windowID] ?? window.observedMinSize ?? .zero
    }

    private func recordObservedMinimumSize(_ window: HyprWindow,
                                           actual: CGSize,
                                           widthConflict: Bool,
                                           heightConflict: Bool) {
        let existing = minimumSize(for: window)
        let updated = CGSize(
            width: widthConflict ? max(existing.width, actual.width) : existing.width,
            height: heightConflict ? max(existing.height, actual.height) : existing.height
        )
        guard isUsableMinimumSize(updated) else { return }
        knownMinSizes[window.windowID] = updated
        window.observedMinSize = updated
    }

    private func lowerMinimumSizeIfAccepted(_ window: HyprWindow, actual: CGSize) {
        guard let known = knownMinSizes[window.windowID] else { return }
        guard actual.width < known.width - TilingConfig.lowerMinSizeAcceptedDeltaPx
            || actual.height < known.height - TilingConfig.lowerMinSizeAcceptedDeltaPx else { return }
        let updated = CGSize(width: min(known.width, actual.width),
                             height: min(known.height, actual.height))
        if isUsableMinimumSize(updated) {
            knownMinSizes[window.windowID] = updated
            window.observedMinSize = updated
        } else {
            knownMinSizes.removeValue(forKey: window.windowID)
            window.observedMinSize = nil
        }
        hyprLog(.debug, .lifecycle, "lowered min-size for '\(window.title ?? "?")' → \(Int(updated.width))x\(Int(updated.height))")
    }

    private func isUsableMinimumSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && (size.width > 0 || size.height > 0)
            && size.width < TilingConfig.usableMinSizeMaxPx && size.height < TilingConfig.usableMinSizeMaxPx
    }

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

    private var layoutEngine: LayoutEngine {
        LayoutEngine(gapSize: gapSize, outerPadding: outerPadding,
                     minSlotDimension: minSlotDimension)
    }

    private let readbackPoller = FrameReadbackPoller()

    private struct NodeState {
        let node: BSPNode
        let splitRatio: CGFloat
        let userSetRatio: Bool
        let splitOverride: SplitDirection?
        let window: HyprWindow?
    }

    private func snapshotTree(_ tree: BSPTree) -> [NodeState] {
        var states: [NodeState] = []
        func walk(_ node: BSPNode) {
            states.append(NodeState(node: node,
                                    splitRatio: node.splitRatio,
                                    userSetRatio: node.userSetRatio,
                                    splitOverride: node.splitOverride,
                                    window: node.window))
            if let left = node.left { walk(left) }
            if let right = node.right { walk(right) }
        }
        walk(tree.root)
        return states
    }

    private func restoreTree(_ states: [NodeState]) {
        for state in states {
            state.node.splitRatio = state.splitRatio
            state.node.userSetRatio = state.userSetRatio
            state.node.splitOverride = state.splitOverride
            state.node.window = state.window
        }
    }

    // delegate to FrameReadbackPoller and reconcile its result against our
    // min-size memory. returns the conflicts the engine should pass into
    // BSPTree.adjustForMinSizes.
    private func applyLayout(_ layouts: [(HyprWindow, CGRect)]) -> [FrameReadbackPoller.Conflict] {
        let result = readbackPoller.applyLayout(layouts)
        for obs in result.observations {
            recordObservedMinimumSize(obs.window, actual: obs.actual,
                                      widthConflict: obs.widthConflict,
                                      heightConflict: obs.heightConflict)
        }
        for (window, size) in result.accepted {
            lowerMinimumSizeIfAccepted(window, actual: size)
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

    private func clearKnownMinimumSizes(for windows: [HyprWindow]) {
        for window in windows {
            knownMinSizes.removeValue(forKey: window.windowID)
            window.observedMinSize = nil
        }
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
                clearKnownMinimumSizes(for: overflow)
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

    private func retile(key: TilingKey, screen: NSScreen, inserted: [HyprWindow] = []) {
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
                hyprLog(.debug, .lifecycle, "overflow persisted with no inserted target — discarding min-size adjustment")
                clearKnownMinimumSizes(for: overflow)
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
        primeMinimumSizes([a, b])
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        guard t.contains(a) && t.contains(b) else { return false }

        let snapshot = snapshotTree(t)
        defer { restoreTree(snapshot) }

        let rect = displayManager.cgRect(for: screen)
        t.swap(a, b)
        t.root.resetSplitRatios()
        return layoutCanAccommodateKnownMinimums(t, rect: rect)
    }

    @discardableResult
    func swapWindows(_ a: HyprWindow, _ b: HyprWindow, onWorkspace workspace: Int, screen: NSScreen) -> Bool {
        guard canSwapWindows(a, b, onWorkspace: workspace, screen: screen) else { return false }
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        t.swap(a, b)
        retile(key: key, screen: screen)
        return true
    }

    /// Swap two windows' positions in the tree and return post-swap layout
    /// rects without applying frames.
    ///
    /// - Important: **Mutates the tree** before returning — `BSPTree.swap`
    ///   exchanges leaf window references and `resetSplitRatios` runs. If the
    ///   caller does nothing with the returned layout, the tree is still in
    ///   its post-swap state.
    /// - Returns: `nil` if either window is missing from the tree or the
    ///   pair fails the cross-axis fit check; otherwise the new layout.
    func prepareSwapLayout(_ a: HyprWindow, _ b: HyprWindow,
                           onWorkspace workspace: Int, screen: NSScreen) -> [(HyprWindow, CGRect)]? {
        guard canSwapWindows(a, b, onWorkspace: workspace, screen: screen) else { return nil }
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        guard t.contains(a) && t.contains(b) else { return nil }
        let rect = displayManager.cgRect(for: screen)

        t.swap(a, b)
        t.root.resetSplitRatios()
        return t.layout(in: rect, gap: gapSize, padding: outerPadding)
    }

    /// Re-apply the current tree state to AX frames using the two-pass
    /// min-size resolution. Pairs with `prepare*Layout`: caller mutates the
    /// tree (via prepare), drives an animation against the returned rects,
    /// then calls `applyComputedLayout` on completion to settle frames.
    func applyComputedLayout(onWorkspace workspace: Int, screen: NSScreen) {
        let key = TilingKey(workspace: workspace, screen: screen)
        retile(key: key, screen: screen)
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
        let rect = displayManager.cgRect(for: screen)
        t.toggleSplit(for: window, in: rect, gap: gapSize, padding: outerPadding)
        t.root.resetSplitRatios()
        return t.layout(in: rect, gap: gapSize, padding: outerPadding)
    }

    func canFitWindow(_ window: HyprWindow? = nil,
                      onWorkspace workspace: Int,
                      screen: NSScreen) -> Bool {
        if let window { primeMinimumSizes([window]) }
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        if t.root.isEmpty { return true }

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
