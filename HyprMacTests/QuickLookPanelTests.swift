import Cocoa
import XCTest
@testable import HyprMac

// Quick Look preview panels: which AX windows count as one, and how one
// lives as a floater from opening to closing. AX and CG facts go in as
// plain values. The subrole and layers are what the macOS 15.7 hub probe
// read off QLPreviewPanel; macOS 27 is unconfirmed until the laptop log
// shows it.

final class QuickLookPanelTests: XCTestCase {

    // MARK: - identification

    private func classify(role: String? = "AXWindow", subrole: String?, modal: Bool = false,
                          fullScreen: Bool = false,
                          cg: WindowAdmissionFilter.CGWindowFacts? = .init(layer: 0, alpha: 1))
        -> WindowAdmissionFilter.Verdict {
        WindowAdmissionFilter.classify(role: role, subrole: subrole, isModal: modal,
                                       isFullScreen: { fullScreen }, cgWindow: { cg })
    }

    func testStandardWindowsGetInWithoutExtraReads() {
        for subrole in ["AXStandardWindow", nil] as [String?] {
            let verdict = WindowAdmissionFilter.classify(
                role: "AXWindow", subrole: subrole, isModal: false,
                isFullScreen: { XCTFail("a standard window never reads AXFullScreen"); return false },
                cgWindow: { XCTFail("a standard window is matched as before"); return nil })
            XCTAssertEqual(verdict, .standard)
        }
    }

    func testOtherWindowKindsStayOut() {
        XCTAssertEqual(classify(role: "AXSheet", subrole: nil), .dropped(.role))
        XCTAssertEqual(classify(role: nil, subrole: "AXStandardWindow"), .dropped(.role))
        for subrole in ["AXDialog", "AXSystemDialog", "AXFloatingWindow", "AXSystemFloatingWindow", "AXUnknown"] {
            XCTAssertEqual(classify(subrole: subrole), .dropped(.subrole), subrole)
        }
        XCTAssertEqual(classify(subrole: "AXStandardWindow", modal: true), .dropped(.modal))
    }

    func testAQuickLookPanelIsManagedFromTheNormalOrFloatingLayer() {
        XCTAssertEqual(classify(subrole: "Quick Look", cg: .init(layer: 0, alpha: 1)), .quickLookPanel)
        // the hub probe read layer 3 while the panel's app was frontmost
        XCTAssertEqual(classify(subrole: "Quick Look", cg: .init(layer: 3, alpha: 1)), .quickLookPanel)
        XCTAssertEqual(WindowAdmissionFilter.quickLookLayers, [0, 3])
    }

    func testOnlyTheExactQuickLookSubrolePasses() {
        // a different spelling on another macOS lands in the drop log instead
        for subrole in ["quick look", "QuickLook", "AXQuickLook", "Quick Look Panel"] {
            XCTAssertEqual(classify(subrole: subrole), .dropped(.subrole), subrole)
        }
    }

    func testAModalQuickLookPanelStaysOut() {
        XCTAssertEqual(classify(subrole: "Quick Look", modal: true), .dropped(.modal))
    }

    func testQuickLookInNativeFullScreenIsNotManaged() {
        XCTAssertEqual(classify(subrole: "Quick Look", fullScreen: true), .dropped(.fullScreen))
    }

    func testQuickLooksOwnFullScreenViewIsNotManaged() {
        // hub probe: the full-screen view drops the panel to alpha 0 and
        // draws on layers 18 and 19
        XCTAssertEqual(classify(subrole: "Quick Look", cg: .init(layer: 3, alpha: 0)),
                       .dropped(.noVisibleWindow))
        XCTAssertEqual(classify(subrole: "Quick Look", cg: .init(layer: 19, alpha: 1)),
                       .dropped(.noVisibleWindow))
    }

    func testAPanelWithoutItsOwnCGWindowIsNotMatchedByPosition() {
        XCTAssertEqual(classify(subrole: "Quick Look", cg: nil), .dropped(.noVisibleWindow))
    }

    // MARK: - floating policy

    func testAQuickLookPanelAlwaysFloats() {
        XCTAssertEqual(FloatingAdmissionPolicy.reason(isExcluded: false, isSizeSettable: true,
                                                      isQuickLookPanel: true), .quickLook)
        // resize capability does not matter: the panel sizes itself per file
        XCTAssertEqual(FloatingAdmissionPolicy.reason(isExcluded: false, isSizeSettable: nil,
                                                      isQuickLookPanel: true), .quickLook)
        XCTAssertEqual(FloatingAdmissionPolicy.reason(isExcluded: true, isSizeSettable: false,
                                                      isQuickLookPanel: true), .quickLook)
        XCTAssertNil(FloatingAdmissionPolicy.reason(isExcluded: false, isSizeSettable: true))
    }

    // MARK: - discovery

    private func panel(_ id: CGWindowID, pid: pid_t) -> HyprWindow {
        let window = makeWindow(id: id, pid: pid)
        window.isQuickLookPanel = true
        return window
    }

    private func discovery(_ access: StubAccessibility)
        -> (WindowDiscoveryService, WindowStateCache) {
        let cache = WindowStateCache()
        let display = DisplayManager()
        let service = WindowDiscoveryService(
            stateCache: cache, accessibility: access, displayManager: display,
            workspaceManager: WorkspaceManager(displayManager: display),
            bundleIDForPID: { _ in "com.apple.finder" },
            isWindowSizeSettable: { _ in true })
        return (service, cache)
    }

    private func poll(_ service: WindowDiscoveryService, _ snapshot: [HyprWindow],
                      running: Set<pid_t>) -> WindowChanges {
        service.computeChanges(snapshot: snapshot, runningPIDs: running,
                               excludedBundleIDs: [], focusedWindowID: 0)
    }

    func testAPanelOpensAsAFloater() {
        let (service, cache) = discovery(StubAccessibility())
        let preview = panel(39, pid: 899)

        let opened = poll(service, [preview], running: [899])

        XCTAssertEqual(opened.newWindows.map(\.windowID), [39])
        XCTAssertTrue(cache.floatingWindowIDs.contains(39))
        XCTAssertTrue(preview.isFloating, "both floating flags agree")
    }

    func testAClosedPanelIsForgottenWithItsFloatingStateAndReopensAsNew() {
        let access = StubAccessibility()
        access.stateAnswer = .absent
        let (service, cache) = discovery(access)

        let opened = poll(service, [panel(40, pid: 900)], running: [900])
        XCTAssertEqual(opened.newWindows.map(\.windowID), [40])
        XCTAssertTrue(cache.floatingWindowIDs.contains(40))

        let closed = poll(service, [], running: [900])
        XCTAssertEqual(closed.goneIDs, [40])
        XCTAssertEqual(closed.fullyForgottenIDs, [40])
        XCTAssertFalse(cache.hiddenWindowIDs.contains(40), "a closed panel is not a ghost")
        XCTAssertFalse(cache.reservedHiddenWindowIDs.contains(40))
        XCTAssertFalse(cache.floatingWindowIDs.contains(40), "no floating state outlives it")
        XCTAssertFalse(cache.knownWindowIDs.contains(40))
        XCTAssertNil(cache.windowOwners[40])
        XCTAssertNil(cache.originalFrames[40])
        XCTAssertTrue(access.queries.isEmpty, "the panel's AX state is never asked")

        // the same long-lived panel comes back with the same id
        let reopened = poll(service, [panel(40, pid: 900)], running: [900])
        XCTAssertEqual(reopened.newWindows.map(\.windowID), [40])
        XCTAssertTrue(reopened.returned.isEmpty)
        XCTAssertTrue(cache.floatingWindowIDs.contains(40))
    }

    func testAPanelRegisteredAtStartupIsStillForgottenOnClose() {
        // startup and Retile All register windows without a discovery pass
        let access = StubAccessibility()
        access.stateAnswer = .absent
        let (service, cache) = discovery(access)
        let preview = panel(45, pid: 904)
        cache.cachedWindows[45] = preview
        cache.knownWindowIDs.insert(45)
        cache.windowOwners[45] = 904
        cache.floatingWindowIDs.insert(45)

        let closed = poll(service, [], running: [904])

        XCTAssertEqual(closed.fullyForgottenIDs, [45])
        XCTAssertFalse(cache.hiddenWindowIDs.contains(45))
        XCTAssertFalse(cache.floatingWindowIDs.contains(45))
    }

    func testAPanelThatHidesWithItsAppHoldsNoSlot() {
        let answers: [AccessibilityManager.HiddenWindowState?] = [.present, .appHidden, .minimized, nil]
        for answer in answers {
            let access = StubAccessibility()
            access.stateAnswer = answer
            let (service, cache) = discovery(access)
            _ = poll(service, [panel(41, pid: 901)], running: [901])

            let gone = poll(service, [], running: [901])

            XCTAssertEqual(gone.fullyForgottenIDs, [41], "\(String(describing: answer))")
            XCTAssertFalse(cache.hiddenWindowIDs.contains(41))
            XCTAssertFalse(cache.reservedHiddenWindowIDs.contains(41))
        }
    }

    func testAnOrdinaryWindowOfTheSameAppStillBecomesHidden() {
        let access = StubAccessibility()
        access.stateAnswer = .absent
        let (service, cache) = discovery(access)
        _ = poll(service, [panel(42, pid: 902), makeWindow(id: 43, pid: 902)], running: [902])

        let gone = poll(service, [], running: [902])

        XCTAssertEqual(gone.goneIDs, [42, 43])
        XCTAssertEqual(gone.fullyForgottenIDs, [42])
        XCTAssertTrue(cache.hiddenWindowIDs.contains(43))
        XCTAssertEqual(access.queries, [43])
    }

    func testAPanelThatStaysOpenIsNotNewAgain() {
        let (service, _) = discovery(StubAccessibility())
        _ = poll(service, [panel(44, pid: 903)], running: [903])

        let again = poll(service, [panel(44, pid: 903)], running: [903])

        XCTAssertTrue(again.newWindows.isEmpty)
        XCTAssertFalse(again.needsRetile)
    }

    // MARK: - workspace admission

    func testAFloatingPanelStaysOnTheWorkspaceItOpenedOnEvenWhenFull() {
        // admission passes floaters as excluded ids: no slot used, no routing
        let excluded = ActionDispatcher.admissionExclusions(
            floatingWindowIDs: [40], hiddenWindowIDs: [], reservedHiddenWindowIDs: [])
        let plan = RetileAllPlanner.admit(
            windowIDs: [40], preferredWorkspace: 1, eligibleWorkspaces: [1, 2, 3],
            existingAssignments: [1: [1, 2, 3, 4]], excludedWindowIDs: excluded,
            capacityForWorkspace: { _ in 4 })

        XCTAssertEqual(plan.assignments, [1: [40]])
        XCTAssertTrue(plan.overflow.isEmpty)
    }

    // MARK: - float toggle

    func testHyprTOnAPreviewLeavesItFloatingAndOutOfEveryTree() {
        let screen = QuickLookTestScreen()
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
        var retiles = 0
        controller.animatedRetile = { body in retiles += 1; body() }
        var refusals = 0
        controller.rejectFloatToTile = { _, _ in refusals += 1 }
        let workspace = workspaces.workspaceForScreen(screen)
        let preview = panel(46, pid: 905)
        preview.isFloating = true
        cache.floatingWindowIDs.insert(46)
        workspaces.assignWindow(46, toWorkspace: workspace)

        controller.toggle(preview, on: screen, in: workspace)

        XCTAssertTrue(cache.floatingWindowIDs.contains(46))
        XCTAssertTrue(preview.isFloating)
        XCTAssertEqual(retiles, 0, "nothing is laid out")
        XCTAssertEqual(refusals, 0, "not a tree refusal; the preview is refused up front")
        XCTAssertTrue(engine.windowIDs(inTreeForWorkspace: workspace, screen: screen).isEmpty)
    }
}

private final class QuickLookTestScreen: NSScreen {
    override func isEqual(_ object: Any?) -> Bool {
        guard let screen = object as? NSScreen else { return false }
        return self === screen
    }
    override var hash: Int { ObjectIdentifier(self).hashValue }
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 1600, height: 1000) }
    override var visibleFrame: NSRect { frame }
    override var localizedName: String { "quick-look-test" }
}
