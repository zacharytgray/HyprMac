import XCTest
@testable import HyprMac

// the Hypr+I overlay's keyboard model and the failed-tile prompt's policy

final class WindowRulesOverlayTests: XCTestCase {

    private func info(title: String = "Chat | Someone", rule: String? = nil, appFloats: Bool = false,
                      appTiles: Bool = false, floating: Bool = false) -> FocusedWindowRuleInfo {
        FocusedWindowRuleInfo(windowID: 8905, appName: "Microsoft Teams", bundleID: "com.microsoft.teams2",
                              title: title, currentRule: rule, appFloats: appFloats, appTiles: appTiles,
                              isFloating: floating)
    }

    func testTheRowsAndTheirOrder() {
        let model = WindowRulesOverlayModel(target: info())
        XCTAssertEqual(model.rows, [.floatApp, .tileApp, .floatTitle, .tileTitle],
                       "permanent rules only: once is Hypr+T")
        XCTAssertEqual(model.selection, .floatApp)
        XCTAssertEqual(model.label(.floatApp), "Always float Microsoft Teams")

        let covered = WindowRulesOverlayModel(target: info(rule: "Never tile: all windows", appFloats: true,
                                                           floating: true))
        XCTAssertEqual(covered.rows, [.tileApp, .floatTitle, .tileTitle, .forget],
                       "the app rule in effect isn't offered again; Forget shows")
        XCTAssertEqual(covered.selection, .tileApp, "the first rule that fits")
        XCTAssertEqual(covered.label(.forget), "Forget the rule")
        XCTAssertEqual(covered.detail(.forget), "Never tile: all windows")
    }

    func testUpAndDownWrap() {
        let model = WindowRulesOverlayModel(target: info())
        XCTAssertEqual(model.selection, .floatApp)
        model.move(-1)
        XCTAssertEqual(model.selection, .tileTitle)
        model.move(1)
        model.move(1)
        XCTAssertEqual(model.selection, .tileApp)
    }

    // prefilled with the window's title, trimmed by the user
    func testTheTitleEditor() {
        let model = WindowRulesOverlayModel(target: info(title: "Weekly sync | Meeting | Microsoft Teams"))
        XCTAssertEqual(model.titleMatch, .titleIs("Weekly sync | Meeting | Microsoft Teams"))
        model.selection = .floatTitle
        model.text = "Meeting"
        model.contains = true
        XCTAssertEqual(model.titleMatch, .titleContains("Meeting"))
        model.text = "Meeting "
        XCTAssertEqual(model.titleMatch, .titleContains("Meeting"))
        model.text = "  "
        XCTAssertNil(model.titleMatch)
        XCTAssertFalse(model.isEnabled(.floatTitle))
        XCTAssertTrue(model.isEnabled(.floatApp))
    }

    // a click on an app row applies it at once, as before
    func testClickingAnAppRowAppliesIt() {
        let model = WindowRulesOverlayModel(target: info())
        XCTAssertTrue(model.click(.tileApp))
        XCTAssertEqual(model.selection, .tileApp)
        XCTAssertFalse(model.isEditingTitle)

        let covered = WindowRulesOverlayModel(target: info(rule: "Never tile: all windows", appFloats: true))
        XCTAssertTrue(covered.click(.forget))
        XCTAssertEqual(covered.selection, .forget)
    }

    // a click on a title row opens its editor like the arrow keys do; a
    // second click on the row (its ↩ chip included) applies it
    func testClickingATitleRowOpensTheEditor() {
        let model = WindowRulesOverlayModel(target: info())
        XCTAssertEqual(model.detail(.floatTitle), "edit title…", "it shows the row takes text")
        XCTAssertFalse(model.click(.floatTitle), "the first click only opens the editor")
        XCTAssertEqual(model.selection, .floatTitle)
        XCTAssertTrue(model.isEditingTitle)
        XCTAssertEqual(model.text, "Chat | Someone", "prefilled with the window's title")
        XCTAssertNil(model.detail(.floatTitle), "the open editor says it")
        XCTAssertEqual(model.detail(.tileTitle), "edit title…")

        XCTAssertFalse(model.click(.tileTitle), "moving to the other title row opens it there")
        XCTAssertEqual(model.selection, .tileTitle)
        XCTAssertTrue(model.click(.tileTitle))

        model.text = ""
        XCTAssertFalse(model.click(.tileTitle), "nothing to apply while the text is empty")

        let keyed = WindowRulesOverlayModel(target: info())
        keyed.move(2)
        XCTAssertEqual(keyed.selection, .floatTitle)
        XCTAssertTrue(keyed.click(.floatTitle), "picked with the keys, a click applies")
    }

    func testTheHeaderChip() {
        XCTAssertEqual(WindowRulesOverlayModel(target: info()).ruleChip, "No rule")
        XCTAssertEqual(WindowRulesOverlayModel(target: info(rule: "Never tile: all windows")).ruleChip, "Always float")
        XCTAssertEqual(WindowRulesOverlayModel(target: info(rule: "Always tile: windows titled “x”")).ruleChip,
                       "Always tile")
    }

    func testAWindowWithNoTitleStartsWithAnEmptyEditor() {
        let model = WindowRulesOverlayModel(target: info(title: ""))
        XCTAssertNil(model.titleMatch)
        XCTAssertFalse(model.isEnabled(.tileTitle))
    }

    func testTheOverlayStaysOnTheWindowsScreen() {
        let rect = WindowRulesOverlayController.placement(size: CGSize(width: 440, height: 300), over: nil)
        XCTAssertEqual(rect.size, CGSize(width: 440, height: 300))
    }
}

final class FailedTilePromptPolicyTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "FailedTilePromptPolicyTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testAskedOncePerApp() {
        let policy = FailedTilePromptPolicy(defaults: defaults)
        XCTAssertTrue(policy.shouldPrompt(bundleID: "com.example.app", isFloating: true,
                                          coveredByRule: false, hasManualChoice: false))
        policy.markAsked("com.example.app")
        XCTAssertFalse(policy.shouldPrompt(bundleID: "com.example.app", isFloating: true,
                                           coveredByRule: false, hasManualChoice: false))
        XCTAssertTrue(policy.shouldPrompt(bundleID: "com.example.other", isFloating: true,
                                          coveredByRule: false, hasManualChoice: false))
        // per Mac, across launches
        XCTAssertFalse(FailedTilePromptPolicy(defaults: defaults)
            .shouldPrompt(bundleID: "com.example.app", isFloating: true, coveredByRule: false, hasManualChoice: false))
    }

    func testNeverWhenItTiledOrARuleOrTheUserPlacedIt() {
        let policy = FailedTilePromptPolicy(defaults: defaults)
        XCTAssertFalse(policy.shouldPrompt(bundleID: "a", isFloating: false, coveredByRule: false, hasManualChoice: false),
                       "it tiled after all")
        XCTAssertFalse(policy.shouldPrompt(bundleID: "a", isFloating: true, coveredByRule: true, hasManualChoice: false))
        XCTAssertFalse(policy.shouldPrompt(bundleID: "a", isFloating: true, coveredByRule: false, hasManualChoice: true))
        XCTAssertFalse(policy.shouldPrompt(bundleID: nil, isFloating: true, coveredByRule: false, hasManualChoice: false))
    }
}

// closing hands focus back to the window the overlay was opened on;
// reopening doesn't bounce it
final class WindowRulesOverlayControllerTests: XCTestCase {
    func testClosingRestoresTheWindow() {
        let controller = WindowRulesOverlayController()
        var restored: [CGWindowID] = []
        var performed: [WindowRulesOverlayModel.Row] = []
        controller.restoreFocus = { restored.append($0) }
        controller.perform = { row, _, _ in performed.append(row) }
        let info = FocusedWindowRuleInfo(windowID: 8905, appName: "Microsoft Teams", bundleID: "com.microsoft.teams2",
                                         title: "Chat", currentRule: nil, appFloats: false, appTiles: false,
                                         isFloating: false)
        controller.show(info, over: nil, icon: nil)
        XCTAssertTrue(controller.isShowing)
        controller.close()
        XCTAssertFalse(controller.isShowing)
        XCTAssertEqual(restored, [8905])

        controller.show(info, over: nil, icon: nil)
        controller.show(info, over: nil, icon: nil)
        XCTAssertEqual(restored, [8905], "reopening doesn't bounce focus")
        controller.close(restoringFocus: false)
        XCTAssertTrue(performed.isEmpty)
    }
}

// it stays about one window: anything that moves on from it closes it
final class WindowRulesOverlayLeaveTests: XCTestCase {
    private func shown() -> (WindowRulesOverlayController, () -> [CGWindowID]) {
        let controller = WindowRulesOverlayController()
        var restored: [CGWindowID] = []
        controller.restoreFocus = { restored.append($0) }
        let info = FocusedWindowRuleInfo(windowID: 8905, appName: "Microsoft Teams", bundleID: "com.microsoft.teams2",
                                         title: "Chat", currentRule: nil, appFloats: false, appTiles: false,
                                         isFloating: false)
        controller.show(info, ownerPID: 4242, over: nil, icon: nil)
        return (controller, { restored })
    }

    func testAClickElsewhereClosesIt() {
        let (c, restored) = shown()
        c.noteClickElsewhere()
        XCTAssertFalse(c.isShowing)
        XCTAssertTrue(restored().isEmpty, "the user moved on; focus stays where they went")
    }

    func testAnotherAppComingForwardClosesItButItsOwnAppDoesNot() {
        let (c, _) = shown()
        c.noteAppActivated(pid: 4242)
        XCTAssertTrue(c.isShowing)
        c.noteAppActivated(pid: getpid())
        XCTAssertTrue(c.isShowing)
        c.noteAppActivated(pid: 777)
        XCTAssertFalse(c.isShowing)
    }

    func testAnotherActionOrTheWindowGoingAwayClosesIt() {
        let (c, _) = shown()
        c.noteWindowsGone([1, 2])
        XCTAssertTrue(c.isShowing)
        c.noteWindowsGone([8905])
        XCTAssertFalse(c.isShowing)

        let (d, _) = shown()
        d.noteOtherAction()
        XCTAssertFalse(d.isShowing)
    }
}
