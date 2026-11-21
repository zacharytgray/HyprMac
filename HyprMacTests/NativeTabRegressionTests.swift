import XCTest
@testable import HyprMac

// native tabs (#85): every tab is its own window and only the selected one is
// on screen, so a tab switch must not move a tile or the focus. these replay a
// held Cmd+Shift+[ poll by poll through discovery, the dispatcher and the
// engine, with the app's (AX) and the window server's answers for each poll,
// and check the other tiles, the ratios and the focus after every poll. under
// key repeat the hide and the show often land in different polls.
//
// the focus check is the refocus counter plus the focus record. the record
// alone passes on unfixed code: adoptFocusedNewcomer records the shown tab.
// on main every case stops at the first tile check, so the focus checks only
// run once the layout holds.
//
// live behavior isn't checked here.

final class NativeTabRegressionTests: XCTestCase {

    let terminal: pid_t = 5000

    // MARK: - harness

    /// Answers the hidden-window query per id, and the focused window.
    final class SceneAccessibility: AccessibilityManager {
        var states: [CGWindowID: AccessibilityManager.HiddenWindowState] = [:]
        /// for an id `states` does not name. nil is the app not answering
        var defaultState: AccessibilityManager.HiddenWindowState? = .absent
        var focused: HyprWindow?

        override func isBackingOff(pid: pid_t) -> Bool { false }
        override var secondsUntilABackoffEnds: TimeInterval? { nil }
        override func hiddenWindowState(windowID: CGWindowID, pid: pid_t) -> AccessibilityManager.HiddenWindowState? {
            states[windowID] ?? defaultState
        }
        override func getFocusedWindow() -> HyprWindow? { focused }
    }

    /// What the window server reports at one poll, beside the AX walk.
    struct WindowServer {
        /// on screen, front to back, as `CGWindowListCopyWindowInfo` lists them
        var onScreen: [StackedWindow] = []
        /// tabs behind the selected one: they still exist, ordered out
        var backgroundTabs: Set<CGWindowID> = []
        /// windows the window server no longer has
        var destroyed: Set<CGWindowID> = []
    }

    final class Harness {
        let screen: NSScreen
        let engine: TilingEngine
        let cache: WindowStateCache
        let workspaces: WorkspaceManager
        let discovery: WindowDiscoveryService
        let dispatcher: ActionDispatcher
        let focus: FocusStateController
        let accessibility: SceneAccessibility
        var windowServer = WindowServer()
        var refocuses = 0
        /// what the last walk read and could not read
        var walkRead: Set<CGWindowID> = []
        var walkUnreadable: Set<CGWindowID> = []
        var clock = Date(timeIntervalSince1970: 1_000_000)

        init(screen: NSScreen, engine: TilingEngine, cache: WindowStateCache, workspaces: WorkspaceManager,
             discovery: WindowDiscoveryService, dispatcher: ActionDispatcher, focus: FocusStateController,
             accessibility: SceneAccessibility) {
            self.screen = screen; self.engine = engine; self.cache = cache; self.workspaces = workspaces
            self.discovery = discovery; self.dispatcher = dispatcher; self.focus = focus
            self.accessibility = accessibility
        }

        func rects() -> [CGWindowID: CGRect] { engine.intendedTileRects() }

        func leafIDs() -> Set<CGWindowID> { Set(engine.windowIDs(inTreeForWorkspace: 1, screen: screen)) }

        func ratios() -> [CGFloat] {
            guard let tree = engine.existingTree(forWorkspace: 1, screen: screen) else { return [] }
            var out: [CGFloat] = []
            func walk(_ node: BSPNode?) {
                guard let node, !node.isLeaf else { return }
                out.append(node.splitRatio)
                walk(node.left)
                walk(node.right)
            }
            walk(tree.root)
            return out
        }

        /// A walk's copy of window `id`, read at `frame`.
        func read(_ id: CGWindowID, pid: pid_t = 5000, at frame: CGRect) -> HyprWindow {
            let w = makeWindow(id: id, pid: pid)
            w.cachedFrame = frame
            return w
        }

        /// What the last walk could not read, and what discovery held and
        /// the walk did not read, as WindowManager's `heldWindowIDs`.
        var heldWindowIDs: Set<CGWindowID> {
            walkUnreadable.union(discovery.heldWindowIDs.subtracting(walkRead))
        }

        /// The caches as `WindowManager.updatePositionCache` refreshes them
        /// from a walk: visible windows, and the tiled ones at their frames.
        func refreshCache(_ windows: [HyprWindow]) {
            cache.tiledPositions.removeAll()
            cache.cachedWindows.removeAll()
            let treeObjects = engine.treeWindowObjects()
            for w in windows {
                guard workspaces.isWindowVisible(w.windowID) else { continue }
                w.adoptNewerCachedFrame(from: treeObjects[w.windowID])
                cache.cachedWindows[w.windowID] = w
                guard let frame = w.cachedFrame,
                      !cache.floatingWindowIDs.contains(w.windowID),
                      !engine.isCoveredByMaximized(w.windowID) else { continue }
                cache.tiledPositions[w.windowID] = frame
            }
        }
    }

    private var configDir: URL?
    private var store: ConfigStore?

    override func setUp() {
        // each test reports the first poll that broke the layout or focus
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        store?.stopFileWatcher()
        store = nil
        if let configDir { try? FileManager.default.removeItem(at: configDir) }
    }

    private func makeHarness() throws -> Harness {
        let screen = RegressionTestScreen()
        let displayManager = DisplayManager(screenSource: { [screen] })
        let engine = TilingEngine(displayManager: displayManager, frameSizingIOFactory: acceptingFrameSizingIOFactory())
        let cache = WindowStateCache()
        let suppressions = SuppressionRegistry()
        let focusBorder = FocusBorder()
        let focusController = FocusStateController(focusBorder: focusBorder)
        let accessibility = SceneAccessibility()
        let cursorManager = CursorManager()
        let workspaces = WorkspaceManager(displayManager: displayManager)
        workspaces.initializeMonitors()
        let orchestrator = WorkspaceOrchestrator(
            workspaceManager: workspaces, tilingEngine: engine,
            accessibility: accessibility, displayManager: displayManager,
            cursorManager: cursorManager, stateCache: cache,
            focusController: focusController, focusBorder: focusBorder,
            dimmingOverlay: DimmingOverlay(), suppressions: suppressions,
            revalidation: MinimaRevalidation())
        let floating = FloatingWindowController(
            stateCache: cache, suppressions: suppressions,
            workspaceManager: workspaces, tilingEngine: engine,
            displayManager: displayManager, accessibility: accessibility,
            cursorManager: cursorManager, focusController: focusController,
            focusBorder: focusBorder, dimmingOverlay: DimmingOverlay())
        // the config lives in a temp folder, never the user's
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeTabRegression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        configDir = dir
        let store = ConfigStore(localConfigURL: dir.appendingPathComponent("config.json"),
                                monitorConfigURL: dir.appendingPathComponent("monitor-config.json"),
                                iCloudRootURL: dir.appendingPathComponent("cloud", isDirectory: true))
        self.store = store
        let config = UserConfig(store: store, iCloudSyncEnabled: false)
        config.showFocusBorder = false
        let dispatcher = ActionDispatcher(
            stateCache: cache, accessibility: accessibility,
            displayManager: displayManager, cursorManager: cursorManager,
            workspaceManager: workspaces, tilingEngine: engine,
            focusController: focusController, focusBorder: focusBorder,
            keybindOverlay: KeybindOverlayController(), appLauncher: AppLauncherManager(),
            workspaceOrchestrator: orchestrator, floatingController: floating,
            config: config)
        let discovery = WindowDiscoveryService(stateCache: cache, accessibility: accessibility,
                                               displayManager: displayManager, workspaceManager: workspaces,
                                               bundleIDForPID: { _ in "com.apple.Terminal" },
                                               isWindowSizeSettable: { _ in true })
        let h = Harness(screen: screen, engine: engine, cache: cache, workspaces: workspaces,
                        discovery: discovery, dispatcher: dispatcher, focus: focusController,
                        accessibility: accessibility)
        discovery.now = { [unowned h] in h.clock }
        dispatcher.screenUnderCursor = { screen }
        // the retile WindowManager wires, cut down to workspace 1, and the
        // position cache it refreshes
        dispatcher.retile = { [unowned h] windows in
            let members = windows.filter {
                workspaces.workspaceFor($0.windowID) == 1 && !cache.floatingWindowIDs.contains($0.windowID)
            }
            let result = engine.tileWindows(members, onWorkspace: 1, screen: screen)
            h.refreshCache(windows)
            return [result]
        }
        // a synthetic click on whatever tile is under the resting pointer
        dispatcher.refocusUnderCursor = { [unowned h] in h.refocuses += 1 }
        // nothing here may activate a real app, raise a real window or read
        // the real screen
        dispatcher.focusWindow = { _, _ in }
        dispatcher.heldWindowIDs = { [unowned h] in h.heldWindowIDs }
        orchestrator.screenUnderCursor = { screen }
        orchestrator.focusTransferredWindow = { _ in }
        floating.performRaise = { _ in .success }
        floating.frontApp = { _ in }
        floating.restoreFocusLifting = { _ in }
        floating.windowListForZOrder = { [] }
        floating.frontmostPID = { nil }
        engine.splitTargetSource = { focusController.lastFocusedID == 0 ? nil : focusController.lastFocusedID }
        // the hold as WindowManager wires it
        engine.heldWindowIDsSource = { [unowned h] in
            h.heldWindowIDs.subtracting(cache.floatingWindowIDs).subtracting(cache.hiddenWindowIDs)
        }
        wireFix(h)
        return h
    }

    // MARK: - the scene

    /// Three Terminal windows tiled on workspace 1. 102, top right, is the
    /// focused one; its tabs switch in place.
    private struct Layout {
        let rects: [CGWindowID: CGRect]
        let ratios: [CGFloat]
        var slot: CGRect { rects[102]! }
    }

    private func tileThree(_ h: Harness) -> (left: HyprWindow, bottom: HyprWindow, layout: Layout) {
        let ids: [CGWindowID] = [101, 102, 103]
        for id in ids { h.workspaces.assignWindow(id, toWorkspace: 1) }
        let first = ids.map { h.read($0, at: CGRect(x: 0, y: 0, width: 100, height: 100)) }
        h.windowServer.onScreen = first.map { StackedWindow(windowID: $0.windowID, ownerPID: terminal, bounds: $0.cachedFrame) }
        runPoll(h, walk: first, unreadable: [])
        let defaults = h.ratios()
        // a column ratio of the user's own, so a tree rebuilt at the defaults
        // shows in the ratios
        h.engine.resizeInDirection(first[0], direction: .right, onWorkspace: 1, screen: h.screen)
        let rects = h.rects()
        let settled = ids.map { h.read($0, at: rects[$0]!) }
        h.windowServer.onScreen = settled.map { StackedWindow(windowID: $0.windowID, ownerPID: terminal, bounds: $0.cachedFrame) }
        runPoll(h, walk: settled, unreadable: [])
        h.refreshCache(settled)
        h.focus.recordFocus(102, reason: "test")
        h.accessibility.focused = settled[1]
        h.refocuses = 0
        XCTAssertEqual(h.leafIDs(), Set(ids), "precondition: three tiles")
        XCTAssertEqual(h.ratios().count, 2, "precondition: two splits")
        XCTAssertNotEqual(h.ratios().first, defaults.first, "precondition: the column ratio off the default")
        return (settled[0], settled[2], Layout(rects: rects, ratios: h.ratios()))
    }

    /// One poll while tab group `group` sits in 102's slot.
    ///
    /// - Parameter shown: the selected tab. nil is the moment between a hide
    ///   and a show: the old tab is gone and the new one not published yet.
    /// - Parameter readable: false is the busy app. The window server shows
    ///   `shown` in the slot, but AX does not answer for it or for the tab
    ///   that left.
    private func poll(_ h: Harness, _ s: (left: HyprWindow, bottom: HyprWindow, layout: Layout),
                      group: [CGWindowID], shown: CGWindowID?, readable: Bool = true) {
        let slot = s.layout.slot
        var walk = [s.left, s.bottom]
        var unreadable: Set<CGWindowID> = []
        var onScreen = [StackedWindow(windowID: s.left.windowID, ownerPID: terminal, bounds: s.layout.rects[101])]
        if let shown {
            onScreen.append(StackedWindow(windowID: shown, ownerPID: terminal, bounds: slot))
            if readable {
                let w = h.read(shown, at: slot)
                walk.insert(w, at: 1)
                h.accessibility.focused = w
            } else {
                unreadable.insert(shown)
            }
        }
        onScreen.append(StackedWindow(windowID: s.bottom.windowID, ownerPID: terminal, bounds: s.layout.rects[103]))
        h.windowServer.onScreen = onScreen
        h.windowServer.backgroundTabs = Set(group).subtracting(shown.map { [$0] } ?? [])
        h.windowServer.destroyed = []
        h.accessibility.defaultState = readable ? .absent : nil
        runPoll(h, walk: walk, unreadable: unreadable)
    }

    /// The layout and focus are what they were before the first switch, with
    /// one tab of the group holding the slot.
    private func assertKept(_ h: Harness, _ layout: Layout, group: [CGWindowID], _ step: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let rects = h.rects()
        XCTAssertEqual(rects[101], layout.rects[101], "\(step): the left tile moved", file: file, line: line)
        XCTAssertEqual(rects[103], layout.rects[103], "\(step): the bottom tile moved", file: file, line: line)
        let inSlot = h.leafIDs().subtracting([101, 103])
        XCTAssertEqual(inSlot.count, 1, "\(step): the slot holds \(inSlot.sorted()), not one tab", file: file, line: line)
        if let tab = inSlot.first {
            XCTAssertTrue(group.contains(tab), "\(step): \(tab) is not a tab of the group", file: file, line: line)
            XCTAssertEqual(rects[tab], layout.slot, "\(step): the tab's tile moved", file: file, line: line)
        }
        XCTAssertEqual(h.ratios(), layout.ratios, "\(step): the split ratios changed", file: file, line: line)
        XCTAssertEqual(h.refocuses, 0, "\(step): refocused whatever is under the cursor", file: file, line: line)
        XCTAssertTrue(group.contains(h.focus.lastFocusedID),
                      "\(step): focus moved off the tab group to \(h.focus.lastFocusedID)", file: file, line: line)
    }

    // MARK: - one switch

    /// The easy case: the hide and the show land in the same poll.
    func testASwitchInOnePollKeepsTheLayoutAndFocus() throws {
        let h = try makeHarness()
        let s = tileThree(h)
        let group: [CGWindowID] = [102, 202]

        poll(h, s, group: group, shown: 202)

        assertKept(h, s.layout, group: group, "same poll")
        XCTAssertEqual(h.rects()[202], s.layout.slot)
        XCTAssertEqual(h.focus.lastFocusedID, 202)
    }

    /// The busy app: the new tab is on screen in the slot but unread for two
    /// seconds, and AX can't say what happened to the old one.
    func testASwitchSplitAcrossPollsKeepsTheLayoutAndFocus() throws {
        let h = try makeHarness()
        let s = tileThree(h)
        let group: [CGWindowID] = [102, 202]

        poll(h, s, group: group, shown: 202, readable: false)
        assertKept(h, s.layout, group: group, "busy poll")

        h.clock.addTimeInterval(2)
        poll(h, s, group: group, shown: 202)
        assertKept(h, s.layout, group: group, "app answers")
        XCTAssertEqual(h.rects()[202], s.layout.slot)
        XCTAssertEqual(h.focus.lastFocusedID, 202)
    }

    /// The old tab is gone from the walk before the new one is published at
    /// all; it shows a poll later.
    func testAShownTabAPollLateKeepsTheLayoutAndFocus() throws {
        let h = try makeHarness()
        let s = tileThree(h)
        let group: [CGWindowID] = [102, 202]

        poll(h, s, group: group, shown: nil)
        assertKept(h, s.layout, group: group, "between hide and show")

        h.clock.addTimeInterval(0.3)
        poll(h, s, group: group, shown: 202)
        assertKept(h, s.layout, group: group, "shown")
        XCTAssertEqual(h.rects()[202], s.layout.slot)
        XCTAssertEqual(h.focus.lastFocusedID, 202)
    }

    /// Back to the first tab: 102 returns with its own id, a poll late.
    func testReturningToTheFirstTabKeepsItsSlot() throws {
        let h = try makeHarness()
        let s = tileThree(h)
        let group: [CGWindowID] = [102, 202]

        poll(h, s, group: group, shown: 202)
        assertKept(h, s.layout, group: group, "first switch")
        h.clock.addTimeInterval(0.1)
        poll(h, s, group: group, shown: 102, readable: false)
        assertKept(h, s.layout, group: group, "busy poll on the way back")
        h.clock.addTimeInterval(1)
        poll(h, s, group: group, shown: 102)
        assertKept(h, s.layout, group: group, "back on the first tab")
        XCTAssertEqual(h.rects()[102], s.layout.slot)
        XCTAssertEqual(h.focus.lastFocusedID, 102)
    }

    // MARK: - a held key

    /// Cmd+Shift+[ held through a group of four tabs, three times round. Every
    /// third switch the poll catches the app busy, and every fifth the new tab
    /// is not published yet.
    func testAHeldKeyThroughTheGroupKeepsTheLayoutAndFocus() throws {
        let h = try makeHarness()
        let s = tileThree(h)
        let group: [CGWindowID] = [102, 202, 203, 204]

        for step in 1...12 {
            let next = group[step % group.count]
            h.clock.addTimeInterval(0.1)
            if step % 5 == 0 {
                poll(h, s, group: group, shown: nil)
                assertKept(h, s.layout, group: group, "step \(step), between hide and show")
                h.clock.addTimeInterval(0.2)
            }
            if step % 3 == 0 {
                poll(h, s, group: group, shown: next, readable: false)
                assertKept(h, s.layout, group: group, "step \(step), busy poll")
                h.clock.addTimeInterval(0.4)
            }
            poll(h, s, group: group, shown: next)
            assertKept(h, s.layout, group: group, "step \(step)")
            XCTAssertEqual(h.rects()[next], s.layout.slot, "step \(step)")
            XCTAssertEqual(h.focus.lastFocusedID, next, "step \(step)")
        }
    }

    // MARK: - what a fix must not break

    /// Closing the last tab is an ordinary close: nothing takes the slot and
    /// the neighbours get the space back.
    func testClosingTheLastTabStillGivesItsSpaceBack() throws {
        let h = try makeHarness()
        let s = tileThree(h)

        h.windowServer.onScreen = [
            StackedWindow(windowID: 101, ownerPID: terminal, bounds: s.layout.rects[101]),
            StackedWindow(windowID: 103, ownerPID: terminal, bounds: s.layout.rects[103]),
        ]
        h.windowServer.backgroundTabs = []
        h.windowServer.destroyed = [102]
        h.accessibility.defaultState = .absent
        runPoll(h, walk: [s.left, s.bottom], unreadable: [])
        // whatever short wait a fix allows a tab to show, it is over
        h.clock.addTimeInterval(3)
        runPoll(h, walk: [s.left, s.bottom], unreadable: [])

        XCTAssertEqual(h.leafIDs(), [101, 103])
        XCTAssertEqual(h.rects()[101], s.layout.rects[101], "the left tile stays")
        XCTAssertEqual(h.rects()[103], s.layout.slot.union(s.layout.rects[103]!),
                       "the bottom tile takes the freed slot and the gap above it")
    }
}

private final class RegressionTestScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 1600, height: 1000) }
    override var visibleFrame: NSRect { frame }
}

// MARK: - adapter
//
// a cut-down `WindowManager.pollWindowChanges`: discovery, the stop on a
// session interruption, the tree half of the re-created element adoption, the
// dispatcher and the held-window release, in that order. it leaves out the
// drift re-apply, the destroy recheck, admission recovery, the hold and retry
// re-polls and the cache half of the adoption. `wireFix` gives discovery the
// scene's window server.

extension NativeTabRegressionTests {

    /// Wire the fix's window-server sources to `h.windowServer`.
    func wireFix(_ h: Harness) {
        h.discovery.onScreenWindows = { [unowned h] in h.windowServer.onScreen }
        h.discovery.isOrderedOutBesideAnother = { [unowned h] id, _ in
            h.windowServer.backgroundTabs.contains(id)
                && !h.windowServer.backgroundTabs.subtracting([id]).isEmpty
        }
        h.dispatcher.refreshPositionCache = { [unowned h] in h.refreshCache($0) }
    }

    /// One discovery poll over the walk `walk`.
    @discardableResult
    func runPoll(_ h: Harness, walk: [HyprWindow], unreadable: Set<CGWindowID>) -> WindowChanges {
        h.walkRead = Set(walk.map(\.windowID))
        h.walkUnreadable = unreadable
        let changes = h.discovery.computeChanges(
            snapshot: walk, runningPIDs: [terminal], excludedBundleIDs: [],
            focusedWindowID: h.focus.lastFocusedID, unreadableWindowIDs: unreadable)
        // locked or asleep: the poll stops here
        if changes.heldForInterruption { return changes }
        h.engine.adoptRecreatedWindows(from: walk)
        _ = h.dispatcher.applyChanges(changes, allWindows: walk)
        let released = h.engine.releaseHeldWindows(readable: Set(walk.map(\.windowID)))
        if !released.isEmpty, !changes.needsRetile { _ = h.dispatcher.retile(walk) }
        return changes
    }
}
