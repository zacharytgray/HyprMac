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

    // write all frames first, then wait briefly for slow apps (Electron, Spotify,
    // Teams) to actually process the AX size change before reading back.
    // without this gap, the readback returns the *previous* size, we falsely
    // flag a min-size conflict, and pass 2 inflates the slot. on the next tile
    // we reset, set the smaller size again, the app is still mid-resize, we
    // read the inflated size again, and the window stays bloated forever.
    // batching also makes one wait cover N windows instead of N waits.
    private func applyLayout(_ layouts: [(HyprWindow, CGRect)]) -> [MinSizeConflict] {
        // snapshot previous frames so we can detect stale readbacks — if a
        // window's "actual" size matches its prior frame AND exceeds target,
        // the app hasn't committed the setFrame yet (not a real min-size conflict).
        var prev: [CGWindowID: CGRect] = [:]
        for (w, _) in layouts {
            if let cached = w.cachedFrame { prev[w.windowID] = cached }
        }

        for (window, frame) in layouts {
            window.setFrame(frame)
        }
        // ~3 frames @ 60Hz — enough for slow apps to commit the resize
        Thread.sleep(forTimeInterval: 0.05)

        // first pass: read current sizes. flag anything that looks stale.
        struct Reading { let window: HyprWindow; let frame: CGRect; var actual: CGRect; var stale: Bool }
        var readings: [Reading] = []
        var anyStale = false
        for (window, frame) in layouts {
            let actualSize = window.size ?? frame.size
            let actualPos = window.position ?? frame.origin
            let actual = CGRect(origin: actualPos, size: actualSize)
            let exceeds = actual.width > frame.width + 20 || actual.height > frame.height + 20
            var stale = false
            if exceeds, let p = prev[window.windowID],
               abs(actual.width - p.width) < 5 && abs(actual.height - p.height) < 5 {
                stale = true
                anyStale = true
            }
            readings.append(Reading(window: window, frame: frame, actual: actual, stale: stale))
        }

        // stale pass: give slow apps more time, then re-read just the suspects.
        // distinguishes "app refuses to shrink" (stays at min-size, != prev if
        // prev was the target size from last tile) from "app mid-resize"
        // (still reporting prev frame). only pays the extra 100ms when needed.
        if anyStale {
            Thread.sleep(forTimeInterval: 0.1)
            for i in readings.indices where readings[i].stale {
                let w = readings[i].window
                let newSize = w.size ?? readings[i].actual.size
                let newPos = w.position ?? readings[i].actual.origin
                readings[i].actual = CGRect(origin: newPos, size: newSize)
            }
        }

        var conflicts: [MinSizeConflict] = []
        for r in readings {
            r.window.cachedFrame = r.actual
            if r.actual.width > r.frame.width + 20 || r.actual.height > r.frame.height + 20 {
                hyprLog("min-size conflict: '\(r.window.title ?? "?")' wanted \(Int(r.frame.width))x\(Int(r.frame.height)), got \(Int(r.actual.width))x\(Int(r.actual.height))")
                conflicts.append(MinSizeConflict(window: r.window, allocated: r.frame, actual: r.actual.size))
            } else if r.stale {
                hyprLog("stale readback resolved for '\(r.window.title ?? "?")' — no conflict after resettle")
            }
        }
        return conflicts
    }

    private func applyLayoutFinal(_ layouts: [(HyprWindow, CGRect)]) {
        for (window, frame) in layouts {
            window.setFrame(frame, crossMonitor: false)
        }
    }

    // tile windows for a workspace on a specific screen.
    // screen is provided explicitly — don't trust window physical position (may be hidden in corner)
    func tileWindows(_ windows: [HyprWindow], onWorkspace workspace: Int, screen: NSScreen) {
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
        var addedAny = false
        for w in tileWindows where !treeIDs.contains(w.windowID) {
            if !t.smartInsert(w, maxDepth: maxDepth(for: screen), in: rect, gap: gapSize,
                              padding: outerPadding, minSlotDimension: minSlotDimension) {
                hyprLog("max depth exceeded — auto-floating '\(w.title ?? "?")'")
                onAutoFloat?(w)
            } else {
                addedAny = true
            }
        }

        // structural change — clear user-set ratios so layout resets to even splits
        if removedAny || addedAny {
            t.root.clearUserSetRatios()
        }

        t.root.resetSplitRatios()

        // pass 1: layout + readback
        let layouts = t.layout(in: rect, gap: gapSize, padding: outerPadding)
        hyprLog("tiling \(layouts.count) windows on workspace \(workspace) screen \(Int(screen.frame.width))x\(Int(screen.frame.height))")
        let conflicts = applyLayout(layouts)

        if !conflicts.isEmpty {
            // pass 2: adjust ratios and re-layout
            let mapped = conflicts.map { (window: $0.window, actual: $0.actual) }
            t.adjustForMinSizes(mapped, in: rect, gap: gapSize, padding: outerPadding)
            let adjusted = t.layout(in: rect, gap: gapSize, padding: outerPadding)
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
        for w in tileWindows where !treeIDs.contains(w.windowID) {
            if !t.smartInsert(w, maxDepth: maxDepth(for: screen), in: rect, gap: gapSize,
                              padding: outerPadding, minSlotDimension: minSlotDimension) {
                onAutoFloat?(w)
            } else {
                addedAny = true
            }
        }

        if removedAny || addedAny {
            t.root.clearUserSetRatios()
        }

        t.root.resetSplitRatios()
        return t.layout(in: rect, gap: gapSize, padding: outerPadding)
    }

    // add a single window to the tree for its workspace+screen and retile
    func addWindow(_ window: HyprWindow, toWorkspace workspace: Int, on screen: NSScreen) {
        guard !window.isFloating else { return }
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        let rect = displayManager.cgRect(for: screen)
        if !t.contains(window) {
            if !t.smartInsert(window, maxDepth: maxDepth(for: screen), in: rect, gap: gapSize,
                              padding: outerPadding, minSlotDimension: minSlotDimension) {
                hyprLog("max depth exceeded — auto-floating '\(window.title ?? "?")'")
                onAutoFloat?(window)
                return
            }
        }
        retile(key: key, screen: screen)
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

    // apply a manual resize: update split ratios from the new frame, then retile
    func applyResize(_ window: HyprWindow, newFrame: CGRect, onWorkspace workspace: Int, screen: NSScreen) {
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        let rect = displayManager.cgRect(for: screen)

        t.applyResizeDelta(for: window, newFrame: newFrame, in: rect, gap: gapSize, padding: outerPadding)
        retile(key: key, screen: screen)
    }

    func swapWindows(_ a: HyprWindow, _ b: HyprWindow, onWorkspace workspace: Int, screen: NSScreen) {
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        if t.contains(a) && t.contains(b) {
            t.swap(a, b)
            retile(key: key, screen: screen)
        }
    }

    // swap in the tree and return target layouts WITHOUT applying frames.
    // caller is responsible for animating or applying the result.
    func computeSwapLayout(_ a: HyprWindow, _ b: HyprWindow,
                           onWorkspace workspace: Int, screen: NSScreen) -> [(HyprWindow, CGRect)]? {
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

    func canFitWindow(onWorkspace workspace: Int, screen: NSScreen) -> Bool {
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        if t.root.isEmpty { return true }

        let rect = displayManager.cgRect(for: screen)
        let leaves = t.root.allLeavesRightToLeft()

        for leaf in leaves {
            guard leaf.depth < maxDepth(for: screen) else { continue }
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

        return leaves.contains { $0.depth < maxDepth(for: screen) }
    }

    // force-insert a window on an explicit screen, evicting deepest-right if full
    func forceInsertWindow(_ window: HyprWindow, toWorkspace workspace: Int, on screen: NSScreen) -> HyprWindow? {
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        let rect = displayManager.cgRect(for: screen)

        if t.contains(window) { return nil }

        if t.smartInsert(window, maxDepth: maxDepth(for: screen), in: rect, gap: gapSize,
                         padding: outerPadding, minSlotDimension: minSlotDimension) {
            retile(key: key, screen: screen)
            return nil
        }

        guard let evicted = t.deepestRightLeafWindow() else { return nil }
        t.remove(evicted)

        if t.smartInsert(window, maxDepth: maxDepth(for: screen), in: rect, gap: gapSize,
                         padding: outerPadding, minSlotDimension: minSlotDimension) {
            retile(key: key, screen: screen)
            return evicted
        }

        _ = t.insert(evicted, maxDepth: maxDepth(for: screen))
        retile(key: key, screen: screen)
        return nil
    }
}
