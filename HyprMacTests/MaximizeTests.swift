import Cocoa
import XCTest
@testable import HyprMac

// maximize draws one window over its tree. the tree, and the other tiles'
// frames, must come through untouched. live behavior isn't checked here.

final class MaximizeEngineTests: XCTestCase {

    /// frames by id. a window with a cap won't grow past it.
    private final class FakeWindows {
        var frames: [CGWindowID: CGRect] = [:]
        var caps: [CGWindowID: CGSize] = [:]
        var writes: [CGWindowID] = []
        var now: TimeInterval = 0

        func io(_ generation: @escaping () -> UInt64) -> FrameSizingIO {
            FrameSizingIO(
                setMessagingTimeout: { _, _ in .success },
                writeSize: { [self] id, size, _ in
                    writes.append(id)
                    var frame = frames[id] ?? .zero
                    let cap = caps[id] ?? CGSize(width: .max, height: .max)
                    frame.size = CGSize(width: min(size.width, cap.width), height: min(size.height, cap.height))
                    frames[id] = frame
                    return .success
                },
                writePosition: { [self] id, position, _ in
                    writes.append(id)
                    var frame = frames[id] ?? .zero
                    frame.origin = position
                    frames[id] = frame
                    return .success
                },
                readPosition: { [self] id, _ in (.success, frames[id]?.origin ?? .zero) },
                readSize: { [self] id, _ in (.success, frames[id]?.size ?? CGSize(width: 100, height: 100)) },
                now: { [self] in now }, sleep: { [self] in now += $0 },
                currentGeneration: generation)
        }
    }

    private var fake: FakeWindows!
    private var engine: TilingEngine!
    private var screen: NSScreen!
    private let a = makeWindow(id: 1)
    private let b = makeWindow(id: 2)
    private let c = makeWindow(id: 3)

    override func setUpWithError() throws {
        let display = DisplayManager()
        guard let main = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("no NSScreen available — test requires a display")
        }
        screen = main
        let fake = FakeWindows()
        self.fake = fake
        engine = TilingEngine(displayManager: display, frameSizingIOFactory: { _, generation in
            fake.io(generation)
        })
    }

    private func tile(_ windows: [HyprWindow]) {
        engine.tileWindows(windows, onWorkspace: 1, screen: screen)
    }

    private var full: CGRect { engine.fullFrame(onWorkspace: 1, screen: screen) }

    private func tiledThenMaximizedA() -> (a: CGRect, b: CGRect) {
        tile([a, b])
        let slots = (a: fake.frames[1]!, b: fake.frames[2]!)
        XCTAssertEqual(engine.maximize(a, onWorkspace: 1, screen: screen), .maximized)
        return slots
    }

    func testMaximizeWritesOnlyThatWindow() {
        let slots = tiledThenMaximizedA()
        XCTAssertEqual(fake.frames[1], full)
        XCTAssertEqual(fake.frames[2], slots.b)
        XCTAssertNotEqual(slots.a, full)
        XCTAssertEqual(engine.maximizedWindowID(onWorkspace: 1, screen: screen), 1)
        XCTAssertTrue(engine.isMaximized(1))
        XCTAssertTrue(engine.isCoveredByMaximized(2))
        XCTAssertFalse(engine.isCoveredByMaximized(1))
    }

    func testEndPutsTheTileBackWithTheSameTree() {
        let slots = tiledThenMaximizedA()
        XCTAssertTrue(engine.endMaximize(onWorkspace: 1, screen: screen))
        XCTAssertEqual(fake.frames[1], slots.a)
        XCTAssertEqual(fake.frames[2], slots.b)
        XCTAssertNil(engine.maximizedWindowID(onWorkspace: 1, screen: screen))
        XCTAssertFalse(engine.endMaximize(onWorkspace: 1, screen: screen))
    }

    func testRetileKeepsItMaximizedAndTheOthersInTheirSlots() {
        let slots = tiledThenMaximizedA()
        fake.frames[2] = CGRect(x: 5, y: 5, width: 50, height: 50)
        tile([a, b])
        XCTAssertEqual(fake.frames[1], full)
        XCTAssertEqual(fake.frames[2], slots.b)
        XCTAssertTrue(engine.isMaximized(1))
    }

    // back from a hidden workspace, every window comes out of the parking corner
    func testComingBackFromParkedRestoresBoth() {
        let slots = tiledThenMaximizedA()
        fake.frames[1] = CGRect(x: 3000, y: 2000, width: 400, height: 300)
        fake.frames[2] = CGRect(x: 3000, y: 2000, width: 400, height: 300)
        tile([a, b])
        XCTAssertEqual(fake.frames[1], full)
        XCTAssertEqual(fake.frames[2], slots.b)
    }

    func testNewWindowEndsIt() {
        _ = tiledThenMaximizedA()
        tile([a, b, c])
        XCTAssertNil(engine.maximizedWindowID(onWorkspace: 1, screen: screen))
        XCTAssertEqual(engine.existingTree(forWorkspace: 1, screen: screen)?.allWindows.count, 3)
        XCTAssertNotEqual(fake.frames[1], full)
    }

    func testClosingTheMaximizedWindowEndsIt() {
        _ = tiledThenMaximizedA()
        engine.removeWindowID(1)
        XCTAssertNil(engine.maximizedWindowID(onWorkspace: 1, screen: screen))
        XCTAssertFalse(engine.isCoveredByMaximized(2))
    }

    func testLastTileUnderItClosingEndsItAtTheSameFrame() {
        _ = tiledThenMaximizedA()
        engine.removeWindowID(2)
        tile([a])
        XCTAssertNil(engine.maximizedWindowID(onWorkspace: 1, screen: screen))
        XCTAssertEqual(fake.frames[1], full)
    }

    func testOtherTileClosingKeepsIt() {
        tile([a, b, c])
        XCTAssertEqual(engine.maximize(a, onWorkspace: 1, screen: screen), .maximized)
        engine.removeWindowID(3)
        tile([a, b])
        XCTAssertTrue(engine.isMaximized(1))
        XCTAssertEqual(fake.frames[1], full)
    }

    func testMinimizedMaximizedWindowLeavingTheTreeEndsIt() {
        _ = tiledThenMaximizedA()
        tile([b])
        XCTAssertNil(engine.maximizedWindowID(onWorkspace: 1, screen: screen))
    }

    func testLoneWindowAlreadyFills() {
        tile([a])
        XCTAssertEqual(engine.maximize(a, onWorkspace: 1, screen: screen), .alreadyFills)
        XCTAssertNil(engine.maximizedWindowID(onWorkspace: 1, screen: screen))
    }

    func testWindowOutsideTheTreeIsRefused() {
        tile([a, b])
        XCTAssertEqual(engine.maximize(c, onWorkspace: 1, screen: screen), .refused)
    }

    func testWindowThatCannotFillIsRefusedAndStaysInItsSlot() {
        tile([a, b])
        let slot = fake.frames[1]!
        fake.caps[1] = slot.size
        XCTAssertEqual(engine.maximize(a, onWorkspace: 1, screen: screen), .refused)
        XCTAssertNil(engine.maximizedWindowID(onWorkspace: 1, screen: screen))
        XCTAssertEqual(fake.frames[1], slot)
    }

    func testWindowThatStopsFillingGoesBackToItsTile() {
        let slots = tiledThenMaximizedA()
        fake.frames[1] = slots.a
        fake.caps[1] = slots.a.size
        tile([a, b])
        XCTAssertNil(engine.maximizedWindowID(onWorkspace: 1, screen: screen))
        XCTAssertEqual(fake.frames[1], slots.a)
        XCTAssertEqual(fake.frames[2], slots.b)
    }

    func testDisplayChangeForgetsIt() {
        _ = tiledThenMaximizedA()
        engine.handleDisplayChange(currentScreens: [screen!], homeScreenForWorkspace: { _ in self.screen })
        XCTAssertNil(engine.maximizedWindowID(onWorkspace: 1))
    }

    func testEndAllEndsEveryWorkspace() {
        let slots = tiledThenMaximizedA()
        engine.endAllMaximized()
        XCTAssertNil(engine.maximizedWindowID(onWorkspace: 1))
        XCTAssertEqual(fake.frames[1], slots.a)
    }

    func testOffTargetFollowsTheDriftTolerances() {
        _ = tiledThenMaximizedA()
        XCTAssertTrue(engine.maximizedOffTarget(liveFrame: { _ in self.full }).isEmpty)
        let nudged = full.offsetBy(dx: 0.5, dy: 0)
        XCTAssertTrue(engine.maximizedOffTarget(liveFrame: { _ in nudged }).isEmpty)
        let dragged = full.offsetBy(dx: 40, dy: 0)
        XCTAssertEqual(engine.maximizedOffTarget(liveFrame: { _ in dragged }).map(\.workspace), [1])
        XCTAssertTrue(engine.maximizedOffTarget(liveFrame: { _ in nil }).isEmpty)
    }

    func testLocationFindsTheWindowAndTheTilesUnderIt() {
        _ = tiledThenMaximizedA()
        XCTAssertEqual(engine.maximizeLocation(involving: 1)?.workspace, 1)
        XCTAssertEqual(engine.maximizeLocation(involving: 2)?.workspace, 1)
        XCTAssertNil(engine.maximizeLocation(involving: 3))
    }

    func testEveryStartAndEndIsReported() {
        var changes: [String] = []
        engine.onMaximizeChanged = { workspace, screen, isOn in
            XCTAssertNotNil(screen)
            changes.append("\(workspace) \(isOn)")
        }
        _ = tiledThenMaximizedA()
        XCTAssertEqual(engine.maximizedWorkspaces, [1])
        engine.endMaximize(onWorkspace: 1, screen: screen)
        _ = engine.maximize(a, onWorkspace: 1, screen: screen)
        tile([a, b, c])
        _ = engine.maximize(a, onWorkspace: 1, screen: screen)
        engine.removeWindowID(1)
        XCTAssertEqual(changes, ["1 true", "1 false", "1 true", "1 false", "1 true", "1 false"])
        XCTAssertEqual(engine.maximizedWorkspaces, [])
    }

    func testTiledDragIsNotCapturedWhileMaximized() {
        _ = tiledThenMaximizedA()
        let result = engine.captureTiledDrag(draggedID: 1, workspace: 1, screen: screen, floatingIDs: [])
        guard case .ineligible = result else { return XCTFail("expected ineligible, got \(result)") }
    }
}

final class MaximizePolicyTests: XCTestCase {
    func testHUDSaysOnAndOff() {
        XCTAssertEqual(WorkspaceOverviewPresentation.fullscreenHUDText(isOn: true).caption, "FULLSCREEN")
        XCTAssertEqual(WorkspaceOverviewPresentation.fullscreenHUDText(isOn: true).number, "On")
        XCTAssertEqual(WorkspaceOverviewPresentation.fullscreenHUDText(isOn: false).number, "Off")
    }

    func testActionsThatReworkTheTreeEndIt() {
        for action: Action in [.swapDirection(.left), .resizeDirection(.left), .toggleSplit, .toggleFloating,
                               .moveToWorkspace(2), .moveToWorkspaceAndFollow(2), .moveWindowToMonitor(.left),
                               .moveToNextEmptyWorkspace, .moveToScratchpad, .restoreLayout, .retileAll] {
            XCTAssertTrue(ActionPolicy.endsMaximize(action), "\(action)")
        }
    }

    func testActionsThatLeaveTheTreeAloneKeepIt() {
        for action: Action in [.toggleMaximize, .switchWorkspace(2), .cycleWorkspace(1), .focusDirection(.left),
                               .closeWindow, .toggleScratchpad, .saveLayout, .showKeybinds] {
            XCTAssertFalse(ActionPolicy.endsMaximize(action), "\(action)")
        }
    }

    func testWaitsOutADisplayTransitionAndKeepsRecovery() {
        XCTAssertTrue(ActionPolicy.isDroppedMidDisplayTransition(.toggleMaximize))
        XCTAssertFalse(ActionPolicy.cancelsPendingRecovery(.toggleMaximize))
    }
}
