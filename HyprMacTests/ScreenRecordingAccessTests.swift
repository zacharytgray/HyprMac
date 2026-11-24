import XCTest
@testable import HyprMac

// Screen Recording's three states: usable here, not granted, and granted
// but waiting on a reopen
final class ScreenRecordingAccessTests: XCTestCase {
    private func access(here: Bool, fresh: Bool) -> (ScreenRecordingAccess, () -> Int) {
        let access = ScreenRecordingAccess()
        var freshChecks = 0
        access.inProcess = { here }
        access.freshCheck = { done in
            freshChecks += 1
            done(fresh)
        }
        return (access, { freshChecks })
    }

    func testGrantedHereNeedsNoFreshCheck() {
        let (access, checks) = access(here: true, fresh: false)
        access.refresh()
        XCTAssertEqual(access.state, .granted)
        XCTAssertEqual(checks(), 0)
    }

    func testGrantedOnlyInAFreshProcessNeedsAReopen() {
        let (access, _) = access(here: false, fresh: true)
        access.refresh()
        XCTAssertEqual(access.state, .needsReopen)
    }

    func testNotGrantedAnywhere() {
        let (access, _) = access(here: false, fresh: false)
        access.refresh()
        XCTAssertEqual(access.state, .notGranted)
    }

    // the running copy caught up while the fresh check ran
    func testCatchingUpDuringTheFreshCheckCountsAsGranted() {
        let access = ScreenRecordingAccess()
        var here = false
        access.inProcess = { here }
        access.freshCheck = { done in
            here = true
            done(true)
        }
        access.refresh()
        XCTAssertEqual(access.state, .granted)
    }

    // nothing shows until the first answer, so the state never flips from
    // not granted to reopen
    func testNoStateUntilTheFirstAnswer() {
        let access = ScreenRecordingAccess()
        var pending: ((Bool) -> Void)?
        access.inProcess = { false }
        access.freshCheck = { pending = $0 }
        access.refresh()
        XCTAssertNil(access.state)
        access.refresh()
        pending?(true)
        XCTAssertEqual(access.state, .needsReopen)
    }

    func testReopenAndSettingsGoThroughTheirHooks() {
        let access = ScreenRecordingAccess(state: .needsReopen)
        var reopened = 0, opened = 0
        access.reopenApp = { reopened += 1 }
        access.openSettingsPane = { opened += 1 }
        access.reopen()
        access.openSettings()
        XCTAssertEqual(reopened, 1)
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(ScreenRecordingAccess.settingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    func testEachStateHasItsOwnLine() {
        let lines = [ScreenRecordingAccess.State.granted, .notGranted, .needsReopen].map(\.message)
        XCTAssertEqual(Set(lines).count, 3)
        XCTAssertTrue(ScreenRecordingAccess.State.needsReopen.message.contains("Reopen HyprMac"))
    }
}
