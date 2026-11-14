import XCTest
@testable import HyprMac
import Carbon

// SecureInputTests pin what HyprMac does when macOS turns on Secure Event
// Input: a transition clears a Hypr key whose keyUp the tap never saw, the
// owner hears about each edge once, and the menu bar text names the app
// macOS reports. Nothing here enables real secure input; the state is a
// closure.

final class SecureInputTests: XCTestCase {

    private let onePassword = SecureInputHolder(pid: 4845, appName: "1Password")

    func testMonitorReportsEachEdgeOnce() {
        var on = false
        let monitor = SecureInputMonitor(isEnabled: { on }, holder: { self.onePassword })

        XCTAssertNil(monitor.poll())
        on = true
        XCTAssertEqual(monitor.poll(), .enabled(onePassword))
        XCTAssertNil(monitor.poll())
        XCTAssertTrue(monitor.isActive)
        on = false
        XCTAssertEqual(monitor.poll(), .disabled)
        XCTAssertNil(monitor.poll())
        XCTAssertFalse(monitor.isActive)
    }

    func testMonitorReadsTheHolderOnlyWhenSecureInputTurnsOn() {
        var on = false
        var holderReads = 0
        let monitor = SecureInputMonitor(isEnabled: { on }, holder: {
            holderReads += 1
            return nil
        })

        _ = monitor.poll()
        on = true
        XCTAssertEqual(monitor.poll(), .enabled(nil))
        _ = monitor.poll()
        on = false
        _ = monitor.poll()
        XCTAssertEqual(holderReads, 1)
    }

    // F18 down reaches the tap, then a password field takes focus and the
    // F18 up never does. The Caps Lock remap skips the stale check, so only
    // the secure input transition can clear it.
    func testSecureInputTurningOnClearsAStuckHyprKey() {
        var on = false
        let manager = HotkeyManager(secureInput: SecureInputMonitor(isEnabled: { on }, holder: { nil }))
        manager.updateKeybinds(Keybind.defaults)
        var transitions: [SecureInputMonitor.Transition] = []
        manager.onSecureInputChange = { transitions.append($0) }

        XCTAssertNil(manager.handleEvent(.keyDown, key(HyprKey.capsLock.keyCode)))
        XCTAssertTrue(manager.isHyprKeyDown)

        on = true
        manager.checkSecureInput()

        XCTAssertFalse(manager.isHyprKeyDown)
        XCTAssertTrue(manager.isSecureInputActive)
        XCTAssertEqual(transitions, [.enabled(nil)])
    }

    // after secure input ends, a plain keystroke must type, not fire the
    // chord the stuck Hypr key would have made of it
    func testPlainKeyAfterSecureInputIsNotAChord() {
        var on = false
        let manager = HotkeyManager(secureInput: SecureInputMonitor(isEnabled: { on }, holder: { nil }))
        manager.updateKeybinds(Keybind.defaults)
        var actions: [Action] = []
        manager.onAction = { actions.append($0) }

        XCTAssertNil(manager.handleEvent(.keyDown, key(HyprKey.capsLock.keyCode)))
        on = true
        manager.checkSecureInput()
        on = false
        manager.checkSecureInput()

        XCTAssertNotNil(manager.handleEvent(.keyDown, key(UInt16(kVK_ANSI_1))),
                        "plain 1 must pass through, not fire Hypr+1")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(actions, [])
    }

    func testChordsWorkAgainAfterSecureInputEnds() {
        var on = true
        let manager = HotkeyManager(secureInput: SecureInputMonitor(isEnabled: { on }, holder: { nil }))
        manager.updateKeybinds(Keybind.defaults)
        var transitions: [SecureInputMonitor.Transition] = []
        manager.onSecureInputChange = { transitions.append($0) }
        let dispatched = expectation(description: "Hypr+1 dispatched")
        var actions: [Action] = []
        manager.onAction = { actions.append($0); dispatched.fulfill() }

        manager.checkSecureInput()
        on = false
        manager.checkSecureInput()
        XCTAssertEqual(transitions, [.enabled(nil), .disabled])

        XCTAssertNil(manager.handleEvent(.keyDown, key(HyprKey.capsLock.keyCode)))
        XCTAssertNil(manager.handleEvent(.keyDown, key(UInt16(kVK_ANSI_1))))
        wait(for: [dispatched], timeout: 1)
        XCTAssertEqual(actions, [.switchWorkspace(1)])
    }

    func testNoTransitionLeavesHyprStateAlone() {
        let manager = HotkeyManager(secureInput: SecureInputMonitor(isEnabled: { false }, holder: { nil }))
        var transitions = 0
        manager.onSecureInputChange = { _ in transitions += 1 }

        XCTAssertNil(manager.handleEvent(.keyDown, key(HyprKey.capsLock.keyCode)))
        manager.checkSecureInput()

        XCTAssertTrue(manager.isHyprKeyDown, "a real Hypr hold must survive a quiet check")
        XCTAssertEqual(transitions, 0)
    }

    func testStopClearsAnActiveSecureInputHint() {
        let manager = HotkeyManager(secureInput: SecureInputMonitor(isEnabled: { true }, holder: { nil }))
        var transitions: [SecureInputMonitor.Transition] = []
        manager.onSecureInputChange = { transitions.append($0) }

        manager.checkSecureInput()
        manager.stop()

        XCTAssertFalse(manager.isSecureInputActive)
        XCTAssertEqual(transitions, [.enabled(nil), .disabled])
    }

    func testHolderPIDComesFromTheConsoleUserThatHasOne() {
        let users: [[String: Any]] = [
            ["kCGSSessionUserNameKey": "other"],
            ["kCGSSessionUserNameKey": "me", "kCGSSessionSecureInputPID": NSNumber(value: 4845)]
        ]
        XCTAssertEqual(SecureInputMonitor.holderPID(inConsoleUsers: users), 4845)
        XCTAssertNil(SecureInputMonitor.holderPID(inConsoleUsers: [["kCGSSessionSecureInputPID": NSNumber(value: 0)]]))
        XCTAssertNil(SecureInputMonitor.holderPID(inConsoleUsers: []))
    }

    func testHolderDisplayNameFallsBackToThePID() {
        XCTAssertEqual(onePassword.displayName, "1Password")
        XCTAssertEqual(SecureInputHolder(pid: 77, appName: nil).displayName, "pid 77")
    }

    func testMenuBarNoticeNamesTheReportedApp() {
        XCTAssertEqual(MenuBarPresentation.secureInputNotice(holderName: "1Password"),
                       "Hypr shortcuts are paused while secure input is on (macOS reports 1Password).")
        XCTAssertEqual(MenuBarPresentation.secureInputNotice(holderName: nil),
                       "Hypr shortcuts are paused while secure input is on.")
        XCTAssertEqual(MenuBarPresentation.secureInputNotice(holderName: ""),
                       "Hypr shortcuts are paused while secure input is on.")
    }

    private func key(_ keyCode: UInt16) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true)!
        event.flags = []
        return event
    }
}
