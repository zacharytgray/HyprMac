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

    var gapSize: CGFloat = 8
    var outerPadding: CGFloat = 8

    // per-screen max BSP depth overrides, keyed by NSScreen.localizedName
    var maxSplitsPerMonitor: [String: Int] = [:]
    private let defaultMaxDepth = 3

    func maxDepth(for screen: NSScreen) -> Int {
        maxSplitsPerMonitor[screen.localizedName] ?? defaultMaxDepth
    }

    // minimum child dimension (px) for smart insert backtracking
    var minSlotDimension: CGFloat = 500

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
        guard actual.width < known.width - 10 || actual.height < known.height - 10 else { return }
        let updated = CGSize(width: min(known.width, actual.width),
                             height: min(known.height, actual.height))
        if isUsableMinimumSize(updated) {
            knownMinSizes[window.windowID] = updated
            window.observedMinSize = updated
        } else {
            knownMinSizes.removeValue(forKey: window.windowID)
            window.observedMinSize = nil
        }
        hyprLog("lowered min-size for '\(window.title ?? "?")' → \(Int(updated.width))x\(Int(updated.height))")
    }

    private func isUsableMinimumSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && (size.width > 0 || size.height > 0)
            && size.width < 10000 && size.height < 10000
    }

    private func tree(for key: TilingKey) -> BSPTree {
        if let existing = trees[key] { return existing }
        let tree = BSPTree()
        trees[key] = tree
        return tree
    }

    private struct MinSizeConflict {
        let window: HyprWindow
        let allocated: CGRect
        let actual: CGSize
    }

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

    // write all frames first, then wait only as long as AX needs to settle.
    // fast windows exit after one read; suspected min-size conflicts require
    // consecutive stable readings so transient AX sizes don't inflate ratios.
    private func applyLayout(_ layouts: [(HyprWindow, CGRect)]) -> [MinSizeConflict] {
        guard !layouts.isEmpty else { return [] }

        // previous frames are only diagnostic now; conflicts come from settled
        // readings, not from matching or not matching the previous frame.
        var prev: [CGWindowID: CGRect] = [:]
        for (w, _) in layouts {
            if let cached = w.cachedFrame { prev[w.windowID] = cached }
        }

        for (window, frame) in layouts {
            window.setFrame(frame)
        }

        struct Reading {
            let window: HyprWindow
            let frame: CGRect
            var actual: CGRect
            var stableSamples: Int
            var elapsed: TimeInterval
        }

        func read(_ window: HyprWindow, target: CGRect) -> CGRect {
            let actualSize = window.size ?? target.size
            let actualPos = window.position ?? target.origin
            return CGRect(origin: actualPos, size: actualSize)
        }

        func exceeds(_ actual: CGRect, _ target: CGRect) -> Bool {
            actual.width > target.width + 20 || actual.height > target.height + 20
        }

        func undershoots(_ actual: CGRect, _ target: CGRect) -> Bool {
            actual.width < target.width - 20 || actual.height < target.height - 20
        }

        let interval: TimeInterval = 0.03
        let maxWait: TimeInterval = 0.36
        let minConflictSettle: TimeInterval = 0.24
        let stableTolerance: CGFloat = 2
        var elapsed: TimeInterval = 0
        var readings: [Reading] = []

        Thread.sleep(forTimeInterval: interval)
        elapsed += interval
        for (window, frame) in layouts {
            readings.append(Reading(window: window, frame: frame,
                                    actual: read(window, target: frame),
                                    stableSamples: 0,
                                    elapsed: elapsed))
        }

        // accepted layouts exit fast. over-target readings must settle for two
        // consecutive samples after a longer floor before they can adjust ratios.
        // under-target readings are usually a cross-screen clamp/race; reapply
        // until the destination screen accepts the requested size.
        while readings.contains(where: { exceeds($0.actual, $0.frame) || undershoots($0.actual, $0.frame) }) && elapsed < maxWait {
            Thread.sleep(forTimeInterval: interval)
            elapsed += interval

            var anyUnsettledConflict = false
            var anyUndersizedFrame = false
            for i in readings.indices {
                let next = read(readings[i].window, target: readings[i].frame)
                let stable = abs(next.width - readings[i].actual.width) <= stableTolerance
                    && abs(next.height - readings[i].actual.height) <= stableTolerance
                readings[i].actual = next
                readings[i].elapsed = elapsed
                readings[i].stableSamples = stable ? readings[i].stableSamples + 1 : 0

                if undershoots(next, readings[i].frame) {
                    readings[i].window.setFrame(readings[i].frame)
                    anyUndersizedFrame = true
                    continue
                }

                if exceeds(next, readings[i].frame),
                   elapsed < minConflictSettle || readings[i].stableSamples < 2 {
                    anyUnsettledConflict = true
                }
            }

            if !anyUnsettledConflict && !anyUndersizedFrame { break }
        }

        var conflicts: [MinSizeConflict] = []
        for r in readings {
            let widthConflict = r.actual.width > r.frame.width + 20
            let heightConflict = r.actual.height > r.frame.height + 20
            let widthUndershot = r.actual.width < r.frame.width - 20
            let heightUndershot = r.actual.height < r.frame.height - 20
            if widthConflict || heightConflict {
                let settled = r.elapsed >= minConflictSettle && r.stableSamples >= 2
                if !settled {
                    hyprLog("unsettled readback ignored: '\(r.window.title ?? "?")' wanted \(Int(r.frame.width))x\(Int(r.frame.height)), saw \(Int(r.actual.width))x\(Int(r.actual.height)) after \(Int(r.elapsed * 1000))ms")
                    r.window.cachedFrame = r.frame
                    continue
                }

                hyprLog("min-size conflict: '\(r.window.title ?? "?")' wanted \(Int(r.frame.width))x\(Int(r.frame.height)), got \(Int(r.actual.width))x\(Int(r.actual.height))")
                conflicts.append(MinSizeConflict(window: r.window, allocated: r.frame, actual: r.actual.size))
                recordObservedMinimumSize(r.window, actual: r.actual.size,
                                          widthConflict: widthConflict,
                                          heightConflict: heightConflict)
            } else if widthUndershot || heightUndershot {
                hyprLog("undersized readback: '\(r.window.title ?? "?")' wanted \(Int(r.frame.width))x\(Int(r.frame.height)), saw \(Int(r.actual.width))x\(Int(r.actual.height)) after \(Int(r.elapsed * 1000))ms")
                r.window.setFrame(r.frame)
                r.window.cachedFrame = r.frame
                continue
            } else {
                lowerMinimumSizeIfAccepted(r.window, actual: r.actual.size)
            }
            r.window.cachedFrame = r.actual

            if let previous = prev[r.window.windowID], widthConflict || heightConflict {
                let deltaW = abs(r.actual.width - previous.width)
                let deltaH = abs(r.actual.height - previous.height)
                hyprLog("readback settled in \(Int(r.elapsed * 1000))ms for '\(r.window.title ?? "?")' (delta \(Int(deltaW))x\(Int(deltaH)))")
            }
        }
        return conflicts
    }

    private func applyLayoutFinal(_ layouts: [(HyprWindow, CGRect)]) {
        for (window, frame) in layouts {
            window.setFrame(frame)
        }
    }

    private func overflowingWindows(in layouts: [(HyprWindow, CGRect)]) -> [HyprWindow] {
        layouts.compactMap { window, frame in
            let minSize = minimumSize(for: window)
            if minSize.width > frame.width + 20 || minSize.height > frame.height + 20 {
                return window
            }
            return nil
        }
    }

    private func layoutCanAccommodateKnownMinimums(_ tree: BSPTree, rect: CGRect) -> Bool {
        let initial = tree.layout(in: rect, gap: gapSize, padding: outerPadding)
        let conflicts = initial.compactMap { window, frame -> (window: HyprWindow, actual: CGSize)? in
            let minSize = minimumSize(for: window)
            if minSize.width > frame.width + 20 || minSize.height > frame.height + 20 {
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

        hyprLog("overflow after min-size adjustment — auto-floating '\(target.title ?? "?")'")
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
        if tree.root.isEmpty {
            tree.root.window = window
            return true
        }

        guard let leaf = fittingLeaf(for: window, in: tree, maxDepth: maxDepth, rect: rect) else {
            return false
        }

        leaf.insert(window)
        if let leafRect = tree.rectForNode(leaf, in: rect, gap: gapSize, padding: outerPadding) {
            hyprLog("smart insert fit at depth \(leaf.depth) (\(Int(leafRect.width))x\(Int(leafRect.height)))")
        }
        return true
    }

    private func fittingLeaf(for window: HyprWindow?, in tree: BSPTree,
                             maxDepth: Int, rect: CGRect) -> BSPNode? {
        let leaves = tree.root.allLeavesRightToLeft()
        for pass in 0...1 {
            for leaf in leaves {
                guard leaf.depth < maxDepth else { continue }
                guard let leafRect = tree.rectForNode(leaf, in: rect, gap: gapSize, padding: outerPadding) else { continue }
                let dir = leaf.direction(for: leafRect)

                if pass == 0 {
                    let (a, b) = splitRects(leafRect, dir: dir, gap: gapSize)
                    let childMin = min(min(a.width, a.height), min(b.width, b.height))
                    if childMin < minSlotDimension { continue }
                }

                let existingMin = minimumSize(for: leaf.window)
                let incomingMin = minimumSize(for: window)
                if pairFits(existingMin, incomingMin, in: leafRect, dir: dir) {
                    return leaf
                }
            }
        }
        return nil
    }

    // tile windows for a workspace on a specific screen.
    // screen is provided explicitly — don't trust window physical position (may be hidden in corner)
    func tileWindows(_ windows: [HyprWindow], onWorkspace workspace: Int, screen: NSScreen) {
        primeMinimumSizes(windows)
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        let rect = displayManager.cgRect(for: screen)

        let tileWindows = windows.filter { !$0.isFloating }
        let treeWindows = t.allWindows
        let currentIDs = Set(tileWindows.map { $0.windowID })
        let treeIDs = Set(treeWindows.map { $0.windowID })

        // remove gone windows
        let removedAny = treeWindows.contains { !currentIDs.contains($0.windowID) }
        for w in treeWindows where !currentIDs.contains(w.windowID) { t.remove(w) }

        // defensive: prune any empty/orphaned nodes that shouldn't exist
        t.root.pruneEmptyNodes()

        // rebuild tree so backtracked windows settle into freed slots
        if removedAny {
            t.compact(maxDepth: maxDepth(for: screen), in: rect, gap: gapSize,
                      padding: outerPadding, minSlotDimension: minSlotDimension)
        }

        // add new windows via smart insert
        var insertedWindows: [HyprWindow] = []
        for w in tileWindows where !treeIDs.contains(w.windowID) {
            if !smartInsertFitting(w, into: t, maxDepth: maxDepth(for: screen), rect: rect) {
                hyprLog("no fitting tile slot — auto-floating '\(w.title ?? "?")'")
                onAutoFloat?(w)
            } else {
                insertedWindows.append(w)
            }
        }

        // structural change — clear user-set ratios so layout resets to even splits
        if removedAny || !insertedWindows.isEmpty {
            t.root.clearUserSetRatios()
        }

        t.root.resetSplitRatios()

        // pass 1: layout + readback
        let layouts = t.layout(in: rect, gap: gapSize, padding: outerPadding)
        hyprLog("tiling \(layouts.count) windows on workspace \(workspace) screen \(Int(screen.frame.width))x\(Int(screen.frame.height))")
        let conflicts = applyLayout(layouts)
        let insertedForOverflow = mergedInserted(insertedWindows, pending: consumePendingInserted(for: key, in: t))

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
                hyprLog("overflow persisted with no inserted target — discarding min-size adjustment")
                clearKnownMinimumSizes(for: overflow)
                t.root.resetSplitRatios()
                applyLayoutFinal(layouts)
                return
            }
            for (window, frame) in adjusted {
                hyprLog("  '\(window.title ?? "?")' → \(frame)")
            }
            applyLayoutFinal(adjusted)
        } else {
            for (window, frame) in layouts {
                hyprLog("  '\(window.title ?? "?")' → \(frame)")
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

    // same as tileWindows but returns layouts WITHOUT applying frames.
    // caller animates from old→new, then calls applyComputedLayout() on completion.
    func computeTileLayout(_ windows: [HyprWindow], onWorkspace workspace: Int, screen: NSScreen) -> [(HyprWindow, CGRect)] {
        primeMinimumSizes(windows)
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        let rect = displayManager.cgRect(for: screen)

        let tileWindows = windows.filter { !$0.isFloating }
        let treeWindows = t.allWindows
        let currentIDs = Set(tileWindows.map { $0.windowID })
        let treeIDs = Set(treeWindows.map { $0.windowID })

        // remove gone windows
        let removedAny = treeWindows.contains { !currentIDs.contains($0.windowID) }
        for w in treeWindows where !currentIDs.contains(w.windowID) { t.remove(w) }

        t.root.pruneEmptyNodes()

        // rebuild tree so backtracked windows settle into freed slots
        if removedAny {
            t.compact(maxDepth: maxDepth(for: screen), in: rect, gap: gapSize,
                      padding: outerPadding, minSlotDimension: minSlotDimension)
        }

        // add new windows via smart insert
        var addedAny = false
        var insertedWindows: [HyprWindow] = []
        for w in tileWindows where !treeIDs.contains(w.windowID) {
            if !smartInsertFitting(w, into: t, maxDepth: maxDepth(for: screen), rect: rect) {
                onAutoFloat?(w)
            } else {
                addedAny = true
                insertedWindows.append(w)
            }
        }

        rememberPendingInserted(insertedWindows, for: key)

        if removedAny || addedAny {
            t.root.clearUserSetRatios()
        }

        t.root.resetSplitRatios()
        return t.layout(in: rect, gap: gapSize, padding: outerPadding)
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
                hyprLog("no fitting tile slot — auto-floating '\(window.title ?? "?")'")
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
                hyprLog("overflow persisted with no inserted target — discarding min-size adjustment")
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

    // swap in the tree and return target layouts WITHOUT applying frames.
    // caller is responsible for animating or applying the result.
    func computeSwapLayout(_ a: HyprWindow, _ b: HyprWindow,
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

    // apply layouts that were previously computed (e.g. after animation).
    // runs the two-pass min-size resolution.
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

    // toggle split and compute new layout without applying frames (for animation)
    func computeToggleSplitLayout(_ window: HyprWindow,
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

    private func splitRects(_ rect: CGRect, dir: SplitDirection, gap: CGFloat) -> (CGRect, CGRect) {
        let halfGap = gap / 2
        switch dir {
        case .horizontal:
            let mid = rect.origin.x + rect.width * 0.5
            return (
                CGRect(x: rect.origin.x, y: rect.origin.y,
                       width: mid - rect.origin.x - halfGap, height: rect.height),
                CGRect(x: mid + halfGap, y: rect.origin.y,
                       width: rect.maxX - mid - halfGap, height: rect.height)
            )
        case .vertical:
            let mid = rect.origin.y + rect.height * 0.5
            return (
                CGRect(x: rect.origin.x, y: rect.origin.y,
                       width: rect.width, height: mid - rect.origin.y - halfGap),
                CGRect(x: rect.origin.x, y: mid + halfGap,
                       width: rect.width, height: rect.maxY - mid - halfGap)
            )
        }
    }

    private func pairFits(_ aMin: CGSize, _ bMin: CGSize,
                          in parentRect: CGRect, dir: SplitDirection) -> Bool {
        switch dir {
        case .horizontal:
            let sumOk = aMin.width + bMin.width + gapSize <= parentRect.width + 1
            let aCross = aMin.height <= parentRect.height + 1
            let bCross = bMin.height <= parentRect.height + 1
            let aInd = aMin.width <= parentRect.width * 0.85 + 1
            let bInd = bMin.width <= parentRect.width * 0.85 + 1
            return sumOk && aCross && bCross && aInd && bInd
        case .vertical:
            let sumOk = aMin.height + bMin.height + gapSize <= parentRect.height + 1
            let aCross = aMin.width <= parentRect.width + 1
            let bCross = bMin.width <= parentRect.width + 1
            let aInd = aMin.height <= parentRect.height * 0.85 + 1
            let bInd = bMin.height <= parentRect.height * 0.85 + 1
            return sumOk && aCross && bCross && aInd && bInd
        }
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
