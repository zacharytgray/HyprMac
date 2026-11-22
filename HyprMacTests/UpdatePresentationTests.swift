import XCTest
@testable import HyprMac

final class UpdatePresentationTests: XCTestCase {
    func testVersionLabelShowsBuildOnlyWhenItAddsSomething() {
        XCTAssertEqual(UpdatePresentation.versionLabel(version: "0.26.0", build: "113"), "v0.26.0 (113)")
        XCTAssertEqual(UpdatePresentation.versionLabel(version: "0.26.0", build: nil), "v0.26.0")
        XCTAssertEqual(UpdatePresentation.versionLabel(version: "0.26.0", build: ""), "v0.26.0")
        XCTAssertEqual(UpdatePresentation.versionLabel(version: "0.26.0", build: "0.26.0"), "v0.26.0")
    }

    func testIdleRowIsAPlainCheck() {
        let row = UpdatePresentation.sidebarRow(for: nil, canCheckForUpdates: true)
        XCTAssertEqual(row.title, "Check for Updates")
        XCTAssertNil(row.detail)
        XCTAssertFalse(row.highlighted)
        XCTAssertTrue(row.enabled)
    }

    // sparkle refuses a check while it downloads in the background
    func testBackgroundCheckDisablesTheCheck() {
        let row = UpdatePresentation.sidebarRow(for: nil, canCheckForUpdates: false)
        XCTAssertEqual(row.title, "Check for Updates")
        XCTAssertEqual(row.detail, "Checking…")
        XCTAssertFalse(row.enabled)
    }

    // the session holding a downloaded update keeps canCheckForUpdates false;
    // nothing is checking, so the row must not say so
    func testReadyUpdateReplacesTheCheckAndNeverSaysChecking() {
        for canCheck in [true, false] {
            let row = UpdatePresentation.sidebarRow(for: .ready(version: "0.27.0"), canCheckForUpdates: canCheck)
            XCTAssertEqual(row.title, "Restart to Update")
            XCTAssertEqual(row.detail, "HyprMac 0.27.0 is ready to install")
            XCTAssertTrue(row.highlighted)
            XCTAssertTrue(row.enabled)
        }
    }

    func testAvailableUpdateShowsTheWindowAction() {
        let row = UpdatePresentation.sidebarRow(for: .available(version: "0.27.0"), canCheckForUpdates: true)
        XCTAssertEqual(row.title, "Show Update")
        XCTAssertEqual(row.detail, "HyprMac 0.27.0 is available")
        XCTAssertTrue(row.highlighted)
        XCTAssertTrue(row.enabled)
    }

    // the sidebar row and the menu bar dot's tooltip name the update the same way
    func testDetailMatchesTheMenuBarTooltip() {
        for notice in [UpdateNotice.available(version: "1.0"), .ready(version: "1.0")] {
            XCTAssertEqual(UpdatePresentation.sidebarRow(for: notice, canCheckForUpdates: true).detail,
                           MenuBarPresentation.updateHelp(for: notice))
        }
    }

    // a downloaded update installs without asking Sparkle for a check
    func testCanActivate() {
        XCTAssertTrue(UpdatePresentation.canActivate(notice: nil, canCheckForUpdates: true))
        XCTAssertFalse(UpdatePresentation.canActivate(notice: nil, canCheckForUpdates: false))
        XCTAssertFalse(UpdatePresentation.canActivate(notice: .available(version: "1.0"), canCheckForUpdates: false))
        XCTAssertTrue(UpdatePresentation.canActivate(notice: .ready(version: "1.0"), canCheckForUpdates: false))
    }
}
