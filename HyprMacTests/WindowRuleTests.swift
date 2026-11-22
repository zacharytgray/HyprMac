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
    func testAScratchpadPinIsNotAWorkspacePin() {
        let pins = rules(("com.apple.Music", WindowRule.scratchpad))
        XCTAssertTrue(WindowRule.isPinnedToScratchpad(bundleID: "com.apple.Music", in: pins))
        XCTAssertFalse(WindowRule.isPinnedToScratchpad(bundleID: "com.apple.Terminal", in: pins))
        XCTAssertFalse(WindowRule.isPinnedToScratchpad(bundleID: nil, in: pins))
        XCTAssertNil(WindowRule.pinnedWorkspace(forBundleID: "com.apple.Music", in: pins))
        XCTAssertFalse(WindowRule.isPinnedToScratchpad(
            bundleID: "com.apple.Terminal", in: rules(("com.apple.Terminal", 2))))
    }

    func testAQuickLookPreviewIsNeverPinnedToTheScratchpad() {
        let pins = rules(("com.apple.finder", WindowRule.scratchpad))
        XCTAssertTrue(ActionDispatcher.isPinnedToScratchpad(bundleID: "com.apple.finder",
                                                            isQuickLookPanel: false, rules: pins))
        XCTAssertFalse(ActionDispatcher.isPinnedToScratchpad(bundleID: "com.apple.finder",
                                                             isQuickLookPanel: true, rules: pins))
    }

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

    // the Pin apps picker takes several apps at once
    func testPickingSeveralAppsAddsAWorkspaceOneRuleForEach() {
        let added = WindowRule.newRules(
            forBundleIDs: ["com.apple.Safari", "com.apple.Notes"],
            existing: rules(("com.apple.Terminal", 3)))
        XCTAssertEqual(added, rules(("com.apple.Safari", 1), ("com.apple.Notes", 1)))
    }

    func testPickingAnAppThatHasARuleLeavesItAlone() {
        let added = WindowRule.newRules(
            forBundleIDs: ["com.apple.Terminal", "com.apple.Safari"],
            existing: rules(("com.apple.Terminal", 3)))
        XCTAssertEqual(added, rules(("com.apple.Safari", 1)))
    }

    func testAnAppPickedTwiceGetsOneRule() {
        let added = WindowRule.newRules(
            forBundleIDs: ["com.apple.Safari", "com.apple.Notes", "com.apple.Safari"],
            existing: [])
        XCTAssertEqual(added, rules(("com.apple.Safari", 1), ("com.apple.Notes", 1)))
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
        XCTAssertTrue(ActionPolicy.isDroppedMidDisplayTransition(.retileAll))
        XCTAssertTrue(ActionPolicy.cancelsPendingRecovery(.retileAll))
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

    // MARK: - reopened windows

    // a closed window whose app gave its id back (Mail, Mimestream) comes
    // back as a return, not a new window. a pin places it like a new one

    // recorded ws hidden and the pin: it keeps that workspace, parks, and
    // the user is taken there
    func testAReopenOntoItsHiddenPinParksThereAndIsFollowed() {
        let h = ReopenHarness(rules: rules(("com.mimestream.Mimestream", 1)), visibleWorkspace: 4)
        let w = h.window(67, bundleID: "com.mimestream.Mimestream")

        h.returnWindow(w, recordedOn: 1, reopened: true)

        XCTAssertEqual(h.workspaces.workspaceFor(67), 1, "its pin, not the visible ws4")
        XCTAssertEqual(h.parks, 1, "parked on its hidden workspace before the follow")
        XCTAssertEqual(h.follows.map(\.windowID), [67])
        XCTAssertEqual(h.follows.map(\.workspace), [1])
    }

    // recorded ws hidden, pin a third hidden workspace
    func testAReopenGoesToAThirdHiddenPinAndIsFollowed() {
        let h = ReopenHarness(rules: rules(("com.mimestream.Mimestream", 2)), visibleWorkspace: 4)
        let w = h.window(68, bundleID: "com.mimestream.Mimestream")

        h.returnWindow(w, recordedOn: 7, reopened: true)

        XCTAssertEqual(h.workspaces.workspaceFor(68), 2)
        XCTAssertEqual(h.parks, 1)
        XCTAssertEqual(h.follows.map(\.workspace), [2])
    }

    // recorded ws hidden, pin the visible workspace
    func testAReopenOntoTheVisiblePinStaysWithNoFollow() {
        let h = ReopenHarness(rules: rules(("com.mimestream.Mimestream", 4)), visibleWorkspace: 4)
        let w = h.window(69, bundleID: "com.mimestream.Mimestream")

        h.returnWindow(w, recordedOn: 1, reopened: true)

        XCTAssertEqual(h.workspaces.workspaceFor(69), 4)
        XCTAssertEqual(h.parks, 0)
        XCTAssertTrue(h.follows.isEmpty)
    }

    // a reopen or a flap on its own visible workspace drifts nowhere, so a
    // pin elsewhere leaves it alone: a pin is not a tether
    func testAReopenOnItsOwnVisibleWorkspaceIgnoresThePin() {
        let h = ReopenHarness(rules: rules(("com.apple.Safari", 2)), visibleWorkspace: 4)
        let w = h.window(75, bundleID: "com.apple.Safari")

        h.returnWindow(w, recordedOn: 4, reopened: true)

        XCTAssertEqual(h.workspaces.workspaceFor(75), 4)
        XCTAssertEqual(h.parks, 0)
        XCTAssertTrue(h.follows.isEmpty)
    }

    func testAnUnpinnedReopenStillDriftsToTheVisibleWorkspace() {
        let h = ReopenHarness(rules: rules(("com.mimestream.Mimestream", 1)), visibleWorkspace: 4)
        let w = h.window(70, bundleID: "com.apple.mail")

        h.returnWindow(w, recordedOn: 1, reopened: true)

        XCTAssertEqual(h.workspaces.workspaceFor(70), 4)
        XCTAssertTrue(h.follows.isEmpty)
    }

    func testAMinimizedReturnOfAPinnedAppKeepsItsWorkspace() {
        let h = ReopenHarness(rules: rules(("com.mimestream.Mimestream", 1)), visibleWorkspace: 4)
        let w = h.window(71, bundleID: "com.mimestream.Mimestream")

        h.returnWindow(w, recordedOn: 6, reopened: false)

        XCTAssertEqual(h.workspaces.workspaceFor(71), 6, "a user hide is not a reopen")
        XCTAssertTrue(h.follows.isEmpty)
    }

    // the same spill as a new window: the next workspace with room
    func testAPinnedReopenOntoAFullPinSpillsLikeANewWindow() {
        let h = ReopenHarness(rules: rules(("com.mimestream.Mimestream", 1)), visibleWorkspace: 4)
        h.engine.maxSplitsPerMonitor[h.screen.localizedName] = 1  // two slots a workspace
        for id: CGWindowID in [80, 81] {
            h.workspaces.assignWindow(id, toWorkspace: 1)
            h.cache.knownWindowIDs.insert(id)
        }
        let w = h.window(72, bundleID: "com.mimestream.Mimestream")

        h.returnWindow(w, recordedOn: 1, reopened: true)

        XCTAssertEqual(h.workspaces.workspaceFor(72), 2)
        XCTAssertEqual(h.follows.map(\.workspace), [2])
    }

    // the reopen's own stale assignment on the pin is not an occupant: one
    // other tile plus itself fits a two-slot pin with no spill
    func testAReopenDoesNotCountItselfOnItsOldWorkspace() {
        let h = ReopenHarness(rules: rules(("com.mimestream.Mimestream", 1)), visibleWorkspace: 4)
        h.engine.maxSplitsPerMonitor[h.screen.localizedName] = 1  // two slots a workspace
        h.workspaces.assignWindow(80, toWorkspace: 1)
        h.cache.knownWindowIDs.insert(80)
        let w = h.window(76, bundleID: "com.mimestream.Mimestream")

        h.returnWindow(w, recordedOn: 1, reopened: true)

        XCTAssertEqual(h.workspaces.workspaceFor(76), 1)
        XCTAssertEqual(h.follows.map(\.workspace), [1])
    }

    // a closed-but-alive ghost holds no slot; a minimized window does
    func testAGhostOnThePinIsNoOccupant() {
        let h = ReopenHarness(rules: rules(("com.mimestream.Mimestream", 1)), visibleWorkspace: 4)
        h.engine.maxSplitsPerMonitor[h.screen.localizedName] = 1
        for id: CGWindowID in [80, 81] {
            h.workspaces.assignWindow(id, toWorkspace: 1)
            h.cache.hiddenWindowIDs.insert(id)
        }
        h.cache.reservedHiddenWindowIDs = [80]
        let w = h.window(73, bundleID: "com.mimestream.Mimestream")

        h.returnWindow(w, recordedOn: 1, reopened: true)

        XCTAssertEqual(h.workspaces.workspaceFor(73), 1)
    }

    func testAReopenPinnedToTheScratchpadIsAdopted() {
        let h = ReopenHarness(rules: rules(("com.mimestream.Mimestream", WindowRule.scratchpad)),
                              visibleWorkspace: 4)
        var adopted: [CGWindowID] = []
        h.dispatcher.adoptPinnedToScratchpad = { adopted.append($0.windowID) }
        let w = h.window(74, bundleID: "com.mimestream.Mimestream")

        h.returnWindow(w, recordedOn: 1, reopened: true)

        XCTAssertEqual(adopted, [74])
        XCTAssertEqual(h.workspaces.workspaceFor(74), 1, "not drifted; adoption assigns it")
        XCTAssertTrue(h.follows.isEmpty)
    }

    // a never-tile app's floater (Spotify) reopened onto a hidden workspace
    // drifts to the visible one and keeps the frame its app gave it. the
    // park repair after the pass leaves it on screen, and a frame its ghost
    // saved before the close is gone
    func testAFloaterReopenedOntoAHiddenWorkspaceStaysOnScreen() {
        let h = ReopenHarness(rules: [], visibleWorkspace: 4)
        let stale = CGRect(x: 900, y: 500, width: 300, height: 200)
        let w = h.framedWindow(77, bundleID: "com.spotify.client")
        h.cache.floatingWindowIDs.insert(77)
        h.workspaces.setSavedFloatingFrame(stale, for: 77)

        h.returnWindow(w, recordedOn: 1, reopened: true)
        h.placement.repairParkedWindows([w])

        XCTAssertEqual(h.workspaces.workspaceFor(77), 4)
        XCTAssertTrue(h.cache.floatingWindowIDs.contains(77), "still floating, no tile")
        XCTAssertFalse(h.engine.windowIDs(inTreeForWorkspace: 4, screen: h.screen).contains(77))
        XCTAssertNil(h.workspaces.savedFloatingFrame(for: 77), "the stale frame is cleared")
        XCTAssertEqual(h.parks, 0, "not parked by the pass or the park repair")
        XCTAssertTrue(h.follows.isEmpty)
    }

    // the seam above sees a park: the same floater left on its hidden
    // workspace, as before the fix, is parked by the repair
    func testTheParkRepairParksAFloaterLeftOnAHiddenWorkspace() {
        let h = ReopenHarness(rules: [], visibleWorkspace: 4)
        let w = h.framedWindow(78, bundleID: "com.spotify.client")
        h.cache.floatingWindowIDs.insert(78)
        h.workspaces.assignWindow(78, toWorkspace: 1)

        h.placement.repairParkedWindows([w])

        XCTAssertEqual(h.parks, 1)
    }

    // a pinned floater reopened onto a hidden workspace goes to its pin, is
    // parked there with the frame it reopened at saved for the reveal, not
    // the one its ghost held, and is followed
    func testAPinnedFloaterReopenedOntoAHiddenWorkspaceGoesToItsPinAndIsFollowed() {
        let h = ReopenHarness(rules: rules(("com.spotify.client", 2)), visibleWorkspace: 4)
        let stale = CGRect(x: 900, y: 500, width: 300, height: 200)
        let w = h.framedWindow(79, bundleID: "com.spotify.client")
        h.cache.floatingWindowIDs.insert(79)
        h.workspaces.setSavedFloatingFrame(stale, for: 79)

        h.returnWindow(w, recordedOn: 7, reopened: true)

        XCTAssertEqual(h.workspaces.workspaceFor(79), 2)
        XCTAssertTrue(h.cache.floatingWindowIDs.contains(79))
        XCTAssertEqual(h.workspaces.savedFloatingFrame(for: 79), w.frame, "its reopened frame, for the reveal")
        XCTAssertEqual(h.parks, 1, "parked on its hidden pin before the follow")
        XCTAssertEqual(h.follows.map(\.windowID), [79])
        XCTAssertEqual(h.follows.map(\.workspace), [2])
    }

    // pinned to the visible workspace: it stays where it opened, unparked
    func testAPinnedFloaterReopenedOntoTheVisiblePinStays() {
        let h = ReopenHarness(rules: rules(("com.spotify.client", 4)), visibleWorkspace: 4)
        let w = h.framedWindow(83, bundleID: "com.spotify.client")
        h.cache.floatingWindowIDs.insert(83)
        h.workspaces.setSavedFloatingFrame(CGRect(x: 900, y: 500, width: 300, height: 200), for: 83)

        h.returnWindow(w, recordedOn: 1, reopened: true)
        h.placement.repairParkedWindows([w])

        XCTAssertEqual(h.workspaces.workspaceFor(83), 4)
        XCTAssertNil(h.workspaces.savedFloatingFrame(for: 83))
        XCTAssertEqual(h.parks, 0)
        XCTAssertTrue(h.follows.isEmpty)
    }

    // a pinned app's window that a float rule covers goes to its pin and
    // floats there, the way a Never tile app's window always has
    func testAPinnedWindowAFloatRuleCoversFloatsOnItsPin() {
        let h = ReopenHarness(rules: rules(("us.zoom.xos", 2)), visibleWorkspace: 4)
        let w = h.framedWindow(90, bundleID: "us.zoom.xos")
        h.cache.knownWindowIDs.insert(90)
        // discovery admitted it floating, for the rule
        h.cache.setFloating(true, window: w)

        _ = h.dispatcher.applyChanges(
            WindowChanges(newWindows: [w], newOnDisabledMonitor: [], returned: [], goneIDs: [],
                          fullyForgottenIDs: [], screenDrift: [], focusedWindowGone: false,
                          requestsRecheck: false),
            allWindows: [w])

        XCTAssertEqual(h.workspaces.workspaceFor(90), 2)
        XCTAssertTrue(h.cache.floatingWindowIDs.contains(90), "the pin moves it, the rule keeps it floating")
        XCTAssertFalse(h.engine.windowIDs(inTreeForWorkspace: 2, screen: h.screen).contains(90))
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
        controller.retile = { body in retiles += 1; body() }
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

/// a dispatcher on one fake screen, a scratch config, and a ghost that comes
/// back the way discovery reports it
private final class ReopenHarness {
    let screen = WindowRuleTestScreen()
    let workspaces: WorkspaceManager
    let engine: TilingEngine
    let cache = WindowStateCache()
    let dispatcher: ActionDispatcher
    let placement: WindowPlacement
    var follows: [(windowID: CGWindowID, workspace: Int)] = []
    /// park writes; a fake window's write fails, which reports each one
    var parks = 0
    private let configDir: URL

    init(rules: [WindowRule], visibleWorkspace: Int) {
        let screen = self.screen
        let display = DisplayManager(screenSource: { [screen] })
        workspaces = WorkspaceManager(displayManager: display)
        workspaces.initializeMonitors()
        _ = workspaces.switchWorkspace(visibleWorkspace, cursorScreen: screen)
        engine = TilingEngine(displayManager: display, frameSizingIOFactory: acceptingFrameSizingIOFactory())
        configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReopenHarness-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let config = UserConfig(store: ConfigStore(
            localConfigURL: configDir.appendingPathComponent("config.json"),
            monitorConfigURL: configDir.appendingPathComponent("monitor-config.json"),
            iCloudRootURL: configDir.appendingPathComponent("cloud", isDirectory: true)))
        config.windowRules = rules

        let suppressions = SuppressionRegistry()
        let border = FocusBorder()
        let focus = FocusStateController(focusBorder: border)
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
        placement = WindowPlacement(
            config: config, accessibility: accessibility, displayManager: display,
            workspaceManager: workspaces, tilingEngine: engine, stateCache: cache,
            floatingController: floating,
            scratchpad: ScratchpadController(
                workspaceManager: workspaces, stateCache: cache, accessibility: accessibility,
                displayManager: display, tilingEngine: engine, focusController: focus,
                focusBorder: border, suppressions: suppressions),
            actionDispatcher: dispatcher, workspaceOrchestrator: orchestrator)
        dispatcher.screenUnderCursor = { screen }
        dispatcher.isMenuTracking = { true }
        dispatcher.followPinnedWindow = { [unowned self] id, workspace in
            follows.append((id, workspace))
        }
        workspaces.onParkFailed = { [unowned self] in parks += 1 }
    }

    deinit { try? FileManager.default.removeItem(at: configDir) }

    func window(_ id: CGWindowID, bundleID: String) -> HyprWindow {
        let w = makeWindow(id: id, pid: 0)
        w.bundleID = bundleID
        return w
    }

    /// a window that reads a frame on screen, mid-screen
    func framedWindow(_ id: CGWindowID, bundleID: String) -> HyprWindow {
        let w = ReopenFramedWindow(id: id, frame: CGRect(x: 200, y: 150, width: 600, height: 400))
        w.bundleID = bundleID
        return w
    }

    /// `window`, a ghost recorded on `workspace`, is back. a reopen is a
    /// verified close; discovery drifts it onto the visible workspace and
    /// marks it only when its own is hidden, as `detectScreenDrift` does
    func returnWindow(_ window: HyprWindow, recordedOn workspace: Int, reopened: Bool) {
        let id = window.windowID
        workspaces.assignWindow(id, toWorkspace: workspace)
        cache.knownWindowIDs.insert(id)
        cache.windowOwners[id] = window.ownerPID
        let visible = workspaces.workspaceForScreen(screen)
        let drift = reopened && !workspaces.isWorkspaceVisible(workspace)
            ? [(windowID: id, fromWorkspace: workspace, toWorkspace: visible)] : []
        _ = dispatcher.applyChanges(
            WindowChanges(newWindows: [], newOnDisabledMonitor: [], returned: [window],
                          goneIDs: [], fullyForgottenIDs: [], screenDrift: drift,
                          focusedWindowGone: false, requestsRecheck: false,
                          returnedFromUserHide: reopened ? [] : [id],
                          reopenedOntoHiddenWorkspace: Set(drift.map(\.windowID))),
            allWindows: [window])
    }
}

private final class ReopenFramedWindow: HyprWindow {
    let storedFrame: CGRect
    init(id: CGWindowID, frame: CGRect) {
        storedFrame = frame
        super.init(element: AXUIElementCreateApplication(0), windowID: id, ownerPID: 0)
    }
    override func readPosition() -> (AXError, CGPoint?) { (.success, storedFrame.origin) }
    override func readSize() -> (AXError, CGSize?) { (.success, storedFrame.size) }
}

private final class WindowRuleTestScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 1600, height: 1000) }
    override var visibleFrame: NSRect { frame }
    override var localizedName: String { "window-rule-test" }
}
