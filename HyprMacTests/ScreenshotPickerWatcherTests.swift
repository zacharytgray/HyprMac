import XCTest
@testable import HyprMac

final class ScreenshotPickerWatcherTests: XCTestCase {
    private var uiRunning = false
    private var overlay = false
    private var time: CFAbsoluteTime = 100
    private var changes: [Bool] = []

    private func makeWatcher() -> ScreenshotPickerWatcher {
        let watcher = ScreenshotPickerWatcher()
        watcher.isUIRunning = { [unowned self] in self.uiRunning }
        watcher.isOverlayVisible = { [unowned self] in self.overlay }
        watcher.now = { [unowned self] in self.time }
        watcher.onChange = { [unowned self] open in self.changes.append(open) }
        addTeardownBlock { watcher.stop() }
        return watcher
    }

    func testOpensAsSoonAsScreencaptureUILaunches() {
        let watcher = makeWatcher()
        uiRunning = true
        watcher.evaluate()
        XCTAssertTrue(watcher.isOpen, "the overlay may not be listed yet")
    }

    func testClosesWhenOverlayGoesEvenIfThumbnailKeepsProcessAlive() {
        let watcher = makeWatcher()
        uiRunning = true
        overlay = true
        watcher.evaluate()
        overlay = false
        time += 0.2
        watcher.evaluate()
        XCTAssertFalse(watcher.isOpen)
        XCTAssertEqual(changes, [true, false])
    }

    func testSecondPickerDuringThumbnailReopens() {
        let watcher = makeWatcher()
        uiRunning = true
        overlay = true
        watcher.evaluate()
        overlay = false
        watcher.evaluate()
        overlay = true
        watcher.evaluate()
        XCTAssertTrue(watcher.isOpen)
        XCTAssertEqual(changes, [true, false, true])
    }

    func testOverlayThatNeverShowsClosesAfterTheGrace() {
        let watcher = makeWatcher()
        uiRunning = true
        watcher.evaluate()
        time += ScreenshotPickerWatcher.overlayGrace - 0.1
        watcher.evaluate()
        XCTAssertTrue(watcher.isOpen)
        time += 0.2
        watcher.evaluate()
        XCTAssertFalse(watcher.isOpen, "a changed owner name must not leave the dim off")
    }

    func testClosesWhenProcessExitsAndOpensAgainOnNextLaunch() {
        let watcher = makeWatcher()
        uiRunning = true
        overlay = true
        watcher.evaluate()
        uiRunning = false
        overlay = false
        watcher.evaluate()
        XCTAssertFalse(watcher.isOpen)
        uiRunning = true
        watcher.evaluate()
        XCTAssertTrue(watcher.isOpen)
        XCTAssertEqual(changes, [true, false, true])
    }

    func testRepeatedEvaluationsReportEachChangeOnce() {
        let watcher = makeWatcher()
        uiRunning = true
        overlay = true
        watcher.evaluate()
        watcher.evaluate()
        watcher.evaluate()
        XCTAssertEqual(changes, [true])
    }
}
