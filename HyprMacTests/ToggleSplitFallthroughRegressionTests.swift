import XCTest
import Cocoa
@testable import HyprMac

// pins the WindowManager.toggleSplit fallthrough fix that landed in Phase 1.
//
// the bug: prepareToggleSplitLayout mutates the BSP tree (toggles parent
// direction). once it returns non-nil, the action handler is committed.
// before the fix, when prepareToggleSplitLayout returned non-nil but produced
// no animation transitions (e.g., empty layout dict, or windows without
// resolvable from-frames), the code fell through to tilingEngine.toggleSplit(),
// toggling the tree a second time and reverting the user's action.
//
// Phase 1 fix: ensure the action returns after applying the prepared layout,
// regardless of whether transitions were animated. The test was deferred to
// Phase 4 because, until ActionDispatcher landed, WindowManager's action path
// had no DI seam to drive in isolation.
//
// see plan §4.2 + §8.2.

final class ToggleSplitFallthroughRegressionTests: XCTestCase {

    private var displayManager: DisplayManager!
    private var tilingEngine: TilingEngine!
    private var workspaceManager: WorkspaceManager!
    private var stateCache: WindowStateCache!
    private var suppressions: SuppressionRegistry!
    private var focusBorder: FocusBorder!
    private var focusController: FocusStateController!
    private var dimmingOverlay: DimmingOverlay!
    private var animator: WindowAnimator!
    private var accessibility: AccessibilityManager!
    private var cursorManager: CursorManager!
    private var keybindOverlay: KeybindOverlayController!
    private var appLauncher: AppLauncherManager!
    private var workspaceOrchestrator: WorkspaceOrchestrator!
    private var floatingController: FloatingWindowController!
    private var dispatcher: ActionDispatcher!
    private var config: UserConfig!
    private var screen: NSScreen!
    private var workspace: Int!

    override func setUpWithError() throws {
        // use displayManager.screens.first to match the dispatcher's resolution path:
        // ActionDispatcher.toggleSplit falls back to displayManager.screens.first when
        // a window has no frame (which is true for our test fixtures). picking
        // NSScreen.main here would mismatch on a multi-monitor host where main is
        // not the first screen.
        let dm = DisplayManager()
        guard let primary = dm.screens.first else {
            throw XCTSkip("no NSScreen available — test requires a display")
        }
        screen = primary

        config = UserConfig()
        // animateWindows = true is required to exercise the buggy branch.
        // prepareToggleSplitLayout only runs when animation is enabled.
        config.animateWindows = true

        displayManager = DisplayManager()
        stateCache = WindowStateCache()
        suppressions = SuppressionRegistry()
        focusBorder = FocusBorder()
        focusController = FocusStateController(focusBorder: focusBorder)
        dimmingOverlay = DimmingOverlay()
        animator = WindowAnimator()
        accessibility = AccessibilityManager()
        cursorManager = CursorManager()
        keybindOverlay = KeybindOverlayController()
        appLauncher = AppLauncherManager()

        workspaceManager = WorkspaceManager(displayManager: displayManager)
        tilingEngine = TilingEngine(displayManager: displayManager)

        workspaceOrchestrator = WorkspaceOrchestrator(
            workspaceManager: workspaceManager,
            tilingEngine: tilingEngine,
            accessibility: accessibility,
            displayManager: displayManager,
            cursorManager: cursorManager,
            stateCache: stateCache,
            focusController: focusController,
            focusBorder: focusBorder,
            dimmingOverlay: dimmingOverlay,
            suppressions: suppressions
        )
        floatingController = FloatingWindowController(
            stateCache: stateCache,
            suppressions: suppressions,
            workspaceManager: workspaceManager,
            tilingEngine: tilingEngine,
            displayManager: displayManager,
            accessibility: accessibility,
            cursorManager: cursorManager,
            focusController: focusController,
            focusBorder: focusBorder,
            dimmingOverlay: dimmingOverlay
        )
        dispatcher = ActionDispatcher(
            stateCache: stateCache,
            accessibility: accessibility,
            displayManager: displayManager,
            cursorManager: cursorManager,
            workspaceManager: workspaceManager,
            tilingEngine: tilingEngine,
            animator: animator,
            focusController: focusController,
            focusBorder: focusBorder,
            keybindOverlay: keybindOverlay,
            appLauncher: appLauncher,
            workspaceOrchestrator: workspaceOrchestrator,
            floatingController: floatingController,
            config: config
        )

        // resolve the workspace WorkspaceManager actually maps to our test screen.
        // on multi-monitor test hosts, the test screen is not necessarily workspace 1.
        // the dispatcher will use the same lookup, so we must seed the tree at the
        // same key.
        workspace = workspaceManager.workspaceForScreen(screen)
    }

    private func tree() -> BSPTree? {
        tilingEngine.existingTree(forWorkspace: workspace, screen: screen)
    }

    // build a 2-window tree so the toggleSplit operates on a real parent node.
    private func seedTwoWindowTree() -> (HyprWindow, HyprWindow) {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        tilingEngine.prepareTileLayout([w1, w2], onWorkspace: workspace, screen: screen)
        return (w1, w2)
    }

    func testToggleSplitMutatesTreeExactlyOnce() {
        let (w1, _) = seedTwoWindowTree()
        guard let tree = tree(),
              let leaf = tree.root.find(w1),
              let parent = leaf.parent else {
            XCTFail("expected 2-window tree with parent node")
            return
        }

        // initial state: splitOverride is nil (dwindle uses computed direction).
        XCTAssertNil(parent.splitOverride, "splitOverride should start unset")

        // wire dispatcher to focus w1, leave the rest as defaults.
        dispatcher.currentFocusedWindow = { w1 }

        dispatcher.dispatch(.toggleSplit)

        // after a single toggle, splitOverride should be set to the OPPOSITE of
        // what dwindle would compute from the rect. for a wide screen rect that's
        // .vertical; for a tall one it's .horizontal. either way it must be
        // non-nil — and crucially it must NOT match the rect-derived default,
        // because that's what double-toggle would leave behind.
        let screenRect = displayManager.cgRect(for: screen)
        let dwindleDefault: SplitDirection = screenRect.width >= screenRect.height ? .horizontal : .vertical
        let expectedAfterOneToggle: SplitDirection = (dwindleDefault == .horizontal) ? .vertical : .horizontal

        XCTAssertNotNil(parent.splitOverride, "splitOverride should be set after toggle")
        XCTAssertEqual(parent.splitOverride, expectedAfterOneToggle,
                       "single toggle should flip exactly once — double-toggle would leave \(dwindleDefault)")
    }

}
