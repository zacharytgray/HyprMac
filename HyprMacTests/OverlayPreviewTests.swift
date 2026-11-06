import XCTest
@testable import HyprMac

final class OverlayPreviewTests: XCTestCase {
    // the debug preview's grid: keybinds and overview on top, five HUDs below
    func testFlowFitsTheOverlaysOnA1080pScreenWithoutOverlap() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1050)
        let sizes = [CGSize(width: 748, height: 690), CGSize(width: 1172, height: 690)]
            + Array(repeating: CGSize(width: 290, height: 220), count: 5)
        let frames = OverlayPreview.flow(sizes, in: bounds)
        XCTAssertEqual(frames.map(\.size), sizes)
        for (i, frame) in frames.enumerated() {
            XCTAssertTrue(bounds.contains(frame), "\(i) \(frame)")
            for other in frames[(i + 1)...] {
                XCTAssertFalse(frame.intersects(other), "\(frame) \(other)")
            }
        }
        XCTAssertEqual(frames[1].minX, frames[0].maxX)
        XCTAssertEqual(frames[2].maxY, frames[0].minY)
    }

    func testFlagsAreOffWithoutTheirArguments() {
        XCTAssertFalse(OverlayPreview.isRequested)
        XCTAssertFalse(OverlayPreview.forcesGlassFallback)
    }
}
