import Cocoa

private struct TilingKey: Hashable {
    let spaceID: CGSSpaceID
    let screenID: Int

    init(space: CGSSpaceID, screen: NSScreen) {
        self.spaceID = space
        self.screenID = Int(screen.frame.origin.x * 10000 + screen.frame.origin.y)
    }
}

class TilingEngine {
    private var trees: [TilingKey: BSPTree] = [:]
    let displayManager: DisplayManager

    var gapSize: CGFloat = 8
    var outerPadding: CGFloat = 8

    // max BSP depth: 3 = eighth screen (full, half, quarter, eighth)
    // each split adds 1 depth level
    var maxDepth: Int = 3

    // minimum child dimension (px) for smart insert backtracking.
    // if splitting a leaf would create children with either dimension below this,
    // backtrack to a shallower leaf with more space.
    var minSlotDimension: CGFloat = 500

    // callback when a window can't fit (exceeds max depth)
    var onAutoFloat: ((HyprWindow) -> Void)?

    init(displayManager: DisplayManager) {
        self.displayManager = displayManager
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

    // apply layout, return windows that couldn't shrink to their allocated size
    private func applyLayout(_ layouts: [(HyprWindow, CGRect)]) -> [MinSizeConflict] {
        var conflicts: [MinSizeConflict] = []
        for (window, frame) in layouts {
            let actual = window.setFrameWithReadback(frame)
            if actual.width > frame.width + 20 || actual.height > frame.height + 20 {
                print("[HyprMac] min-size conflict: '\(window.title ?? "?")' wanted \(Int(frame.width))x\(Int(frame.height)), got \(Int(actual.width))x\(Int(actual.height))")
                conflicts.append(MinSizeConflict(window: window, allocated: frame, actual: actual.size))
            }
        }
        return conflicts
    }

    // apply layout without readback (for the second pass after ratio adjustment)
    private func applyLayoutFinal(_ layouts: [(HyprWindow, CGRect)]) {
        for (window, frame) in layouts {
            window.setFrame(frame)
        }
    }

    func tileWindows(_ windows: [HyprWindow], onSpace spaceID: CGSSpaceID) {
        var windowsByScreen: [NSScreen: [HyprWindow]] = [:]
        for window in windows {
            guard !window.isFloating else { continue }
            guard let screen = displayManager.screen(for: window) ?? displayManager.screens.first else { continue }
            windowsByScreen[screen, default: []].append(window)
        }

        var activeKeys: Set<TilingKey> = []

        for (screen, screenWindows) in windowsByScreen {
            let key = TilingKey(space: spaceID, screen: screen)
            activeKeys.insert(key)
            let t = tree(for: key)
            let rect = displayManager.cgRect(for: screen)

            let treeWindows = t.allWindows
            let currentIDs = Set(screenWindows.map { $0.windowID })
            let treeIDs = Set(treeWindows.map { $0.windowID })

            // remove gone windows
            for w in treeWindows where !currentIDs.contains(w.windowID) { t.remove(w) }

            // add new windows — smart insert backtracks to shallower leaves
            // when splitting the deepest-right would create too-small slots
            for w in screenWindows where !treeIDs.contains(w.windowID) {
                if !t.smartInsert(w, maxDepth: maxDepth, in: rect, gap: gapSize,
                                  padding: outerPadding, minSlotDimension: minSlotDimension) {
                    print("[HyprMac] max depth exceeded — auto-floating '\(w.title ?? "?")'")
                    onAutoFloat?(w)
                }
            }

            // reset ratios before layout so stale adjustments don't persist
            t.root.resetSplitRatios()

            // pass 1: layout + readback to detect min-size conflicts
            let layouts = t.layout(in: rect, gap: gapSize, padding: outerPadding)
            print("[HyprMac] tiling \(layouts.count) windows on screen \(Int(screen.frame.width))x\(Int(screen.frame.height))")
            let conflicts = applyLayout(layouts)

            if !conflicts.isEmpty {
                // pass 2: adjust split ratios and re-layout
                let mapped = conflicts.map { (window: $0.window, actual: $0.actual) }
                t.adjustForMinSizes(mapped, in: rect, gap: gapSize, padding: outerPadding)
                let adjusted = t.layout(in: rect, gap: gapSize, padding: outerPadding)
                for (window, frame) in adjusted {
                    print("[HyprMac]   '\(window.title ?? "?")' → \(frame)")
                }
                applyLayoutFinal(adjusted)
            } else {
                for (window, frame) in layouts {
                    print("[HyprMac]   '\(window.title ?? "?")' → \(frame)")
                }
            }
        }

        for (key, t) in trees where key.spaceID == spaceID {
            if !activeKeys.contains(key) && t.allWindows.isEmpty {
                trees.removeValue(forKey: key)
            }
        }
    }

    func addWindow(_ window: HyprWindow, toSpace spaceID: CGSSpaceID) {
        guard !window.isFloating else { return }
        guard let screen = displayManager.screen(for: window) ?? displayManager.screens.first else { return }
        let key = TilingKey(space: spaceID, screen: screen)
        let t = tree(for: key)
        let rect = displayManager.cgRect(for: screen)
        if !t.contains(window) {
            if !t.smartInsert(window, maxDepth: maxDepth, in: rect, gap: gapSize,
                              padding: outerPadding, minSlotDimension: minSlotDimension) {
                print("[HyprMac] max depth exceeded — auto-floating '\(window.title ?? "?")'")
                onAutoFloat?(window)
                return
            }
        }
        retile(key: key, screen: screen)
    }

    func removeWindow(_ window: HyprWindow, fromSpace spaceID: CGSSpaceID) {
        for screen in displayManager.screens {
            let key = TilingKey(space: spaceID, screen: screen)
            let t = tree(for: key)
            if t.contains(window) {
                t.remove(window)
                retile(key: key, screen: screen)
                return
            }
        }
    }

    private func retile(key: TilingKey, screen: NSScreen) {
        let t = tree(for: key)
        let rect = displayManager.cgRect(for: screen)

        t.root.resetSplitRatios()

        let layouts = t.layout(in: rect, gap: gapSize, padding: outerPadding)
        let conflicts = applyLayout(layouts)

        if !conflicts.isEmpty {
            let mapped = conflicts.map { (window: $0.window, actual: $0.actual) }
            t.adjustForMinSizes(mapped, in: rect, gap: gapSize, padding: outerPadding)
            let adjusted = t.layout(in: rect, gap: gapSize, padding: outerPadding)
            applyLayoutFinal(adjusted)
        }
    }

    func swapWindows(_ a: HyprWindow, _ b: HyprWindow, onSpace spaceID: CGSSpaceID) {
        guard let screen = displayManager.screen(for: a) ?? displayManager.screens.first else { return }
        let key = TilingKey(space: spaceID, screen: screen)
        let t = tree(for: key)
        if t.contains(a) && t.contains(b) {
            t.swap(a, b)
            retile(key: key, screen: screen)
        }
    }

    func crossSwapWindows(_ a: HyprWindow, _ b: HyprWindow) {
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

        let screenA = displayManager.screens.first { TilingKey(space: kA.spaceID, screen: $0) == kA }
        let screenB = displayManager.screens.first { TilingKey(space: kB.spaceID, screen: $0) == kB }

        if let sA = screenA { retile(key: kA, screen: sA) }
        if let sB = screenB { retile(key: kB, screen: sB) }
    }

    func toggleSplit(_ window: HyprWindow, onSpace spaceID: CGSSpaceID) {
        guard let screen = displayManager.screen(for: window) ?? displayManager.screens.first else { return }
        let key = TilingKey(space: spaceID, screen: screen)
        let t = tree(for: key)
        let rect = displayManager.cgRect(for: screen)
        t.toggleSplit(for: window, in: rect, gap: gapSize, padding: outerPadding)
        retile(key: key, screen: screen)
    }

    // check if a screen's tree has room for another window (matches smart insert logic)
    func canFitWindow(onSpace spaceID: CGSSpaceID, screen: NSScreen) -> Bool {
        let key = TilingKey(space: spaceID, screen: screen)
        let t = tree(for: key)
        if t.root.isEmpty { return true }

        let rect = displayManager.cgRect(for: screen)
        let leaves = t.root.allLeavesRightToLeft()

        // check if any leaf below maxDepth can accommodate a split
        for leaf in leaves {
            guard leaf.depth < maxDepth else { continue }
            guard let leafRect = t.rectForNode(leaf, in: rect, gap: gapSize, padding: outerPadding) else { continue }
            let dir = leaf.direction(for: leafRect)
            let childMin: CGFloat
            switch dir {
            case .horizontal:
                childMin = min((leafRect.width - gapSize) / 2, leafRect.height)
            case .vertical:
                childMin = min(leafRect.width, (leafRect.height - gapSize) / 2)
            }
            if childMin >= minSlotDimension { return true }
        }

        // fallback: any leaf below maxDepth at all (smart insert has a fallback too)
        return leaves.contains { $0.depth < maxDepth }
    }

    // force-insert a window, evicting the most recent window if tree is full.
    // returns the evicted window or nil.
    func forceInsertWindow(_ window: HyprWindow, toSpace spaceID: CGSSpaceID) -> HyprWindow? {
        guard let screen = displayManager.screen(for: window) ?? displayManager.screens.first else { return nil }
        let key = TilingKey(space: spaceID, screen: screen)
        let t = tree(for: key)
        let rect = displayManager.cgRect(for: screen)

        if t.contains(window) { return nil }

        // try smart insert
        if t.smartInsert(window, maxDepth: maxDepth, in: rect, gap: gapSize,
                         padding: outerPadding, minSlotDimension: minSlotDimension) {
            retile(key: key, screen: screen)
            return nil
        }

        // tree full — evict deepest-right (most recent) window to make room
        guard let evicted = t.deepestRightLeafWindow() else { return nil }
        t.remove(evicted)

        if t.smartInsert(window, maxDepth: maxDepth, in: rect, gap: gapSize,
                         padding: outerPadding, minSlotDimension: minSlotDimension) {
            retile(key: key, screen: screen)
            return evicted
        }

        // shouldn't happen — restore
        _ = t.insert(evicted, maxDepth: maxDepth)
        retile(key: key, screen: screen)
        return nil
    }

    func toggleFloating(_ window: HyprWindow, space spaceID: CGSSpaceID) {
        window.isFloating.toggle()
        if window.isFloating {
            removeWindow(window, fromSpace: spaceID)
        } else {
            addWindow(window, toSpace: spaceID)
        }
    }
}
