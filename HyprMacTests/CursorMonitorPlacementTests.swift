import XCTest
import Cocoa
@testable import HyprMac

// an app's first window opens on the monitor under the pointer. the rule
// itself is a pure function; the dispatcher gathers its facts, assigns,
// and sends a refused window back to the monitor it opened on.

final class CursorMonitorPlacementTests: XCTestCase {

    // MARK: - the rule

    private typealias Facts = ActionDispatcher.CursorPlacementFacts

    private func decide(_ change: (inout Facts) -> Void = { _ in }) -> ActionDispatcher.CursorPlacement {
        var facts = Facts(cursorWorkspace: 3)
        change(&facts)
        return ActionDispatcher.cursorPlacement(facts)
    }

    func testAnAppsFirstWindowOnAnotherMonitorMovesToTheCursorsWorkspace() {
        XCTAssertEqual(decide(), .move(toWorkspace: 3))
    }

    func testAWindowAlreadyOnTheCursorsMonitorStays() {
        XCTAssertEqual(decide { $0.standsOnCursorMonitor = true }, .stay(.alreadyOnCursorMonitor))
        XCTAssertEqual(decide { $0.standsOnCursorMonitor = false }, .move(toWorkspace: 3))
    }

    func testAReconcilePollLeavesTheWindowWhereItOpened() {
        XCTAssertEqual(decide { $0.gate = .reconcilePoll }, .stay(.reconcilePoll))
        XCTAssertEqual(decide { $0.gate = .open }, .move(toWorkspace: 3))
    }

    func testADisplayTransitionLeavesTheWindowWhereItOpened() {
        XCTAssertEqual(decide { $0.gate = .displayTransition }, .stay(.displayTransition))
    }

    func testAPinWins() {
        XCTAssertEqual(decide { $0.isPinned = true }, .stay(.pinned))
        XCTAssertEqual(decide { $0.isPinned = false }, .move(toWorkspace: 3))
    }

    func testAFloaterStays() {
        XCTAssertEqual(decide { $0.isFloating = true }, .stay(.floating))
    }

    func testAQuickLookPanelStays() {
        XCTAssertEqual(decide { $0.isQuickLookPanel = true }, .stay(.quickLookPanel))
    }

    func testADisabledCursorMonitorTakesNothing() {
        XCTAssertEqual(decide { $0.cursorMonitorEnabled = false }, .stay(.cursorMonitorDisabled))
        XCTAssertEqual(decide { $0.cursorMonitorEnabled = true }, .move(toWorkspace: 3))
    }

    func testAnAppWithAWindowOnScreenKeepsItsNewWindowWhereItOpened() {
        XCTAssertEqual(decide { $0.appHasOtherWindowOnScreen = true }, .stay(.appHasWindowOnScreen))
        XCTAssertEqual(decide { $0.appHasOtherWindowOnScreen = false }, .move(toWorkspace: 3))
    }

    func testAFullCursorWorkspaceLeavesTheWindowWhereItOpened() {
        XCTAssertEqual(decide { $0.cursorWorkspaceHasRoom = false }, .stay(.workspaceFull))
        XCTAssertEqual(decide { $0.cursorWorkspaceHasRoom = true }, .move(toWorkspace: 3))
    }

    // MARK: - drift exemption

    private func driftService(clock: @escaping () -> Date)
        -> (WindowDiscoveryService, WindowStateCache, WorkspaceManager, left: NSScreen, right: NSScreen) {
        let left = PlacementLeftScreen(), right = PlacementRightScreen()
        let display = DisplayManager(screenSource: { [left, right] })
        let workspaces = WorkspaceManager(displayManager: display)
        workspaces.initializeMonitors()
        let cache = WindowStateCache()
        let svc = WindowDiscoveryService(stateCache: cache, accessibility: StubAccessibility(),
                                         displayManager: display, workspaceManager: workspaces,
                                         bundleIDForPID: { _ in nil }, isWindowSizeSettable: { _ in true })
        svc.now = clock
        return (svc, cache, workspaces, left, right)
    }

    private func poll(_ svc: WindowDiscoveryService, _ windows: [HyprWindow], running: Set<pid_t>) -> WindowChanges {
        svc.computeChanges(snapshot: windows, runningPIDs: running, excludedBundleIDs: [],
                           focusedWindowID: 0)
    }

    /// a window assigned to the left monitor's workspace that still stands
    /// on the right one
    private func onItsWay(_ svc: WindowDiscoveryService, _ cache: WindowStateCache,
                          _ workspaces: WorkspaceManager, left: NSScreen) -> PlacementFramedWindow {
        let window = PlacementFramedWindow(id: 9101, pid: 9100, frame: CGRect(x: 2000, y: 100, width: 800, height: 600))
        cache.knownWindowIDs = [9101]
        cache.windowOwners[9101] = 9100
        workspaces.assignWindow(9101, toWorkspace: workspaces.workspaceForScreen(left))
        svc.exemptFromDrift(9101)
        return window
    }

    func testDriftLeavesAWindowOnItsWayToTheCursorsMonitorAlone() {
        let clock = Date(timeIntervalSinceReferenceDate: 1000)
        let (svc, cache, workspaces, left, _) = driftService(clock: { clock })
        let window = onItsWay(svc, cache, workspaces, left: left)

        XCTAssertTrue(poll(svc, [window], running: [9100]).screenDrift.isEmpty)
        XCTAssertEqual(svc.driftExemptWindowIDs, [9101])
    }

    func testTheExemptionEndsOnceTheWindowIsMostlyOnItsWorkspacesScreen() {
        let clock = Date(timeIntervalSinceReferenceDate: 1000)
        let (svc, cache, workspaces, left, _) = driftService(clock: { clock })
        let window = onItsWay(svc, cache, workspaces, left: left)

        window.storedFrame = CGRect(x: 1000, y: 100, width: 800, height: 600)
        XCTAssertTrue(poll(svc, [window], running: [9100]).screenDrift.isEmpty)
        XCTAssertEqual(svc.driftExemptWindowIDs, [])

        // dragged back to the right monitor later, it drifts as any window does
        window.storedFrame = CGRect(x: 2000, y: 100, width: 800, height: 600)
        XCTAssertEqual(poll(svc, [window], running: [9100]).screenDrift.map(\.windowID), [9101])
    }

    func testTheExemptionEndsAtItsDeadline() {
        var clock = Date(timeIntervalSinceReferenceDate: 1000)
        let (svc, cache, workspaces, left, _) = driftService(clock: { clock })
        let window = onItsWay(svc, cache, workspaces, left: left)

        clock += WindowDiscoveryService.driftExemptionSpan + 0.1
        XCTAssertEqual(poll(svc, [window], running: [9100]).screenDrift.map(\.windowID), [9101])
        XCTAssertEqual(svc.driftExemptWindowIDs, [])
    }

    func testTheExemptionIsDroppedWhenTheWindowIsForgotten() {
        let clock = Date(timeIntervalSinceReferenceDate: 1000)
        let (svc, cache, workspaces, left, _) = driftService(clock: { clock })
        _ = onItsWay(svc, cache, workspaces, left: left)

        let changes = poll(svc, [], running: [])

        XCTAssertEqual(changes.fullyForgottenIDs, [9101])
        XCTAssertEqual(svc.driftExemptWindowIDs, [])
    }

    // MARK: - the dispatcher on two monitors

    private final class Harness {
        let left = PlacementLeftScreen()
        let right = PlacementRightScreen()
        let workspaces: WorkspaceManager
        let engine: TilingEngine
        let cache = WindowStateCache()
        let focus: FocusStateController
        let dispatcher: ActionDispatcher
        var windows: [HyprWindow] = []
        var exempted: Set<CGWindowID> = []
        var exemptionsEnded: Set<CGWindowID> = []
        var recoveryCancelled: [CGWindowID] = []
        private let configDir: URL
        private let store: ConfigStore

        var leftWorkspace: Int { workspaces.workspaceForScreen(left) }
        var rightWorkspace: Int { workspaces.workspaceForScreen(right) }

        init(rules: [WindowRule] = []) {
            let left = self.left, right = self.right
            let display = DisplayManager(screenSource: { [left, right] })
            workspaces = WorkspaceManager(displayManager: display)
            workspaces.initializeMonitors()
            engine = TilingEngine(displayManager: display, frameSizingIOFactory: acceptingFrameSizingIOFactory())
            configDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("CursorMonitorPlacement-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            store = ConfigStore(localConfigURL: configDir.appendingPathComponent("config.json"),
                                monitorConfigURL: configDir.appendingPathComponent("monitor-config.json"),
                                iCloudRootURL: configDir.appendingPathComponent("cloud", isDirectory: true))
            let config = UserConfig(store: store, iCloudSyncEnabled: false)
            config.windowRules = rules
            let suppressions = SuppressionRegistry()
            let border = FocusBorder()
            focus = FocusStateController(focusBorder: border)
            let dimming = DimmingOverlay()
            let accessibility = AccessibilityManager()
            let cursor = CursorManager()
            let orchestrator = WorkspaceOrchestrator(
                workspaceManager: workspaces, tilingEngine: engine,
                accessibility: accessibility, displayManager: display,
                cursorManager: cursor, stateCache: cache,
                focusController: focus, focusBorder: border,
                dimmingOverlay: dimming, suppressions: suppressions,
                revalidation: MinimaRevalidation())
            let floating = FloatingWindowController(
                stateCache: cache, suppressions: suppressions,
                workspaceManager: workspaces, tilingEngine: engine,
                displayManager: display, accessibility: accessibility,
                cursorManager: cursor, focusController: focus,
                focusBorder: border, dimmingOverlay: dimming)
            dispatcher = ActionDispatcher(
                stateCache: cache, accessibility: accessibility,
                displayManager: display, cursorManager: cursor,
                workspaceManager: workspaces, tilingEngine: engine,
                focusController: focus, focusBorder: border,
                keybindOverlay: KeybindOverlayController(), appLauncher: AppLauncherManager(),
                workspaceOrchestrator: orchestrator, floatingController: floating,
                config: config)
            // the pointer is on the left monitor
            dispatcher.screenUnderCursor = { left }
            dispatcher.isMenuTracking = { true }
            dispatcher.exemptFromDrift = { [unowned self] in exempted.insert($0) }
            dispatcher.endDriftExemption = { [unowned self] in exemptionsEnded.insert($0) }
            dispatcher.cancelAdmissionRecovery = { [unowned self] id, _ in recoveryCancelled.append(id) }
            // the retile WindowManager wires: every visible workspace, by screen
            dispatcher.retile = { [unowned self] windows in
                var results: [TilingEngine.AdmissionResult] = []
                for screen in [left, right] {
                    let members = workspaces.windowIDs(onWorkspace: workspaces.workspaceForScreen(screen))
                    results.append(engine.tileWindows(windows.filter { members.contains($0.windowID) },
                                                      onWorkspace: workspaces.workspaceForScreen(screen),
                                                      screen: screen))
                }
                cache.cachedWindows = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
                cache.tiledPositions = engine.intendedTileRects()
                return results
            }
            engine.newcomerOriginSource = { [unowned self] in dispatcher.cursorMoveOrigin($0) }
            engine.splitTargetSource = { [unowned self] in focus.lastFocusedID == 0 ? nil : focus.lastFocusedID }
        }

        deinit {
            store.stopFileWatcher()
            try? FileManager.default.removeItem(at: configDir)
        }

        func frame(on screen: NSScreen) -> CGRect {
            screen === left ? CGRect(x: 200, y: 100, width: 800, height: 600)
                : CGRect(x: 2000, y: 100, width: 800, height: 600)
        }

        /// windows already tiled on `screen`'s visible workspace
        @discardableResult
        func tiled(_ ids: [CGWindowID], pid: pid_t, on screen: NSScreen) -> [HyprWindow] {
            let made = ids.map { PlacementFramedWindow(id: $0, pid: pid, frame: frame(on: screen)) }
            for w in made {
                cache.knownWindowIDs.insert(w.windowID)
                cache.windowOwners[w.windowID] = pid
                workspaces.assignWindow(w.windowID, toWorkspace: workspaces.workspaceForScreen(screen))
            }
            windows += made
            _ = dispatcher.retile(windows)
            return made
        }

        /// a window discovery just found, standing on `screen`
        func opens(_ id: CGWindowID, pid: pid_t, on screen: NSScreen, bundleID: String? = nil,
                   minimum: CGSize? = nil) -> HyprWindow {
            let w = PlacementFramedWindow(id: id, pid: pid, frame: frame(on: screen))
            w.bundleID = bundleID
            w.observedMinSize = minimum
            cache.knownWindowIDs.insert(id)
            cache.windowOwners[id] = pid
            windows.append(w)
            _ = dispatcher.applyChanges(
                WindowChanges(newWindows: [w], newOnDisabledMonitor: [], returned: [],
                              goneIDs: [], fullyForgottenIDs: [], screenDrift: [],
                              focusedWindowGone: false, requestsRecheck: false),
                allWindows: windows)
            return w
        }

        /// `window`, gone from `screen`'s workspace, back on screen there
        func returns(_ window: HyprWindow, afterClose: Bool) {
            let id = window.windowID
            _ = dispatcher.applyChanges(
                WindowChanges(newWindows: [], newOnDisabledMonitor: [], returned: [],
                              goneIDs: [id], fullyForgottenIDs: [], screenDrift: [],
                              focusedWindowGone: false, requestsRecheck: false),
                allWindows: windows.filter { $0.windowID != id })
            var changes = WindowChanges(newWindows: [], newOnDisabledMonitor: [], returned: [window],
                                        goneIDs: [], fullyForgottenIDs: [], screenDrift: [],
                                        focusedWindowGone: false, requestsRecheck: false)
            if afterClose { changes.reopenedAfterClose = [id] }
            _ = dispatcher.applyChanges(changes, allWindows: windows)
        }

        func tree(_ screen: NSScreen) -> Set<CGWindowID> {
            Set(engine.windowIDs(inTreeForWorkspace: workspaces.workspaceForScreen(screen), screen: screen))
        }

        func sibling(of id: CGWindowID, on screen: NSScreen) -> CGWindowID? {
            guard let tree = engine.existingTree(forWorkspace: workspaces.workspaceForScreen(screen), screen: screen),
                  let node = tree.root.allLeavesRightToLeft().first(where: { $0.window?.windowID == id }),
                  let parent = node.parent else { return nil }
            return (parent.left === node ? parent.right : parent.left)?.window?.windowID
        }
    }

    func testANewAppWindowOnTheOtherMonitorOpensBesideTheFocusedTile() {
        let h = Harness()
        let tiles = h.tiled([9201, 9202], pid: 9200, on: h.left)
        h.tiled([9203], pid: 9210, on: h.right)
        h.focus.recordFocus(tiles[0].windowID, reason: "test")

        let teams = h.opens(9204, pid: 9220, on: h.right)

        XCTAssertEqual(h.workspaces.workspaceFor(teams.windowID), h.leftWorkspace)
        XCTAssertTrue(h.tree(h.left).contains(teams.windowID))
        XCTAssertFalse(h.tree(h.right).contains(teams.windowID))
        XCTAssertEqual(h.sibling(of: teams.windowID, on: h.left), tiles[0].windowID)
        XCTAssertEqual(h.exempted, [teams.windowID])
        XCTAssertNil(h.dispatcher.cursorMoveOrigin(teams.windowID), "the pass's moves end with it")
    }

    func testAnAppThatAlreadyHasAWindowOnScreenOpensWhereMacOSPutIt() {
        let h = Harness()
        h.tiled([9301], pid: 9300, on: h.left)
        h.tiled([9302], pid: 9310, on: h.right)

        let second = h.opens(9303, pid: 9310, on: h.right)

        XCTAssertEqual(h.workspaces.workspaceFor(second.windowID), h.rightWorkspace)
        XCTAssertTrue(h.tree(h.right).contains(second.windowID))
        XCTAssertTrue(h.exempted.isEmpty)
    }

    func testAPinnedAppGoesToItsPin() {
        let h = Harness(rules: [WindowRule(bundleID: "com.example.pinned", workspace: 5)])
        h.tiled([9401], pid: 9400, on: h.left)
        XCTAssertNotEqual(h.leftWorkspace, 5)
        XCTAssertNotEqual(h.rightWorkspace, 5)

        let pinned = h.opens(9402, pid: 9410, on: h.right, bundleID: "com.example.pinned")

        XCTAssertEqual(h.workspaces.workspaceFor(pinned.windowID), 5)
        XCTAssertTrue(h.exempted.isEmpty)
    }

    func testAWindowReopenedAfterACloseMovesToTheCursorsMonitor() {
        let h = Harness()
        h.tiled([9501], pid: 9500, on: h.left)
        let teams = h.tiled([9502, 9503], pid: 9510, on: h.right)
        // the app's other window is gone too, so nothing of it is on screen
        h.cache.knownWindowIDs.remove(9503)
        h.cache.hiddenWindowIDs.insert(9503)
        h.windows.removeAll { $0.windowID == 9503 }

        h.returns(teams[0], afterClose: true)

        XCTAssertEqual(h.workspaces.workspaceFor(9502), h.leftWorkspace)
        XCTAssertTrue(h.tree(h.left).contains(9502))
        XCTAssertFalse(h.tree(h.right).contains(9502))
    }

    func testAWindowBackFromAMinimizeKeepsItsWorkspace() {
        let h = Harness()
        h.tiled([9601], pid: 9600, on: h.left)
        let window = h.tiled([9602], pid: 9610, on: h.right)[0]

        h.returns(window, afterClose: false)

        XCTAssertEqual(h.workspaces.workspaceFor(9602), h.rightWorkspace)
        XCTAssertTrue(h.tree(h.right).contains(9602))
        XCTAssertTrue(h.exempted.isEmpty)
    }

    func testAFullWorkspaceOnTheCursorsMonitorLeavesTheWindowWhereItOpened() {
        let h = Harness()
        // two tiles fill a one-split monitor
        h.engine.maxSplitsPerMonitor = [h.left.localizedName: 1]
        h.tiled([9701, 9702], pid: 9700, on: h.left)

        let window = h.opens(9703, pid: 9710, on: h.right)

        XCTAssertEqual(h.workspaces.workspaceFor(window.windowID), h.rightWorkspace)
        XCTAssertTrue(h.tree(h.right).contains(window.windowID))
        XCTAssertEqual(h.tree(h.left), [9701, 9702])
        XCTAssertTrue(h.exempted.isEmpty, "never moved, not moved and sent back")
        XCTAssertTrue(h.recoveryCancelled.isEmpty)
    }

    /// wider than the left monitor, so its tile there is refused before
    /// any frame is written. it goes back to the right monitor and tiles there
    func testAWindowTheCursorsMonitorRefusesGoesBackToTheMonitorItOpenedOn() {
        let h = Harness()
        h.tiled([9801], pid: 9800, on: h.left)
        h.tiled([9802], pid: 9805, on: h.right)

        let wide = h.opens(9803, pid: 9810, on: h.right, minimum: CGSize(width: 1700, height: 100))

        XCTAssertEqual(h.workspaces.workspaceFor(wide.windowID), h.rightWorkspace)
        XCTAssertTrue(h.tree(h.right).contains(wide.windowID))
        XCTAssertFalse(h.tree(h.left).contains(wide.windowID))
        XCTAssertEqual(h.recoveryCancelled, [wide.windowID])
        XCTAssertEqual(h.exemptionsEnded, [wide.windowID])
    }
}

private final class PlacementLeftScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 1600, height: 1000) }
    override var visibleFrame: NSRect { frame }
    override var localizedName: String { "placement-left" }
}

/// wider than the left one, so a window too wide for the left fits here
private final class PlacementRightScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 1600, y: 0, width: 2400, height: 1000) }
    override var visibleFrame: NSRect { frame }
    override var localizedName: String { "placement-right" }
}

private final class PlacementFramedWindow: HyprWindow {
    var storedFrame: CGRect {
        didSet { cachedFrame = storedFrame }
    }
    init(id: CGWindowID, pid: pid_t, frame: CGRect) {
        storedFrame = frame
        super.init(element: AXUIElementCreateApplication(pid), windowID: id, ownerPID: pid)
        cachedFrame = frame
    }
    override func readPosition() -> (AXError, CGPoint?) { (.success, storedFrame.origin) }
    override func readSize() -> (AXError, CGSize?) { (.success, storedFrame.size) }
}
