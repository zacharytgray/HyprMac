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
        XCTAssertEqual(model.rows, [.once, .floatApp, .tileApp, .floatTitle, .tileTitle])
        XCTAssertEqual(model.label(.once), "Float this window")
        XCTAssertEqual(model.label(.floatApp), "Always float all Microsoft Teams windows")

        let covered = WindowRulesOverlayModel(target: info(rule: "Never tile: all windows", appFloats: true,
                                                           floating: true))
        XCTAssertEqual(covered.rows, [.once, .tileApp, .floatTitle, .tileTitle, .forget],
                       "the app rule in effect isn't offered again; Forget shows")
        XCTAssertEqual(covered.label(.once), "Tile this window")
        XCTAssertEqual(covered.label(.forget), "Forget the rule: Never tile: all windows")
    }

    func testUpAndDownWrap() {
        let model = WindowRulesOverlayModel(target: info())
        XCTAssertEqual(model.selection, .once)
        model.move(-1)
        XCTAssertEqual(model.selection, .tileTitle)
        model.move(1)
        model.move(1)
        XCTAssertEqual(model.selection, .floatApp)
    }

    // prefilled with the window's title, trimmed by the user. typing moves
    // the pick to the title rule
    func testTheTitleEditor() {
        let model = WindowRulesOverlayModel(target: info(title: "Weekly sync | Meeting | Microsoft Teams"))
        XCTAssertEqual(model.titleMatch, .titleIs("Weekly sync | Meeting | Microsoft Teams"))
        model.text = "Meeting"
        XCTAssertEqual(model.selection, .floatTitle)
        model.contains = true
        XCTAssertEqual(model.titleMatch, .titleContains("Meeting"))
        model.selection = .tileTitle
        model.text = "Meeting "
        XCTAssertEqual(model.selection, .tileTitle, "typing on a title row keeps it")
        XCTAssertEqual(model.titleMatch, .titleContains("Meeting"))
        model.text = "  "
        XCTAssertNil(model.titleMatch)
        XCTAssertFalse(model.isEnabled(.floatTitle))
        XCTAssertTrue(model.isEnabled(.floatApp))
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

// live check: with another app in front the overlay never got Esc or the
// typing. it brings HyprMac forward on open and hands focus back on close
final class WindowRulesOverlayControllerTests: XCTestCase {
    func testOpeningActivatesAndClosingRestoresTheWindow() {
        let controller = WindowRulesOverlayController()
        var activations = 0
        var restored: [CGWindowID] = []
        var performed: [WindowRulesOverlayModel.Row] = []
        controller.activateApp = { activations += 1 }
        controller.restoreFocus = { restored.append($0) }
        controller.perform = { row, _, _ in performed.append(row) }
        var later: [() -> Void] = []
        controller.schedule = { _, body in later.append(body) }
        let info = FocusedWindowRuleInfo(windowID: 8905, appName: "Microsoft Teams", bundleID: "com.microsoft.teams2",
                                         title: "Chat", currentRule: nil, appFloats: false, appTiles: false,
                                         isFloating: false)
        controller.show(info, over: nil, icon: nil)
        XCTAssertEqual(activations, 1)
        XCTAssertTrue(controller.isShowing)
        // the Hypr key's focus pass re-activated the window's app after the
        // overlay opened, and the typing went there. it takes the keys back
        later.forEach { $0() }
        XCTAssertEqual(activations, 1 + WindowRulesOverlayController.reassertDelays.count)
        later.removeAll()

        controller.close()
        XCTAssertFalse(controller.isShowing)
        XCTAssertEqual(restored, [8905], "Esc hands focus back to the window")

        controller.show(info, over: nil, icon: nil)
        let stale = later
        controller.show(info, over: nil, icon: nil)
        XCTAssertEqual(restored, [8905], "reopening doesn't bounce focus")
        let before = activations
        stale.forEach { $0() }
        XCTAssertEqual(activations, before, "a closed panel's re-assert does nothing")
        controller.close(restoringFocus: false)
        XCTAssertTrue(performed.isEmpty)
    }
}
