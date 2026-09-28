import Cocoa
import XCTest
@testable import HyprMac

// window rules: per-app workspace pins, the Retile All keybind that also
// applies them, and the Never tile refusal. the decisions are statics over
// plain values; the toggle refusal runs the real controller on a fake screen.

final class WindowRuleTests: XCTestCase {

    private func rules(_ pairs: (String, Int)...) -> [WindowRule] {
        pairs.map { WindowRule(bundleID: $0.0, workspace: $0.1) }
    }

    // MARK: - pin resolution

    func testMatchingAppIsPinnedToItsWorkspace() {
        XCTAssertEqual(WindowRule.pinnedWorkspace(forBundleID: "com.apple.Terminal",
                                                  in: rules(("com.apple.Terminal", 2))), 2)
    }

    func testOtherAppsAndUnknownOwnersAreNotPinned() {
        let pins = rules(("com.apple.Terminal", 2))
        XCTAssertNil(WindowRule.pinnedWorkspace(forBundleID: "com.apple.Safari", in: pins))
        XCTAssertNil(WindowRule.pinnedWorkspace(forBundleID: nil, in: pins))
        XCTAssertNil(WindowRule.pinnedWorkspace(forBundleID: "com.apple.Terminal", in: []))
    }

    // a hand-edited config can name a workspace that doesn't exist
    func testWorkspaceOutsideOneToTenPinsNothing() {
        for workspace in [0, -1, 11] {
            XCTAssertNil(WindowRule.pinnedWorkspace(forBundleID: "com.apple.Terminal",
                                                    in: rules(("com.apple.Terminal", workspace))),
                         "workspace \(workspace)")
        }
        XCTAssertEqual(WindowRule.pinnedWorkspace(forBundleID: "com.apple.Terminal",
                                                  in: rules(("com.apple.Terminal", 10))), 10)
    }

    func testDuplicateRuleResolvesToTheFirst() {
        XCTAssertEqual(WindowRule.pinnedWorkspace(
            forBundleID: "com.apple.Terminal",
            in: rules(("com.apple.Terminal", 2), ("com.apple.Terminal", 7))), 2)
    }

    // a preview belongs to whichever app opened it; a pinned Finder must
    // not drag every Quick Look panel along
    func testQuickLookPreviewIsNeverPinned() {
        let pins = rules(("com.apple.finder", 4))
        XCTAssertNil(ActionDispatcher.pinnedWorkspace(bundleID: "com.apple.finder",
                                                      isQuickLookPanel: true, rules: pins))
        XCTAssertEqual(ActionDispatcher.pinnedWorkspace(bundleID: "com.apple.finder",
                                                        isQuickLookPanel: false, rules: pins), 4)
    }

    // MARK: - follow

    private func landing(_ id: CGWindowID, _ workspace: Int, openedOn: Int) -> ActionDispatcher.PinnedLanding {
        ActionDispatcher.PinnedLanding(windowID: id, workspace: workspace, openedOnWorkspace: openedOn)
    }

    func testAPinThatMovedTheWindowIsFollowed() {
        let target = ActionDispatcher.pinFollowTarget([landing(7, 2, openedOn: 1)], focusedWindowID: nil)
        XCTAssertEqual(target, landing(7, 2, openedOn: 1))
    }

    // it opened where it's pinned anyway: nothing to switch to
    func testAPinThatChangedNothingIsNotFollowed() {
        XCTAssertNil(ActionDispatcher.pinFollowTarget([landing(7, 2, openedOn: 2)], focusedWindowID: 7))
        XCTAssertNil(ActionDispatcher.pinFollowTarget([], focusedWindowID: nil))
    }

    func testTheFocusedWindowWinsWhenSeveralPinnedWindowsArrive() {
        let landings = [landing(7, 2, openedOn: 1), landing(8, 5, openedOn: 1)]
        XCTAssertEqual(ActionDispatcher.pinFollowTarget(landings, focusedWindowID: 8)?.windowID, 8)
        XCTAssertEqual(ActionDispatcher.pinFollowTarget(landings, focusedWindowID: 99)?.windowID, 7)
    }

    // a full pinned workspace spills; the follow goes where the window landed
    func testFollowUsesTheWorkspaceTheWindowActuallyLandedOn() {
        let target = ActionDispatcher.pinFollowTarget([landing(7, 3, openedOn: 1)], focusedWindowID: 7)
        XCTAssertEqual(target?.workspace, 3)
    }

    // MARK: - Retile All

    func testPinnedWindowsFormTheirOwnBatchesAheadOfTheRest() {
        let pins: [CGWindowID: Int] = [7: 3, 8: 1, 9: 3]
        let split = RetileAllPlanner.pinnedStartupBatches(
            windowIDs: [5, 7, 6, 8, 9],
            pinnedWorkspaceFor: { pins[$0] },
            order: { $0.sorted() })
        XCTAssertEqual(split.batches.map(\.preferredWorkspace), [1, 3])
        XCTAssertEqual(split.batches.map(\.windowIDs), [[8], [7, 9]])
        XCTAssertEqual(split.unpinned, [5, 6])
    }

    // pinned batches go first, so a pin takes its seat before the screen
    // batch that also wants that workspace fills it
    func testAPinnedWindowClaimsItsWorkspaceBeforeScreenPlacement() {
        let split = RetileAllPlanner.pinnedStartupBatches(
            windowIDs: [5, 6, 7],
            pinnedWorkspaceFor: { $0 == 7 ? 1 : nil },
            order: { $0 })
        let plan = RetileAllPlanner.admitStartupBatches(
            split.batches + [RetileAllBatch(preferredWorkspace: 1, windowIDs: split.unpinned)],
            workspaceCount: 3,
            reservedAssignments: [:],
            capacityForWorkspace: { $0 == 1 ? 2 : 4 })
        XCTAssertEqual(plan.assignments[1], [7, 5])
        XCTAssertEqual(plan.assignments[2], [6])
        XCTAssertTrue(plan.overflow.isEmpty)
    }

    // a full pinned workspace spills onward, the same as admission
    func testAFullPinnedWorkspaceSpillsOnward() {
        let split = RetileAllPlanner.pinnedStartupBatches(
            windowIDs: [7, 8, 9],
            pinnedWorkspaceFor: { _ in 2 },
            order: { $0 })
        let plan = RetileAllPlanner.admitStartupBatches(
            split.batches, workspaceCount: 3, reservedAssignments: [:],
            capacityForWorkspace: { _ in 2 })
        XCTAssertEqual(plan.assignments[2], [7, 8])
        XCTAssertEqual(plan.assignments[3], [9])
    }

    func testOnlyFloatersAwayFromTheirPinMove() {
        let current: [CGWindowID: Int] = [1: 1, 2: 4, 3: 1, 4: ScratchpadController.workspace]
        let pins: [CGWindowID: Int] = [1: 4, 2: 4, 4: 4, 5: 4]
        let moves = RetileAllPlanner.pinnedFloaterMoves(
            floatingWindowIDs: [3, 1, 2, 4, 5],
            workspaceFor: { current[$0] },
            pinnedWorkspaceFor: { pins[$0] })
        // 2 is already there, 3 has no pin, 4 is in the scratchpad, 5 is untracked
        XCTAssertEqual(moves.map(\.windowID), [1])
        XCTAssertEqual(moves.first?.from, 1)
        XCTAssertEqual(moves.first?.to, 4)
    }

    // MARK: - pinned floater frames

    // worked out from known frames, never read back after a write
    private let laptop = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let external = CGRect(x: 1600, y: 0, width: 1920, height: 1080)

    func testACarriedFloaterKeepsItsSizeAndRelativePosition() {
        let carried = WorkspaceOrchestrator.carriedFloaterFrame(
            CGRect(x: 100, y: 100, width: 400, height: 300), from: laptop, to: external)
        XCTAssertEqual(carried, CGRect(x: 1760, y: 120, width: 400, height: 300))
    }

    func testAFloaterAlreadyOnTheTargetStaysPut() {
        let frame = CGRect(x: 1700, y: 50, width: 400, height: 300)
        XCTAssertEqual(WorkspaceOrchestrator.carriedFloaterFrame(frame, from: laptop, to: external), frame)
    }

    func testAnOversizedFloaterIsCappedAndClampedToTheTarget() {
        let small = CGRect(x: 1600, y: 0, width: 800, height: 600)
        let carried = WorkspaceOrchestrator.carriedFloaterFrame(laptop, from: laptop, to: small)
        XCTAssertEqual(carried, small)
    }

    // MARK: - Retile All keybind

    func testRetileAllBehavesLikeTheOtherLayoutWideActions() {
        XCTAssertTrue(WindowManager.isDroppedMidDisplayTransition(.retileAll))
        XCTAssertTrue(WindowManager.cancelsPendingRecovery(.retileAll))
        XCTAssertTrue(HotkeyManager.ignoresAutorepeat(.retileAll))
        XCTAssertFalse(HotkeyManager.actionIsAvailable(.retileAll, tilingEnabled: false))
        XCTAssertEqual(KeybindCategory.from(.retileAll), .system)
        XCTAssertEqual(Keybind(keyCode: 15, modifiers: .hypr, action: .retileAll).actionDescription,
                       "Retile All Spaces")
    }

    // MARK: - config

    private func decode(_ json: String) throws -> SavedConfig {
        try JSONDecoder().decode(SavedConfig.self, from: Data(json.utf8))
    }

    func testRulesRoundTripThroughSavedConfig() throws {
        let saved = try decode("""
        {"keybinds":[],"gapSize":8,"outerPadding":8,"enabled":true,
         "windowRules":[{"bundleID":"com.apple.Terminal","workspace":2}]}
        """)
        XCTAssertEqual(saved.windowRules, rules(("com.apple.Terminal", 2)))
        let reloaded = try JSONDecoder().decode(SavedConfig.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(reloaded.windowRules, saved.windowRules)
    }

    func testConfigWithoutRulesDecodesAsNone() throws {
        XCTAssertNil(try decode(#"{"keybinds":[],"gapSize":8,"outerPadding":8,"enabled":true}"#).windowRules)
        XCTAssertNil(try decode(#"{"keybinds":[],"gapSize":8,"outerPadding":8,"enabled":true,"windowRules":null}"#)
            .windowRules)
    }

    // one bad rule costs itself, never the other rules or settings
    func testAMalformedRuleIsSkipped() throws {
        let saved = try decode("""
        {"keybinds":[],"gapSize":22,"outerPadding":8,"enabled":true,
         "windowRules":[{"bundleID":"com.busted.app"},42,null,
                        {"bundleID":"com.apple.Terminal","workspace":2},
                        {"bundleID":"com.apple.Safari","workspace":"three"}]}
        """)
        XCTAssertEqual(saved.windowRules, rules(("com.apple.Terminal", 2)))
        XCTAssertEqual(saved.gapSize, 22)
    }

    func testAnUnreadableRulesValueCostsOnlyTheRules() throws {
        let saved = try decode("""
        {"keybinds":[],"gapSize":14,"outerPadding":8,"enabled":true,
         "excludedBundleIDs":["com.apple.FaceTime"],"windowRules":{"future":"value"}}
        """)
        XCTAssertNil(saved.windowRules)
        XCTAssertEqual(saved.excludedBundleIDs, ["com.apple.FaceTime"])
        XCTAssertEqual(saved.gapSize, 14)
    }

    // MARK: - Never tile refusal

    func testHyprTOnANeverTileWindowLeavesItFloatingAndOutOfEveryTree() {
        let screen = WindowRuleTestScreen()
        let display = DisplayManager(screenSource: { [screen] })
        let workspaces = WorkspaceManager(displayManager: display)
        workspaces.initializeMonitors()
        let cache = WindowStateCache()
        let engine = TilingEngine(displayManager: display,
                                  frameSizingIOFactory: acceptingFrameSizingIOFactory())
        let border = FocusBorder()
        let controller = FloatingWindowController(
            stateCache: cache, suppressions: SuppressionRegistry(), workspaceManager: workspaces,
            tilingEngine: engine, displayManager: display, accessibility: AccessibilityManager(),
            cursorManager: CursorManager(), focusController: FocusStateController(focusBorder: border),
            focusBorder: border, dimmingOverlay: DimmingOverlay())
        controller.excludedBundleIDs = { ["com.apple.FaceTime"] }
        var retiles = 0
        controller.animatedRetile = { body in retiles += 1; body() }
        var refusals = 0
        controller.rejectFloatToTile = { _, _ in refusals += 1 }
        let workspace = workspaces.workspaceForScreen(screen)
        let window = makeWindow(id: 51, pid: 906)
        window.bundleID = "com.apple.FaceTime"
        window.isFloating = true
        cache.floatingWindowIDs.insert(51)
        workspaces.assignWindow(51, toWorkspace: workspace)

        controller.toggle(window, on: screen, in: workspace)

        XCTAssertTrue(cache.floatingWindowIDs.contains(51))
        XCTAssertTrue(window.isFloating)
        XCTAssertEqual(retiles, 0, "nothing is laid out")
        XCTAssertEqual(refusals, 0, "not a tree refusal; the app is refused up front")
        XCTAssertTrue(engine.windowIDs(inTreeForWorkspace: workspace, screen: screen).isEmpty)
        XCTAssertTrue(controller.isNeverTile(window))
    }

    func testAnAppOutsideNeverTileIsNotRefused() {
        let screen = WindowRuleTestScreen()
        let display = DisplayManager(screenSource: { [screen] })
        let workspaces = WorkspaceManager(displayManager: display)
        let border = FocusBorder()
        let controller = FloatingWindowController(
            stateCache: WindowStateCache(), suppressions: SuppressionRegistry(), workspaceManager: workspaces,
            tilingEngine: TilingEngine(displayManager: display,
                                       frameSizingIOFactory: acceptingFrameSizingIOFactory()),
            displayManager: display, accessibility: AccessibilityManager(),
            cursorManager: CursorManager(), focusController: FocusStateController(focusBorder: border),
            focusBorder: border, dimmingOverlay: DimmingOverlay())
        controller.excludedBundleIDs = { ["com.apple.FaceTime"] }
        let window = makeWindow(id: 52, pid: 907)
        window.bundleID = "com.apple.Terminal"
        XCTAssertFalse(controller.isNeverTile(window))
    }
}

private final class WindowRuleTestScreen: SyntheticScreen {
    override func isEqual(_ object: Any?) -> Bool {
        guard let screen = object as? NSScreen else { return false }
        return self === screen
    }
    override var hash: Int { ObjectIdentifier(self).hashValue }
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 1600, height: 1000) }
    override var visibleFrame: NSRect { frame }
    override var localizedName: String { "window-rule-test" }
}
