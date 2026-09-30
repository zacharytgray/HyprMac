import XCTest
import Cocoa
@testable import HyprMac

// HandleDisplayChangeTests cover the orphan-and-prune path of
// TilingEngine.handleDisplayChange. the migration path requires multiple live
// NSScreen instances and isn't exercised here — it's covered by the manual
// monitor-disconnect smoke test until we have a fake-display harness.
//
// see plan §4.2 (display lifecycle) + §11.

final class HandleDisplayChangeTests: XCTestCase {

    private var displayManager: DisplayManager!
    private var engine: TilingEngine!
    private var screen: NSScreen!

    override func setUpWithError() throws {
        displayManager = DisplayManager()
        engine = TilingEngine(displayManager: displayManager)
        guard let main = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("no NSScreen available — test requires a display")
        }
        screen = main
    }

    func testHandleDisplayChangePrunesOrphanedTrees() {
        // seed a tree
        engine.prepareTileLayout([makeWindow(id: 1), makeWindow(id: 2)],
                                 onWorkspace: 1, screen: screen)
        XCTAssertNotNil(engine.existingTree(forWorkspace: 1, screen: screen))

        // simulate the screen vanishing with no home-screen destination
        engine.handleDisplayChange(currentScreens: [], homeScreenForWorkspace: { _ in nil })

        // tree should be pruned
        XCTAssertNil(engine.existingTree(forWorkspace: 1, screen: screen))
    }

    func testAMigratedTreeCarriesItsUnverifiedMark() throws {
        let trace = MigrationTrace()
        let engine = TilingEngine(displayManager: DisplayManager(),
                                  frameSizingIOFactory: { _, generation in trace.io(generation) })
        let windows = (961...962).map {
            HyprWindow(element: AXUIElementCreateApplication(99996), windowID: CGWindowID($0),
                       ownerPID: 99996)
        }
        let usable = engine.displayManager.cgRect(for: screen)
        for (index, window) in windows.enumerated() {
            trace.frames[window.windowID] = CGRect(x: usable.minX + 20 + CGFloat(index) * 150,
                                                   y: usable.minY + 20, width: 120, height: 120)
        }
        engine.tileWindows(windows, onWorkspace: 1, screen: screen)
        XCTAssertFalse(engine.intendedTileRects().isEmpty)

        trace.rejectNextRead = true
        engine.tileWindows(windows, onWorkspace: 1, screen: screen)
        XCTAssertTrue(engine.intendedTileRects().isEmpty)

        // the workspace's home moves to a screen that is not in the manager's
        // live list, so the tree migrates and the claim has to go with it
        let destination = MigrationScreen()
        engine.handleDisplayChange(currentScreens: [screen, destination],
                                   homeScreenForWorkspace: { _ in destination })

        XCTAssertNotNil(engine.existingTree(forWorkspace: 1, screen: destination))
        XCTAssertEqual(engine.unverifiedGeometryWindowIDs, Set(windows.map(\.windowID)),
                       "a migrated tree has still never had a layout accepted")
    }

    func testHandleDisplayChangeIsNoopWhenTreeOnItsHome() {
        engine.prepareTileLayout([makeWindow(id: 1), makeWindow(id: 2)],
                                 onWorkspace: 1, screen: screen)
        let tree = engine.existingTree(forWorkspace: 1, screen: screen)
        XCTAssertNotNil(tree)
        let countBefore = tree?.allWindows.count

        // a tree already sitting on its workspace's current home is left alone.
        // (a nil home means "no live home" and prunes — covered above.)
        engine.handleDisplayChange(currentScreens: [screen], homeScreenForWorkspace: { _ in self.screen })

        XCTAssertNotNil(engine.existingTree(forWorkspace: 1, screen: screen))
        XCTAssertEqual(engine.existingTree(forWorkspace: 1, screen: screen)?.allWindows.count, countBefore)
    }
}

final class FitAwareDisplayMigrationTests: XCTestCase {
    func testCollidingMigrationsDoNotMergeWindowsWhoseKnownMinimumsCannotFit() throws {
        let left = CollisionScreen(x: 0, width: 1400)
        let right = CollisionScreen(x: 2000, width: 1400)
        let destination = CollisionScreen(x: 4000, width: 1400)
        let displayManager = DisplayManager(screenSource: { [left, right, destination] })
        let engine = TilingEngine(displayManager: displayManager)
        let first = makeWindow(id: 971)
        let second = makeWindow(id: 972)
        first.observedMinSize = CGSize(width: 1000, height: 500)
        second.observedMinSize = CGSize(width: 1000, height: 500)

        engine.prepareTileLayout([first], onWorkspace: 1, screen: left)
        engine.prepareTileLayout([second], onWorkspace: 1, screen: right)

        engine.handleDisplayChange(currentScreens: [destination],
                                   homeScreenForWorkspace: { _ in destination })

        let migrated = try XCTUnwrap(engine.existingTree(forWorkspace: 1,
                                                         screen: destination))
        XCTAssertEqual(migrated.allWindows.count, 1,
                       "migration must use the same geometric fit decision as admission")
    }
}

private final class MigrationScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 6000, y: 0, width: 1400, height: 900) }
    override var visibleFrame: NSRect { frame }
}

private final class CollisionScreen: SyntheticScreen {
    let bounds: NSRect

    init(x: CGFloat, width: CGFloat) {
        bounds = NSRect(x: x, y: 0, width: width, height: 900)
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var frame: NSRect { bounds }
    override var visibleFrame: NSRect { bounds }
}

private final class MigrationTrace {
    var frames: [CGWindowID: CGRect] = [:]
    var rejectNextRead = false
    private var wrote = false
    private var now: TimeInterval = 0

    func io(_ generation: @escaping () -> UInt64) -> FrameSizingIO {
        FrameSizingIO(setMessagingTimeout: { _, _ in .success },
                      writeSize: { [self] id, size, _ in wrote = true; frames[id]?.size = size; return .success },
                      writePosition: { [self] id, position, _ in frames[id]?.origin = position; return .success },
                      readPosition: { [self] id, _ in
                          if wrote && rejectNextRead { rejectNextRead = false; return (.cannotComplete, nil) }
                          return (.success, frames[id]?.origin)
                      },
                      readSize: { [self] id, _ in (.success, frames[id]?.size) },
                      now: { [self] in now }, sleep: { [self] in now += $0 },
                      currentGeneration: generation)
    }
}

final class DisplaySnapshotTests: XCTestCase {
    func testFingerprintRefreshesAChangedProviderWithoutNotification() {
        let first = SnapshotScreen()
        let second = SnapshotScreen()
        second.bounds.size.width = 1512
        var provided: [NSScreen] = [first]
        let manager = DisplayManager(screenSource: { provided })
        let before = manager.refreshedFingerprint()
        provided = [second]
        XCTAssertNotEqual(manager.refreshedFingerprint(), before)
        XCTAssertEqual(manager.screens.first?.frame.width, 1512)
    }

    func testOnePointUsableFrameNoiseKeepsTheSameFingerprint() {
        let screen = SnapshotScreen()
        let manager = DisplayManager(screenSource: { [screen] })
        let before = manager.refreshedFingerprint()
        screen.usable = screen.bounds.offsetBy(dx: 0, dy: 1)
        XCTAssertEqual(manager.refreshedFingerprint(), before)
        screen.usable = screen.bounds.offsetBy(dx: 0, dy: 2)
        XCTAssertNotEqual(manager.refreshedFingerprint(), before, "noise cannot accumulate against a moving anchor")
    }

    func testASymmetricOnePointInsetChangesTheFingerprint() {
        let screen = SnapshotScreen()
        let manager = DisplayManager(screenSource: { [screen] })
        let before = manager.refreshedFingerprint()
        // each edge moves one point, so every edge delta is inside the slack,
        // but the usable area is two points narrower
        screen.usable = screen.bounds.insetBy(dx: 1, dy: 0)
        XCTAssertNotEqual(manager.refreshedFingerprint(), before)
    }

    func testUsableBoundsChangeTheFingerprintAndTheDisplayIDDoesNot() {
        let screen = SnapshotScreen()
        let manager = DisplayManager(screenSource: { [screen] })
        let before = manager.refreshedFingerprint()
        screen.usable = screen.bounds.insetBy(dx: 0, dy: 25)
        let inset = manager.refreshedFingerprint()
        XCTAssertNotEqual(inset, before)
        // the id a display comes back with after a wake is not a new desk;
        // the same name at the same frame is the same monitor
        screen.displayID = 42
        XCTAssertEqual(manager.refreshedFingerprint(), inset)
    }
}

private final class SnapshotScreen: SyntheticScreen {
    var bounds = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    var usable: NSRect?
    var displayID = 41
    override var frame: NSRect { bounds }
    override var visibleFrame: NSRect { usable ?? bounds }
    override var localizedName: String { "Test display" }
    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): NSNumber(value: displayID)]
    }
}

private final class DeskScreen: SyntheticScreen {
    let bounds: NSRect
    let name: String?
    init(x: CGFloat, width: CGFloat, name: String? = nil) {
        bounds = NSRect(x: x, y: 0, width: width, height: 900)
        self.name = name
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var frame: NSRect { bounds }
    override var visibleFrame: NSRect { bounds }
    override var localizedName: String { name ?? super.localizedName }
}

final class DisplayReturnTests: XCTestCase {
    /// an external monitor that leaves for a sleep and comes back showed
    /// its lowest home workspace on return, which hid the one the user was
    /// on and parked its windows. it shows what it showed before it left
    func testAReturningScreenShowsTheWorkspaceItLastShowed() {
        let laptop = DeskScreen(x: 0, width: 1400)
        let external = DeskScreen(x: 1400, width: 1920)
        var live: [NSScreen] = [laptop, external]
        let display = DisplayManager(screenSource: { live })
        let workspaces = WorkspaceManager(displayManager: display)
        workspaces.initializeMonitors()
        _ = workspaces.switchWorkspace(4, cursorScreen: external)
        XCTAssertEqual(workspaces.workspaceForScreen(external), 4)

        live = [laptop]
        display.refresh()
        workspaces.initializeMonitors()
        XCTAssertFalse(workspaces.isWorkspaceVisible(4), "one screen: ws4 is hidden")

        live = [laptop, external]
        display.refresh()
        workspaces.initializeMonitors()

        XCTAssertEqual(workspaces.workspaceForScreen(external), 4)
        XCTAssertEqual(workspaces.workspaceForScreen(laptop), 1)
    }

    /// two displays of one model share a name. the one that leaves comes
    /// back on its own workspace, not on the other's
    func testTwoSameNamedDisplaysRememberTheirWorkspacesApart() {
        let laptop = DeskScreen(x: 0, width: 1400)
        let left = DeskScreen(x: 1400, width: 1920, name: "LG HDR 4K")
        let right = DeskScreen(x: 3320, width: 1920, name: "LG HDR 4K")
        var live: [NSScreen] = [laptop, left, right]
        let display = DisplayManager(screenSource: { live })
        let workspaces = WorkspaceManager(displayManager: display)
        workspaces.initializeMonitors()
        _ = workspaces.switchWorkspace(5, cursorScreen: left)
        _ = workspaces.switchWorkspace(6, cursorScreen: right)
        XCTAssertEqual(workspaces.workspaceForScreen(left), 5)
        XCTAssertEqual(workspaces.workspaceForScreen(right), 6)

        live = [laptop, left]
        display.refresh()
        workspaces.initializeMonitors()
        live = [laptop, left, right]
        display.refresh()
        workspaces.initializeMonitors()

        XCTAssertEqual(workspaces.workspaceForScreen(right), 6)
        XCTAssertEqual(workspaces.workspaceForScreen(left), 5)
    }

    /// a park write the app refuses asks for the repair poll a few times,
    /// not every 0.3 s for as long as the app refuses
    func testAParkWriteThatKeepsFailingAsksForTheRepairPollAFewTimes() {
        let screen = DeskScreen(x: 0, width: 1400)
        let workspaces = WorkspaceManager(displayManager: DisplayManager(screenSource: { [screen] }))
        var requests = 0
        workspaces.onParkFailed = { requests += 1 }
        // its AX element answers nothing, so every write fails
        let window = makeWindow(id: 4711)

        for _ in 0..<(WorkspaceManager.parkRepairRequests + 3) {
            workspaces.hideInCorner(window, on: screen)
        }

        XCTAssertEqual(requests, WorkspaceManager.parkRepairRequests)
    }

    /// NSScreen.screens comes back in another order after some wakes, and
    /// the display id changes; neither is a new desk
    func testTheDisplayFingerprintIgnoresScreenOrderAndIDs() {
        let a = DeskScreen(x: 0, width: 1400)
        let b = DeskScreen(x: 1400, width: 1920)
        let forward = DisplayManager(screenSource: { [a, b] }).refreshedFingerprint()
        let backward = DisplayManager(screenSource: { [b, a] }).refreshedFingerprint()
        XCTAssertEqual(forward, backward)
        XCTAssertFalse(forward.contains("NSScreenNumber"))
    }
}
