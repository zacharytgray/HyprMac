import Cocoa
import XCTest
@testable import HyprMac

final class TiledDragEventTests: XCTestCase {
    func testPointUsesSyntheticCGEventLocation() throws {
        let event = try makeEvent(type: .leftMouseDragged, point: CGPoint(x: 123, y: 456))

        XCTAssertEqual(TiledDragEvent.point(event: event, primaryHeight: 900),
                       CGPoint(x: 123, y: 456))
    }

    func testReleaseUsesMouseUpPointRatherThanMouseDownPoint() throws {
        let down = try makeEvent(type: .leftMouseDown, point: CGPoint(x: 10, y: 20))
        let up = try makeEvent(type: .leftMouseUp, point: CGPoint(x: 310, y: 420))

        XCTAssertEqual(TiledDragEvent.point(event: down, primaryHeight: 900),
                       CGPoint(x: 10, y: 20))
        XCTAssertEqual(TiledDragEvent.release(event: up, primaryHeight: 900,
                                              sawDragEvent: true).pointer,
                       CGPoint(x: 310, y: 420))
    }

    // only Hypr swaps on a drag. holding Option at release is a plain drop
    func testOptionDoesNotRequestSwapAtRelease() throws {
        let withOption = try makeEvent(type: .leftMouseUp, point: .zero, optionDown: true)

        XCTAssertFalse(TiledDragEvent.release(event: withOption, primaryHeight: 900,
                                              sawDragEvent: true).swapRequested)
    }

    func testSemanticSwapIntentDoesNotRequireAPlatformModifier() throws {
        let event = try makeEvent(type: .leftMouseUp, point: .zero)

        XCTAssertTrue(TiledDragEvent.release(event: event, primaryHeight: 900,
                                             sawDragEvent: true,
                                             swapRequested: true).swapRequested)
    }

    func testReleasePreservesWhetherDragEventWasObserved() throws {
        let event = try makeEvent(type: .leftMouseUp, point: .zero)

        XCTAssertFalse(TiledDragEvent.release(event: event, primaryHeight: 900,
                                              sawDragEvent: false).sawDragEvent)
        XCTAssertTrue(TiledDragEvent.release(event: event, primaryHeight: 900,
                                             sawDragEvent: true).sawDragEvent)
    }

    func testJitterUnderThresholdIsNotADrag() {
        XCTAssertFalse(TiledDragEvent.isDrag(from: CGPoint(x: 100, y: 100),
                                             to: CGPoint(x: 103, y: 100),
                                             sawDragEvent: true))
    }

    func testTravelBeyondThresholdIsADrag() {
        XCTAssertTrue(TiledDragEvent.isDrag(from: CGPoint(x: 100, y: 100),
                                            to: CGPoint(x: 100, y: 112),
                                            sawDragEvent: true))
    }

    func testMissingPressPointFallsBackToTheDragEventFlag() {
        XCTAssertTrue(TiledDragEvent.isDrag(from: nil, to: CGPoint(x: 500, y: 500),
                                            sawDragEvent: true))
        XCTAssertFalse(TiledDragEvent.isDrag(from: nil, to: CGPoint(x: 500, y: 500),
                                             sawDragEvent: false))
    }

    func testTravelWithoutADragEventIsNeverADrag() {
        XCTAssertFalse(TiledDragEvent.isDrag(from: CGPoint(x: 100, y: 100),
                                             to: CGPoint(x: 130, y: 100),
                                             sawDragEvent: false))
    }

    func testTravelExactlyAtTheThresholdIsADrag() {
        XCTAssertEqual(TilingConfig.dragThresholdPx, 8)
        XCTAssertTrue(TiledDragEvent.isDrag(from: CGPoint(x: 100, y: 100),
                                            to: CGPoint(x: 108, y: 100),
                                            sawDragEvent: true))
    }

    private func makeEvent(type: CGEventType, point: CGPoint,
                           optionDown: Bool = false) throws -> NSEvent {
        let mouseType: CGMouseButton = .left
        let cgEvent = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type,
                                           mouseCursorPosition: point, mouseButton: mouseType))
        if optionDown { cgEvent.flags = .maskAlternate }
        return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
    }
}
