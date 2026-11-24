import Cocoa
import IOSurface
import XCTest
@testable import HyprMac

// the stand-in keeps its last picture after the stream stops, as a copy:
// the stream writes into the same surfaces again

private func surface(width: Int, height: Int, fill: UInt8) -> IOSurface {
    let s = IOSurface(properties: [
        .width: width, .height: height, .bytesPerElement: 4,
        .pixelFormat: kCVPixelFormatType_32BGRA,
    ])!
    s.lock(options: [], seed: nil)
    memset(s.baseAddress, Int32(fill), s.allocationSize)
    s.unlock(options: [], seed: nil)
    return s
}

final class FloaterStandInViewTests: XCTestCase {
    func testAViewWithoutAPictureShowsTheCard() {
        let view = StandInView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertFalse(view.hasPicture)
        view.setLive(true)
        XCTAssertFalse(view.showsLivePicture, "no picture yet: the card")
    }

    func testAPictureShowsLiveAndSurvivesTheStreamStopping() {
        let view = StandInView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let s = surface(width: 40, height: 20, fill: 0x80)
        view.setSurface(s)
        view.setLive(true)
        XCTAssertTrue(view.showsLivePicture)

        view.freezePicture()
        // the stream reuses the surface for a later frame
        s.lock(options: [], seed: nil)
        memset(s.baseAddress, 0, s.allocationSize)
        s.unlock(options: [], seed: nil)

        XCTAssertTrue(view.hasPicture, "the copy stays after the stream stops")
        XCTAssertTrue(view.showsLivePicture)
    }

    func testFreezingWithNoPictureKeepsTheCard() {
        let view = StandInView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.freezePicture()
        view.setLive(true)
        XCTAssertFalse(view.hasPicture)
        XCTAssertFalse(view.showsLivePicture)
    }

    func testTheRepairsKnobReadsItsKey() {
        let defaults = UserDefaults(suiteName: "FloaterStandInViewTests")!
        defer { defaults.removePersistentDomain(forName: "FloaterStandInViewTests") }
        XCTAssertFalse(FloaterStandInMode.debugKeepsRepairs(defaults))
        defaults.set(true, forKey: FloaterStandInMode.debugKeepRepairsKey)
        #if DEBUG
        XCTAssertTrue(FloaterStandInMode.debugKeepsRepairs(defaults))
        #else
        XCTAssertFalse(FloaterStandInMode.debugKeepsRepairs(defaults))
        #endif
    }
}
