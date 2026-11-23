import XCTest
import Cocoa
@testable import HyprMac

// issue #102: a layout key the engine refuses and rolls back shakes the
// window that would not fit, once per press. background passes stay quiet.

final class RefusedLayoutFeedbackTests: XCTestCase {

    private var screen: NSScreen!
    private var workspace: Int!
    private var io: MisfitFrameIO!
    private var tilingEngine: TilingEngine!
    private var stateCache: WindowStateCache!
    private var dispatcher: ActionDispatcher!
    private var shakes: [(id: CGWindowID, frame: CGRect, message: String)] = []

    override func setUpWithError() throws {
        // the dispatcher falls back to the first screen for a window with no
        // readable frame, which every fixture window is
        let displayManager = DisplayManager()
        guard let primary = displayManager.screens.first else {
            throw XCTSkip("no NSScreen available — test requires a display")
        }
        screen = primary
        io = MisfitFrameIO()
        stateCache = WindowStateCache()
        let suppressions = SuppressionRegistry()
        let focusBorder = FocusBorder()
        let focusController = FocusStateController(focusBorder: focusBorder)
        let accessibility = AccessibilityManager()
        let cursorManager = CursorManager()
        let workspaceManager = WorkspaceManager(displayManager: displayManager)
        tilingEngine = TilingEngine(displayManager: displayManager,
                                    frameSizingIOFactory: io.factory())
        let orchestrator = WorkspaceOrchestrator(
            workspaceManager: workspaceManager, tilingEngine: tilingEngine,
            accessibility: accessibility, displayManager: displayManager,
            cursorManager: cursorManager, stateCache: stateCache,
            focusController: focusController, focusBorder: focusBorder,
            dimmingOverlay: DimmingOverlay(), suppressions: suppressions,
            revalidation: MinimaRevalidation())
        let floating = FloatingWindowController(
            stateCache: stateCache, suppressions: suppressions,
            workspaceManager: workspaceManager, tilingEngine: tilingEngine,
            displayManager: displayManager, accessibility: accessibility,
            cursorManager: cursorManager, focusController: focusController,
            focusBorder: focusBorder, dimmingOverlay: DimmingOverlay())
        dispatcher = ActionDispatcher(
            stateCache: stateCache, accessibility: accessibility,
            displayManager: displayManager, cursorManager: cursorManager,
            workspaceManager: workspaceManager, tilingEngine: tilingEngine,
            focusController: focusController, focusBorder: focusBorder,
            keybindOverlay: KeybindOverlayController(), appLauncher: AppLauncherManager(),
            workspaceOrchestrator: orchestrator, floatingController: floating,
            config: UserConfig())
        shakes = []
        dispatcher.layoutRefused = { [unowned self] id, frame, message in
            shakes.append((id, frame, message))
        }
        workspace = workspaceManager.workspaceForScreen(screen)
    }

    /// Two columns, laid out and standing on their tiles. 1 is focused.
    private func seed(_ ids: [CGWindowID] = [1, 2]) -> [HyprWindow] {
        let windows = ids.map { makeWindow(id: $0) }
        let layouts = tilingEngine.seedTree(windows, onWorkspace: workspace, screen: screen)
        for (window, frame) in layouts { io.place(window.windowID, at: frame) }
        dispatcher.currentFocusedWindow = { windows[0] }
        return windows
    }

    func testARefusedToggleSplitShakesTheWindowThatDidNotFit() {
        _ = seed()
        let standing = io.frame(2)
        io.fixedSize = 2

        dispatcher.dispatch(.toggleSplit)

        XCTAssertEqual(shakes.map(\.id), [2], "one shake, on the window that kept its size, not the focused one")
        XCTAssertEqual(shakes.first?.frame, standing, "the shake sits where the rollback left the window")
        XCTAssertEqual(io.frame(2), standing, "precondition: the layout was rolled back")
    }

    func testAnAcceptedToggleSplitDoesNotShake() {
        _ = seed()

        dispatcher.dispatch(.toggleSplit)

        XCTAssertTrue(shakes.isEmpty)
        XCTAssertNotEqual(io.sizeWrites, 0, "precondition: the toggle laid out new frames")
    }

    /// 2 has to grow and can't. (Asked to shrink instead, its width becomes
    /// a floor and the adjusted pass is accepted: no rollback, no shake.)
    func testARefusedResizeShakesTheWindowThatDidNotFit() {
        _ = seed()
        io.fixedSize = 2

        dispatcher.dispatch(.resizeDirection(.left))

        XCTAssertEqual(shakes.map(\.id), [2])
    }

    /// An app that did not answer in time refused nothing.
    func testAToggleSplitRolledBackOnAnAXTimeoutDoesNotShake() {
        _ = seed()
        let standing = io.frame(2)
        io.timesOut = 2

        dispatcher.dispatch(.toggleSplit)

        XCTAssertTrue(shakes.isEmpty, "a timeout is not a refusal")
        XCTAssertNotEqual(io.timedOutWrites, 0, "precondition: the write timed out")
        XCTAssertEqual(io.frame(2), standing, "precondition: the layout was rolled back")
    }

    /// A close retiles the rest. The survivor that will not grow refuses the
    /// pass, and nobody pressed a key.
    func testABackgroundRetileRefusalDoesNotShake() {
        let windows = seed([1, 2, 3])
        io.fixedSize = 2
        var results: [TilingEngine.AdmissionResult] = []
        dispatcher.retile = { [unowned self] _ in
            let result = tilingEngine.tileWindows(Array(windows.prefix(2)),
                                                  onWorkspace: workspace, screen: screen)
            results.append(result)
            return [result]
        }

        _ = dispatcher.applyChanges(
            WindowChanges(newWindows: [], newOnDisabledMonitor: [], returned: [], goneIDs: [3],
                          fullyForgottenIDs: [], screenDrift: [], focusedWindowGone: false,
                          requestsRecheck: false),
            allWindows: Array(windows.prefix(2)))

        XCTAssertNotNil(results.first?.failure, "precondition: the background pass was refused")
        XCTAssertTrue(shakes.isEmpty)
    }

    // MARK: - which window a refusal names

    private func restored(_ reason: FrameSizingFailure,
                          frames: [CGWindowID: CGRect] = [:]) -> TilingEngine.LayoutApplicationOutcome {
        .rejectedRestored(reason: reason, actualFrames: frames, progress: FrameSizingProgressReport())
    }

    func testTheRefusalTargetIsTheWindowTheFailureNames() {
        let target = ActionDispatcher.refusalTarget
        XCTAssertEqual(target(restored(.geometryMismatch(7)), 1), 7)
        XCTAssertEqual(target(restored(.outsideUsableFrame(7)), 1), 7)
        // Dia turning a size down
        XCTAssertEqual(target(restored(.writeFailed(7, .attributeUnsupported)), 1), 7)
        XCTAssertEqual(target(restored(.cleanupFailed(9, primary: .geometryMismatch(7), error: .failure)), 1), 7)
    }

    /// A pair that only failed together has no one window at fault: the
    /// shake goes on the window the key acted on.
    func testAPairRefusalShakesTheFocusedWindow() {
        let target = ActionDispatcher.refusalTarget
        XCTAssertEqual(target(restored(.overlap(7, 8)), 1), 1)
        XCTAssertEqual(target(restored(.gapViolation(7, 8)), 1), 1)
    }

    func testFailuresThatRefuseNothingDoNotShake() {
        let target = ActionDispatcher.refusalTarget
        for reason: FrameSizingFailure in [
            .writeFailed(7, .cannotComplete), .readFailed(7, .cannotComplete), .readFailed(7, .failure),
            .writeFailed(7, .invalidUIElement), .windowUnavailable(7), .deadlineExceeded,
            .attemptsExhausted, .superseded,
            .cleanupFailed(9, primary: .writeFailed(7, .cannotComplete), error: .cannotComplete),
        ] {
            XCTAssertNil(target(restored(reason), 1), "\(reason)")
        }
        XCTAssertNil(target(nil, 1), "nothing was laid out")
        XCTAssertNil(target(.accepted(actualFrames: [:], progress: FrameSizingProgressReport()), 1))
        XCTAssertNil(target(.degraded(candidateReason: .superseded, restorationReason: nil,
                                      restorationAttempted: false, actualFrames: [:],
                                      progress: FrameSizingProgressReport()), 1))
    }
}

/// Every window lands where it is sent, except `fixedSize`, which keeps its
/// size like an app with a fixed window, and `timesOut`, whose resizes come
/// back as an AX timeout.
private final class MisfitFrameIO {
    var fixedSize: CGWindowID?
    var timesOut: CGWindowID?
    private(set) var sizeWrites = 0
    private(set) var timedOutWrites = 0
    private var positions: [CGWindowID: CGPoint] = [:]
    private var sizes: [CGWindowID: CGSize] = [:]
    // the readback judges an off-target window only after its settle time
    private var clock: TimeInterval = 0

    func place(_ id: CGWindowID, at frame: CGRect) {
        positions[id] = frame.origin
        sizes[id] = frame.size
    }

    func frame(_ id: CGWindowID) -> CGRect {
        CGRect(origin: positions[id] ?? .zero, size: sizes[id] ?? .zero)
    }

    func factory() -> ([CGWindowID: HyprWindow], @escaping () -> UInt64) -> FrameSizingIO {
        { [self] _, generation in
            FrameSizingIO(
                setMessagingTimeout: { _, _ in .success },
                writeSize: { [self] id, size, _ in
                    sizeWrites += 1
                    if id == timesOut, size != sizes[id] {
                        timedOutWrites += 1
                        return .cannotComplete
                    }
                    if id != fixedSize { sizes[id] = size }
                    return .success
                },
                writePosition: { [self] id, position, _ in positions[id] = position; return .success },
                readPosition: { [self] id, _ in (.success, positions[id] ?? .zero) },
                readSize: { [self] id, _ in (.success, sizes[id] ?? CGSize(width: 100, height: 100)) },
                now: { [self] in clock }, sleep: { [self] in clock += $0 },
                currentGeneration: generation
            )
        }
    }
}
