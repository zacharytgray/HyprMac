import XCTest
import Carbon
import IOKit
@testable import HyprMac

final class PhysicalKeyHoldStateTests: XCTestCase {
    func testOneKeyboardDownThenUpReleases() {
        var hold = PhysicalKeyHoldState()
        XCTAssertFalse(hold.keyChanged(device: 1, isDown: true))
        XCTAssertTrue(hold.isHeld)
        XCTAssertTrue(hold.keyChanged(device: 1, isDown: false))
        XCTAssertFalse(hold.isHeld)
    }

    func testHeldOnTwoKeyboardsStaysHeldUntilBothAreUp() {
        var hold = PhysicalKeyHoldState()
        hold.keyChanged(device: 1, isDown: true)
        hold.keyChanged(device: 2, isDown: true)
        XCTAssertFalse(hold.keyChanged(device: 1, isDown: false))
        XCTAssertTrue(hold.isHeld)
        XCTAssertTrue(hold.keyChanged(device: 2, isDown: false))
        XCTAssertFalse(hold.isHeld)
    }

    func testRemovingTheHoldingKeyboardReleases() {
        var hold = PhysicalKeyHoldState()
        hold.keyChanged(device: 7, isDown: true)
        XCTAssertTrue(hold.deviceRemoved(7))
        XCTAssertFalse(hold.isHeld)
    }

    func testRemovingAnotherKeyboardKeepsTheHold() {
        var hold = PhysicalKeyHoldState()
        hold.keyChanged(device: 1, isDown: true)
        hold.keyChanged(device: 2, isDown: true)
        XCTAssertFalse(hold.deviceRemoved(2))
        XCTAssertFalse(hold.deviceRemoved(3))
        XCTAssertEqual(hold.holders, [1])
    }

    func testUpWithoutDownIsNotARelease() {
        var hold = PhysicalKeyHoldState()
        XCTAssertFalse(hold.keyChanged(device: 1, isDown: false))
        XCTAssertFalse(hold.deviceRemoved(1))
    }

    func testRepeatedDownFromOneKeyboardNeedsOneUp() {
        var hold = PhysicalKeyHoldState()
        hold.keyChanged(device: 1, isDown: true)
        hold.keyChanged(device: 1, isDown: true)
        XCTAssertTrue(hold.keyChanged(device: 1, isDown: false))
    }

    func testResetForgetsEveryHolder() {
        var hold = PhysicalKeyHoldState()
        hold.keyChanged(device: 1, isDown: true)
        hold.keyChanged(device: 2, isDown: true)
        hold.reset()
        XCTAssertFalse(hold.isHeld)
        XCTAssertFalse(hold.keyChanged(device: 1, isDown: false))
    }
}

/// Stands in for the IOHIDManager reader.
private final class FakePhysicalCapsLock: PhysicalCapsLockReading {
    var isActive = false
    var isCapsLockDown = false
    var onRelease: (() -> Void)?
    var startResult = kIOReturnSuccess
    var startCount = 0
    var stopCount = 0
    var resetCount = 0

    func start(on runLoop: CFRunLoop) -> IOReturn {
        startCount += 1
        if startResult == kIOReturnSuccess { isActive = true }
        return startResult
    }

    func stop() {
        stopCount += 1
        isActive = false
        isCapsLockDown = false
    }

    func reset() {
        resetCount += 1
        isCapsLockDown = false
    }

    /// The last held Caps Lock comes up.
    func release() {
        isCapsLockDown = false
        onRelease?()
    }
}

final class HotkeyManagerPhysicalCapsLockTests: XCTestCase {
    private var physical: FakePhysicalCapsLock!
    private var granted = true
    private var manager: HotkeyManager!
    private let chordKey = UInt16(kVK_ANSI_H)

    override func setUp() {
        super.setUp()
        physical = FakePhysicalCapsLock()
        granted = true
        manager = HotkeyManager(physicalKeys: physical, hasKeyboardAccess: { [unowned self] in self.granted })
        manager.updateKeybinds([Keybind(keyCode: chordKey, modifiers: .hypr, action: .toggleFloating)])
        manager.updateHyprKey(.capsLock)
    }

    override func tearDown() {
        manager = nil
        physical = nil
        super.tearDown()
    }

    // MARK: helpers

    private func key(_ code: UInt16, down: Bool) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!
        event.flags = []
        return event
    }

    private func hypr(_ hyprKey: HyprKey = .capsLock, down: Bool) {
        XCTAssertNil(manager.handleEvent(down ? .keyDown : .keyUp, key(hyprKey.keyCode, down: down)),
                     "the Hypr key is always swallowed")
    }

    /// true when the chord key was taken as Hypr+H
    private func chordFires() -> Bool {
        manager.handleEvent(.keyDown, key(chordKey, down: true)) == nil
    }

    private func startMonitor() {
        manager.refreshPhysicalKeyMonitor(runLoop: CFRunLoopGetCurrent())
        XCTAssertTrue(physical.isActive)
    }

    // MARK: the #81 path

    func testF18ReleaseIsIgnoredWhileCapsLockIsPhysicallyHeld() {
        startMonitor()
        physical.isCapsLockDown = true
        hypr(down: true)
        XCTAssertTrue(chordFires())
        // control comes up and macOS sends the F18 release early
        hypr(down: false)
        XCTAssertTrue(chordFires(), "Hypr should still be held")
    }

    func testPhysicalReleaseEndsHyprAfterAnIgnoredRelease() {
        startMonitor()
        physical.isCapsLockDown = true
        hypr(down: true)
        hypr(down: false)
        physical.release()
        XCTAssertFalse(chordFires(), "Hypr should end on the physical release")
    }

    func testNormalPressEndsOnThePhysicalReleaseFirst() {
        startMonitor()
        physical.isCapsLockDown = true
        hypr(down: true)
        // the physical up lands a few ms before the F18 release
        physical.release()
        XCTAssertFalse(chordFires())
        hypr(down: false)
        XCTAssertFalse(chordFires())
    }

    func testHyprKeyUpCallbackFiresOnceForAnIgnoredThenPhysicalRelease() {
        startMonitor()
        var ups = 0
        manager.onHyprKeyUp = { ups += 1 }
        physical.isCapsLockDown = true
        hypr(down: true)
        hypr(down: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(ups, 0)
        physical.release()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(ups, 1)
    }

    // MARK: fallback

    func testWithoutTheMonitorF18ReleaseEndsHyprAsBefore() {
        granted = false
        manager.refreshPhysicalKeyMonitor(runLoop: CFRunLoopGetCurrent())
        XCTAssertFalse(physical.isActive)
        XCTAssertEqual(physical.startCount, 0, "no keyboard is opened without access")
        // even a stale held answer is not trusted while the monitor is off
        physical.isCapsLockDown = true
        hypr(down: true)
        hypr(down: false)
        XCTAssertFalse(chordFires())
    }

    func testNonCapsLockHyprKeyIgnoresPhysicalState() {
        // right command: a native modifier, so the tap sees flagsChanged
        // and the chord carries the command flag
        manager.updateHyprKey(.rightCommand)
        physical.isActive = true
        physical.isCapsLockDown = true
        let command = UInt16(kVK_RightCommand)
        func toggleCommand() {
            let event = key(command, down: true)
            XCTAssertNil(manager.handleEvent(.flagsChanged, event))
        }
        func chordWithCommand() -> Bool {
            let event = key(chordKey, down: true)
            event.flags = .maskCommand
            return manager.handleEvent(.keyDown, event) == nil
        }
        toggleCommand()
        XCTAssertTrue(chordWithCommand())
        toggleCommand()
        XCTAssertFalse(chordFires(), "the held Caps Lock answer must not keep Command held")

        // a physical Caps Lock release does nothing to a Command press
        toggleCommand()
        physical.release()
        XCTAssertTrue(chordWithCommand())
    }

    // MARK: safety

    func testTapInterruptionResetClearsHeldState() {
        startMonitor()
        physical.isCapsLockDown = true
        hypr(down: true)
        hypr(down: false)
        manager.resetTrackingAfterTapInterruption()
        XCTAssertEqual(physical.resetCount, 1)
        XCTAssertFalse(physical.isCapsLockDown)
        XCTAssertFalse(chordFires())
    }

    func testRevokedAccessStopsTheMonitorAndEndsAnIgnoredPress() {
        startMonitor()
        physical.isCapsLockDown = true
        hypr(down: true)
        hypr(down: false)
        granted = false
        manager.refreshPhysicalKeyMonitor(runLoop: CFRunLoopGetCurrent())
        XCTAssertFalse(physical.isActive)
        XCTAssertFalse(chordFires(), "no physical up is coming, so Hypr must not stay held")
    }

    // MARK: lifecycle

    func testMonitorRunsOnlyWhileCapsLockIsTheHyprKey() {
        startMonitor()
        XCTAssertEqual(physical.startCount, 1)
        // updateHyprKey refreshes on the tap's run loop, which tests don't have
        manager.updateHyprKey(.tab)
        XCTAssertFalse(physical.isActive)
        XCTAssertEqual(physical.stopCount, 1)

        manager.refreshPhysicalKeyMonitor(runLoop: CFRunLoopGetCurrent())
        XCTAssertFalse(physical.isActive, "Tab never opens the keyboards")

        manager.updateHyprKey(.capsLock)
        manager.refreshPhysicalKeyMonitor(runLoop: CFRunLoopGetCurrent())
        XCTAssertTrue(physical.isActive)
        XCTAssertEqual(physical.startCount, 2)
    }

    func testGrantAfterLaunchStartsTheMonitorOnTheNextRefresh() {
        granted = false
        manager.refreshPhysicalKeyMonitor(runLoop: CFRunLoopGetCurrent())
        XCTAssertFalse(physical.isActive)
        granted = true
        manager.refreshPhysicalKeyMonitor(runLoop: CFRunLoopGetCurrent())
        XCTAssertTrue(physical.isActive)
    }

    func testOpenFailureKeepsTheOldBehaviorAndRetries() {
        physical.startResult = IOReturn(bitPattern: 0xE000_02E2) // kIOReturnNotPermitted
        manager.refreshPhysicalKeyMonitor(runLoop: CFRunLoopGetCurrent())
        XCTAssertFalse(physical.isActive)
        physical.isCapsLockDown = true
        hypr(down: true)
        hypr(down: false)
        XCTAssertFalse(chordFires(), "a failed open must not hold Hypr")

        physical.startResult = kIOReturnSuccess
        manager.refreshPhysicalKeyMonitor(runLoop: CFRunLoopGetCurrent())
        XCTAssertTrue(physical.isActive)
        XCTAssertEqual(physical.startCount, 2)
    }

    // MARK: paused (#94)

    /// the event came back out of the tap instead of being swallowed
    private func passes(_ type: CGEventType, _ code: UInt16, flags: CGEventFlags = []) -> Bool {
        let event = key(code, down: type != .keyUp)
        event.flags = flags
        return manager.handleEvent(type, event) != nil
    }

    private func bindPause() {
        manager.updateKeybinds([Keybind(keyCode: chordKey, modifiers: .hypr, action: .toggleTiling)])
    }

    func testPausedCapsLockHyprKeyIsNotHypr() {
        bindPause()
        manager.updateTilingEnabled(false)
        // the remap is gone, so F18 here is a real F18 key
        XCTAssertTrue(passes(.keyDown, HyprKey.capsLock.keyCode))
        XCTAssertFalse(chordFires(), "nothing may resume tiling behind a plain key")
        XCTAssertTrue(passes(.keyUp, HyprKey.capsLock.keyCode))
    }

    func testPausingMidPressDropsTheHeldHypr() {
        bindPause()
        hypr(down: true)
        // Caps+P paused tiling; the remap goes away and the F18 release never comes
        manager.updateTilingEnabled(false)
        XCTAssertFalse(chordFires(), "a stuck Hypr would turn a typed key into a resume")
    }

    func testPausedTypingHyprKeyTypesAgain() {
        bindPause()
        for typing in [HyprKey.backslash, .tab, .grave] {
            manager.updateHyprKey(typing)
            manager.updateTilingEnabled(true)
            XCTAssertFalse(passes(.keyDown, typing.keyCode), "\(typing.rawValue) is swallowed while tiling is on")
            XCTAssertFalse(passes(.keyUp, typing.keyCode))

            manager.updateTilingEnabled(false)
            XCTAssertTrue(passes(.keyDown, typing.keyCode), "\(typing.rawValue) types while paused")
            XCTAssertFalse(chordFires(), "\(typing.rawValue) is not Hypr while paused")
            XCTAssertTrue(passes(.keyUp, typing.keyCode))
        }
    }

    func testPausedModifierHyprKeyPassesThroughAndStillResumes() {
        bindPause()
        manager.updateHyprKey(.rightCommand)
        let command = UInt16(kVK_RightCommand)

        XCTAssertFalse(passes(.flagsChanged, command), "swallowed while tiling is on")
        XCTAssertFalse(passes(.flagsChanged, command))

        manager.updateTilingEnabled(false)
        XCTAssertTrue(passes(.flagsChanged, command), "paused: macOS gets the key back")
        XCTAssertFalse(passes(.keyDown, chordKey, flags: .maskCommand), "Hypr+P still resumes")
        XCTAssertTrue(passes(.flagsChanged, command))
        XCTAssertTrue(passes(.keyDown, chordKey), "released: a plain key again")
    }

    func testResumingMakesTheHyprKeyHyprAgain() {
        manager.updateTilingEnabled(false)
        manager.updateTilingEnabled(true)
        hypr(down: true)
        XCTAssertTrue(chordFires())
        hypr(down: false)
    }
}
