import XCTest
import Cocoa
@testable import HyprMac

// pins what WorkspaceOrchestrator.moveToWorkspace does with a destination that
// refuses the window: a structural refusal never touches the screen and leaves
// the window where it was, and a refusal by learned bounds alone buys one
// revalidation — parked for the reveal when the destination is hidden, because
// unparking its tenants over the visible workspace to run an experiment is not
// what the user asked for.

final class WorkspaceOrchestratorMoveTests: XCTestCase {

    private var displayManager: DisplayManager!
    private var workspaceManager: WorkspaceManager!
    private var tilingEngine: TilingEngine!
    private var stateCache: WindowStateCache!
    private var revalidation: MinimaRevalidation!
    private var orchestrator: WorkspaceOrchestrator!
    private var trace: MoveTrace!
    private var screen: NSScreen!
    private var source: Int!
    private var destination: Int!
    private var elsewhere: Int!

    override func setUpWithError() throws {
        let dm = DisplayManager()
        guard let primary = dm.screens.first else {
            throw XCTSkip("no NSScreen available — test requires a display")
        }
        screen = primary
        displayManager = dm
        trace = MoveTrace()
        stateCache = WindowStateCache()
        workspaceManager = WorkspaceManager(displayManager: displayManager)
        tilingEngine = TilingEngine(displayManager: displayManager,
                                    frameSizingIOFactory: { _, generation in self.trace.io(generation) })
        revalidation = MinimaRevalidation()
        revalidation.workspaceFor = { [weak self] in self?.workspaceManager.workspaceFor($0) }

        let focusBorder = FocusBorder()
        orchestrator = WorkspaceOrchestrator(
            workspaceManager: workspaceManager,
            tilingEngine: tilingEngine,
            accessibility: AccessibilityManager(),
            displayManager: displayManager,
            cursorManager: CursorManager(),
            stateCache: stateCache,
            focusController: FocusStateController(focusBorder: focusBorder),
            focusBorder: focusBorder,
            dimmingOverlay: DimmingOverlay(),
            suppressions: SuppressionRegistry(),
            revalidation: revalidation)
        orchestrator.animatedRetile = { prepare, completion in prepare?(); completion?() }
        orchestrator.tileAllVisibleSpaces = { _ in }
        orchestrator.screenUnderCursor = { [weak self] in self?.screen ?? NSScreen.main! }

        source = workspaceManager.workspaceForScreen(screen)
        // any other workspace anchored to this screen is hidden, which is the
        // only destination a single-display host can offer
        let others = workspaceManager.workspacesAnchoredTo(screen).filter { $0 != source }.sorted()
        try XCTSkipIf(others.count < 2, "needs two more workspaces anchored to this screen")
        destination = others[0]
        elsewhere = others[1]
    }

    /// Seed the hidden destination with one tenant carrying `minimum` under
    /// `provenance`, and return the window the test will try to move there.
    private func seedDestination(minimum: CGSize, provenance: MinSizeProvenance) -> HyprWindow {
        let tenant = makeWindow(id: 801)
        let usable = displayManager.cgRect(for: screen)
        trace.frames[tenant.windowID] = CGRect(x: usable.minX + 20, y: usable.minY + 20,
                                               width: 120, height: 120)
        tilingEngine.prepareTileLayout([tenant], onWorkspace: destination, screen: screen)
        tenant.observedMinSize = minimum
        tenant.minSizeProvenance = provenance
        tilingEngine.primeMinimumSizes([tenant])

        let mover = makeWindow(id: 802)
        trace.frames[mover.windowID] = CGRect(x: usable.minX + 200, y: usable.minY + 20,
                                              width: 120, height: 120)
        workspaceManager.assignWindow(mover.windowID, toWorkspace: source)
        stateCache.cachedWindows[mover.windowID] = mover
        orchestrator.currentFocusedWindow = { mover }
        orchestrator.allWindows = { [tenant, mover] }
        trace.written = []
        return mover
    }

    private func hugeMinimum() -> CGSize {
        let usable = displayManager.cgRect(for: screen)
        return CGSize(width: usable.width * 1.2, height: 0)
    }

    func testALearnedBoundOnAHiddenTenantParksAMarkerInsteadOfWriting() throws {
        let mover = seedDestination(minimum: hugeMinimum(), provenance: .observed)

        orchestrator.moveToWorkspace(destination)

        XCTAssertEqual(revalidation.pendingWindowIDs, [mover.windowID],
                       "the move goes through and the attempt waits for the reveal")
        XCTAssertEqual(revalidation.marker(for: mover.windowID)?.workspace, destination)
        XCTAssertEqual(revalidation.marker(for: mover.windowID)?.sourceWorkspace, source)
        XCTAssertEqual(workspaceManager.workspaceFor(mover.windowID), destination)
        XCTAssertTrue(trace.written.isEmpty,
                      "no hidden tenant is unparked over the visible workspace for an experiment")
    }

    func testASeededBoundRefusesTheMoveAndParksNothing() throws {
        let mover = seedDestination(minimum: hugeMinimum(), provenance: .seeded)

        orchestrator.moveToWorkspace(destination)

        XCTAssertTrue(revalidation.pendingWindowIDs.isEmpty,
                      "a hint nothing has tested is not a learned bound")
        XCTAssertEqual(workspaceManager.workspaceFor(mover.windowID), source,
                       "the window keeps its source workspace")
        XCTAssertTrue(trace.written.isEmpty)
    }

    func testAStructuralRefusalNeverTouchesTheScreen() throws {
        tilingEngine.maxSplitsPerMonitor = [screen.localizedName: 0]
        let mover = seedDestination(minimum: .zero, provenance: .seeded)

        orchestrator.moveToWorkspace(destination)

        XCTAssertTrue(revalidation.pendingWindowIDs.isEmpty)
        XCTAssertEqual(workspaceManager.workspaceFor(mover.windowID), source)
        XCTAssertTrue(trace.written.isEmpty, "a structural refusal never writes")
    }

    func testAFittingDestinationTakesTheWindowWithNoMarker() throws {
        let mover = seedDestination(minimum: .zero, provenance: .seeded)

        orchestrator.moveToWorkspace(destination)

        XCTAssertTrue(revalidation.pendingWindowIDs.isEmpty)
        XCTAssertEqual(workspaceManager.workspaceFor(mover.windowID), destination)
    }

    func testMovingTheSameWindowAgainReplacesItsPendingRevalidation() throws {
        let mover = seedDestination(minimum: hugeMinimum(), provenance: .observed)
        orchestrator.moveToWorkspace(destination)
        XCTAssertEqual(revalidation.pendingWindowIDs, [mover.windowID])

        // on to a third workspace, which has no tree refusing it
        orchestrator.moveToWorkspace(elsewhere)

        XCTAssertEqual(workspaceManager.workspaceFor(mover.windowID), elsewhere)
        XCTAssertTrue(revalidation.pendingWindowIDs.isEmpty,
                      "the older request is not left waiting on a reveal that would undo this one")
    }
}

/// Minimal AX stand-in that records which windows the engine wrote to.
private final class MoveTrace {
    var frames: [CGWindowID: CGRect] = [:]
    var written: Set<CGWindowID> = []
    private var now: TimeInterval = 0

    func io(_ generation: @escaping () -> UInt64) -> FrameSizingIO {
        FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { [self] id, size, _ in written.insert(id); frames[id]?.size = size; return .success },
            writePosition: { [self] id, position, _ in
                written.insert(id); frames[id]?.origin = position; return .success
            },
            readPosition: { [self] id, _ in (.success, frames[id]?.origin) },
            readSize: { [self] id, _ in (.success, frames[id]?.size) },
            now: { [self] in now }, sleep: { [self] in now += $0 },
            currentGeneration: generation)
    }
}
