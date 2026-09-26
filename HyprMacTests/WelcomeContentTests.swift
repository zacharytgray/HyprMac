import XCTest
@testable import HyprMac
import Carbon

final class WelcomeContentTests: XCTestCase {
    func testWhatsNewDescribesOnlyThe0150Changes() {
        let features = WhatsNewFeatures.current

        XCTAssertEqual(features.map(\.title), [
            "Saved Layouts",
            "A Balanced Keybind List"
        ])
        XCTAssertEqual(features[0].credit, "@joops")
        XCTAssertTrue(features[0].description.contains("Hypr+Ctrl+S"))
        XCTAssertNil(features[1].credit)
        XCTAssertFalse(features.map(\.title).contains("A New Look"))
        XCTAssertEqual(WelcomeContent.productURL.absoluteString, "https://hyprmac.app/")
    }

    func testTutorialRequestUsesInjectedRouteAfterClosingHelp() {
        let overlay = KeybindOverlayController()
        var requests = 0
        overlay.onShowTutorial = { [weak overlay] in
            XCTAssertEqual(overlay?.isShowing, false)
            requests += 1
        }

        overlay.openTutorial()
        overlay.openTutorial()

        XCTAssertEqual(requests, 2)
    }

    func testTutorialChordUsesConfiguredHyprKeyAndSavedBinding() {
        let binds = [Keybind(
            keyCode: 40,
            modifiers: [.hypr, .control, .shift],
            action: .toggleFloating)]

        let chord = WelcomeContent.chord(in: binds, hyprKey: .f15) {
            if case .toggleFloating = $0 { return true }
            return false
        }

        XCTAssertEqual(chord, "HYPR ⌃ ⇧ K")
    }

    func testTutorialChordReturnsNilWhenActionWasRemoved() {
        XCTAssertNil(WelcomeContent.chord(in: [], hyprKey: .capsLock) { _ in true })
    }

    func testTutorialUsesConfiguredDedicatedAndWorkspaceTenChords() {
        let binds = [
            Keybind(keyCode: UInt16(kVK_ANSI_F), modifiers: .hypr,
                    action: .moveToNextEmptyWorkspace),
            Keybind(keyCode: UInt16(kVK_ANSI_0), modifiers: [.hypr, .shift],
                    action: .switchWorkspace(10))
        ]

        XCTAssertEqual(WelcomeContent.chord(in: binds, hyprKey: .capsLock) {
            $0 == .moveToNextEmptyWorkspace
        }, "HYPR F")
        XCTAssertEqual(WelcomeContent.chord(in: binds, hyprKey: .capsLock) {
            $0 == .switchWorkspace(10)
        }, "HYPR ⇧ 0")
    }

    func testOverlayGroupsOnlyCanonicalWorkspaceNumberKeys() {
        let canonical = Keybind(
            keyCode: UInt16(kVK_ANSI_3), modifiers: .hypr,
            action: .switchWorkspace(3))
        let customized = Keybind(
            keyCode: UInt16(kVK_ANSI_Q), modifiers: .hypr,
            action: .switchWorkspace(3))

        XCTAssertTrue(KeybindOverlayGrouping.usesCanonicalWorkspaceKey(canonical, number: 3))
        XCTAssertFalse(KeybindOverlayGrouping.usesCanonicalWorkspaceKey(customized, number: 3))

        let tenth = Keybind(
            keyCode: UInt16(kVK_ANSI_0), modifiers: .hypr,
            action: .switchWorkspace(10))
        XCTAssertTrue(KeybindOverlayGrouping.usesCanonicalWorkspaceKey(tenth, number: 10))
    }

    func testOverlayGroupsOnlyMatchingArrowKeys() {
        let canonical = Keybind(
            keyCode: UInt16(kVK_LeftArrow), modifiers: .hypr,
            action: .focusDirection(.left))
        let customized = Keybind(
            keyCode: UInt16(kVK_ANSI_H), modifiers: .hypr,
            action: .focusDirection(.left))

        XCTAssertTrue(KeybindOverlayGrouping.usesCanonicalDirectionKey(canonical, direction: .left))
        XCTAssertFalse(KeybindOverlayGrouping.usesCanonicalDirectionKey(customized, direction: .left))
    }

    func testOverlayFoldsEachWorkspaceFamilyIntoItsOwnRow() throws {
        let binds = Keybind.defaults
        let seeds: [(KeybindOverlayGrouping.WorkspaceFamily, Action, String)] = [
            (.switchTo, .switchWorkspace(1), "Switch to workspace N"),
            (.move, .moveToWorkspace(1), "Move window to workspace N"),
            (.moveAndFollow, .moveToWorkspaceAndFollow(1), "Move window to workspace N and follow"),
        ]
        var claimed = Set<Int>()
        for (family, action, title) in seeds {
            let seed = try XCTUnwrap(binds.first { $0.action == action })
            let run = try XCTUnwrap(KeybindOverlayGrouping.workspaceRun(seededBy: seed, in: binds))
            XCTAssertEqual(run.family, family)
            XCTAssertEqual(run.family.title, title)
            let numbers = run.indices.compactMap {
                KeybindOverlayGrouping.workspaceFamily(of: binds[$0].action)?.number
            }
            XCTAssertEqual(numbers.sorted(), Array(Constants.workspaceRange), title)
            XCTAssertTrue(claimed.isDisjoint(with: run.indices), "\(title) folds only its own binds")
            claimed.formUnion(run.indices)
        }
    }

    func testACustomizedFollowBindBreaksOnlyItsOwnRow() throws {
        var binds = Keybind.defaults
        let index = try XCTUnwrap(binds.firstIndex { $0.action == .moveToWorkspaceAndFollow(4) })
        binds[index] = Keybind(keyCode: UInt16(kVK_ANSI_Q), modifiers: [.hypr, .control, .shift],
                               action: .moveToWorkspaceAndFollow(4))

        let follow = try XCTUnwrap(binds.first { $0.action == .moveToWorkspaceAndFollow(1) })
        let move = try XCTUnwrap(binds.first { $0.action == .moveToWorkspace(1) })
        XCTAssertNil(KeybindOverlayGrouping.workspaceRun(seededBy: follow, in: binds))
        XCTAssertEqual(KeybindOverlayGrouping.workspaceRun(seededBy: move, in: binds)?.indices.count, 10)
    }

    func testOverlaySummarizesOnlyTheCompleteWorkspaceRange() {
        XCTAssertTrue(KeybindOverlayGrouping.isCompleteWorkspaceRange(Array(Constants.workspaceRange)))
        XCTAssertFalse(KeybindOverlayGrouping.isCompleteWorkspaceRange(Array(1...9)))
        XCTAssertFalse(KeybindOverlayGrouping.isCompleteWorkspaceRange([1, 3]))
        XCTAssertFalse(KeybindOverlayGrouping.isCompleteWorkspaceRange([1, 1]))
    }
}

@MainActor
final class LoginItemControllerTests: XCTestCase {
    private enum TestError: Error { case denied }

    func testConstructingAndRefreshingNeverChangesLoginItems() {
        var reads = 0
        var registrations = 0
        var opens = 0
        let controller = LoginItemController(appName: "HyprMac", status: {
            reads += 1
            return .notRegistered
        }, register: { registrations += 1 }, openSettings: { opens += 1 })
        XCTAssertEqual(reads, 0)
        controller.refresh()
        XCTAssertEqual(controller.state, .notEnabled)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(registrations, 0)
        XCTAssertEqual(opens, 0)
    }

    func testYesRegistersOnceAndShowsEnabledAfterSuccess() {
        var status = LoginItemController.ServiceStatus.notRegistered
        var registrations = 0
        var opens = 0
        let controller = LoginItemController(appName: "HyprMac", status: { status }, register: {
            registrations += 1
            status = .enabled
        }, openSettings: { opens += 1 })
        controller.enable()
        controller.enable()
        XCTAssertEqual(controller.state, .enabled)
        XCTAssertEqual(registrations, 1)
        XCTAssertEqual(opens, 0)
        XCTAssertNil(controller.instructionText)
    }

    func testAlreadyEnabledDoesNotRegisterOrOpenSettings() {
        let controller = LoginItemController(appName: "HyprMac", status: { .enabled }, register: {
            XCTFail("already enabled service must not register again")
        }, openSettings: { XCTFail("already enabled service must not open Settings") })
        controller.refresh()
        controller.enable()
        XCTAssertEqual(controller.state, .enabled)
    }

    func testExistingApprovalRequirementOpensSettingsOnlyAfterYes() {
        var opens = 0
        let controller = LoginItemController(appName: "HyprMac Debug", status: { .requiresApproval }, register: {
            XCTFail("pending approval must not register again")
        }, openSettings: { opens += 1 })
        controller.refresh()
        XCTAssertEqual(controller.state, .requiresApproval)
        XCTAssertEqual(opens, 0)
        controller.enable()
        XCTAssertEqual(opens, 1)
        XCTAssertTrue(controller.instructionText?.contains("HyprMac Debug") == true)
        XCTAssertTrue(controller.instructionText?.contains("Login Items") == true)
    }

    func testRegistrationRequiringApprovalIsNotReportedAsEnabled() {
        var status = LoginItemController.ServiceStatus.notRegistered
        var opens = 0
        let controller = LoginItemController(appName: "HyprMac", status: { status }, register: {
            status = .requiresApproval
        }, openSettings: { opens += 1 })
        controller.enable()
        XCTAssertEqual(controller.state, .requiresApproval)
        XCTAssertEqual(opens, 1)
    }

    func testRegistrationFailureOpensSettingsWithManualInstructions() {
        var opens = 0
        let controller = LoginItemController(appName: "HyprMac Debug", status: { .notRegistered }, register: {
            throw TestError.denied
        }, openSettings: { opens += 1 })
        controller.enable()
        guard case .failed = controller.state else { return XCTFail("failure must not report enabled") }
        XCTAssertEqual(opens, 1)
        XCTAssertTrue(controller.instructionText?.contains("HyprMac Debug") == true)
        XCTAssertTrue(controller.instructionText?.contains("Open at Login") == true)
        XCTAssertTrue(controller.instructionText?.contains("+") == true)
    }

    func testRegistrationWithoutEnabledStatusUsesManualFallback() {
        for status in [LoginItemController.ServiceStatus.notRegistered, .unavailable] {
            var registrations = 0
            var opens = 0
            let controller = LoginItemController(appName: "HyprMac", status: { status }, register: {
                registrations += 1
            }, openSettings: { opens += 1 })
            controller.enable()
            guard case .failed = controller.state else { return XCTFail("unconfirmed registration must not report enabled") }
            XCTAssertEqual(registrations, 1)
            XCTAssertEqual(opens, 1)
        }
    }

    func testRefreshRetainsFallbackAndReflectsExternalApprovalAndDisable() {
        var status = LoginItemController.ServiceStatus.notRegistered
        var opens = 0
        var registrations = 0
        let controller = LoginItemController(appName: "HyprMac", status: { status }, register: {
            registrations += 1
            throw TestError.denied
        }, openSettings: { opens += 1 })
        controller.enable()
        controller.refresh()
        guard case .failed = controller.state else { return XCTFail("fallback instructions must remain visible") }
        status = .enabled
        controller.refresh()
        XCTAssertEqual(controller.state, .enabled)
        status = .notRegistered
        controller.refresh()
        XCTAssertEqual(controller.state, .notEnabled)
        XCTAssertEqual(registrations, 1)
        XCTAssertEqual(opens, 1)
    }

    func testRefreshReflectsAnExternallyRemovedPendingLoginItem() {
        var status = LoginItemController.ServiceStatus.requiresApproval
        let controller = LoginItemController(appName: "HyprMac", status: { status }, register: {
            XCTFail("refresh must not register")
        }, openSettings: { XCTFail("refresh must not open Settings") })
        controller.refresh()
        XCTAssertEqual(controller.state, .requiresApproval)
        status = .notRegistered
        controller.refresh()
        XCTAssertEqual(controller.state, .notEnabled)
        XCTAssertNil(controller.instructionText)
    }

    func testExplicitManageActionOnlyOpensSettings() {
        var opens = 0
        let controller = LoginItemController(appName: "HyprMac", status: { .enabled }, register: {
            XCTFail("manage action must not register")
        }, openSettings: { opens += 1 })
        controller.openLoginItems()
        XCTAssertEqual(opens, 1)
    }
}
