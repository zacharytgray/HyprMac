import Cocoa
import XCTest
@testable import HyprMac

// an app can re-create a window's AX element and keep the window id: ordering
// the window out and straight back in does it. the old element answers
// -25202 (invalid element) from then on, and every HyprWindow built on it is
// dead. live behavior isn't checked here.

final class StaleWindowElementTests: XCTestCase {

    /// frames by id. only a window object on a live element reads or writes them
    private final class App {
        var frames: [CGWindowID: CGRect] = [:]
        private var dead: [AXUIElement] = []
        private var nextElement: pid_t = 5000
        private var now: TimeInterval = 0

        /// a window object on a brand new element
        func window(_ id: CGWindowID) -> HyprWindow {
            nextElement += 1
            return HyprWindow(element: AXUIElementCreateApplication(nextElement), windowID: id, ownerPID: 100)
        }

        /// what a later walk hands back for a window that kept its element
        func walked(_ window: HyprWindow) -> HyprWindow {
            HyprWindow(element: window.element, windowID: window.windowID, ownerPID: window.ownerPID)
        }

        /// the app re-creates the element. the id stays
        func recreated(_ window: HyprWindow) -> HyprWindow {
            dead.append(window.element)
            return self.window(window.windowID)
        }

        func isLive(_ window: HyprWindow?) -> Bool {
            guard let window else { return false }
            return !dead.contains { CFEqual($0, window.element) }
        }

        func io(_ windows: [CGWindowID: HyprWindow], _ generation: @escaping () -> UInt64) -> FrameSizingIO {
            FrameSizingIO(
                setMessagingTimeout: { _, _ in .success },
                writeSize: { [self] id, size, _ in
                    guard isLive(windows[id]) else { return .invalidUIElement }
                    frames[id, default: .zero].size = size
                    return .success
                },
                writePosition: { [self] id, position, _ in
                    guard isLive(windows[id]) else { return .invalidUIElement }
                    frames[id, default: .zero].origin = position
                    return .success
                },
                readPosition: { [self] id, _ in
                    isLive(windows[id]) ? (.success, frames[id]?.origin ?? .zero) : (.invalidUIElement, nil)
                },
                readSize: { [self] id, _ in
                    isLive(windows[id]) ? (.success, frames[id]?.size ?? CGSize(width: 100, height: 100))
                        : (.invalidUIElement, nil)
                },
                now: { [self] in now }, sleep: { [self] in now += $0 },
                currentGeneration: generation)
        }
    }

    private final class Screen: SyntheticScreen {
        override var frame: NSRect { NSRect(x: 0, y: 0, width: 1600, height: 1000) }
        override var visibleFrame: NSRect { frame }
    }

    private let app = App()
    private let screen = Screen()
    private lazy var engine = TilingEngine(
        displayManager: DisplayManager(screenSource: { [screen] in [screen] }),
        frameSizingIOFactory: { [app] windows, generation in app.io(windows, generation) })

    /// two tiles, then the app re-creates 11's element
    private func tileThenRecreate() -> (walk: [HyprWindow], old: HyprWindow) {
        let a = app.window(11), b = app.window(13)
        XCTAssertNil(engine.tileWindows([a, b], onWorkspace: 1, screen: screen).failure)
        return ([app.recreated(a), app.walked(b)], a)
    }

    private func leaf(_ id: CGWindowID) -> HyprWindow? {
        engine.existingTree(forWorkspace: 1, screen: screen)?.allWindows.first { $0.windowID == id }
    }

    /// the tree kept the object from the first pass, on the dead element.
    /// every later layout of that workspace failed until the window left it
    func testAPassHandedTheNewElementLaysTheWindowOut() {
        let (walk, _) = tileThenRecreate()
        // moved since, so the pass has to write
        app.frames[11]?.origin.x += 40

        let result = engine.tileWindows(walk, onWorkspace: 1, screen: screen)

        XCTAssertNil(result.failure)
        XCTAssertTrue(leaf(11) === walk[0], "the tree now holds the object on the live element")
    }

    /// a tiled drag reads every tile through the tree. one dead element
    /// refused every drag on the workspace, with the red shake
    func testADragIsCapturedOnceThePollAdoptsTheNewElement() {
        let (walk, _) = tileThenRecreate()
        let stale = engine.captureTiledDrag(draggedID: 13, workspace: 1, screen: screen, floatingIDs: [])
        guard case .unknown(.windowUnavailable(11)) = stale else {
            return XCTFail("the dead element should still fail the capture here, got \(stale)")
        }

        XCTAssertEqual(engine.adoptRecreatedWindows(from: walk), [11])

        let live = engine.captureTiledDrag(draggedID: 13, workspace: 1, screen: screen, floatingIDs: [])
        guard case .captured = live else {
            return XCTFail("the capture should read 11 through its new element, got \(live)")
        }
    }

    func testAdoptingKeepsTheTreeAndWhatWasStampedOnTheOldObject() {
        let (walk, old) = tileThenRecreate()
        let before = engine.existingTree(forWorkspace: 1, screen: screen)?.allWindows.map(\.windowID)
        old.observedMinSize = CGSize(width: 640, height: 480)
        old.minSizeProvenance = .observed

        engine.adoptRecreatedWindows(from: walk)

        XCTAssertEqual(engine.existingTree(forWorkspace: 1, screen: screen)?.allWindows.map(\.windowID), before)
        XCTAssertTrue(leaf(11) === walk[0])
        XCTAssertEqual(leaf(11)?.observedMinSize, CGSize(width: 640, height: 480))
        XCTAssertEqual(leaf(11)?.minSizeProvenance, .observed)
    }

    func testAWindowThatKeptItsElementKeepsItsObject() {
        let a = app.window(11), b = app.window(13)
        XCTAssertNil(engine.tileWindows([a, b], onWorkspace: 1, screen: screen).failure)

        XCTAssertEqual(engine.adoptRecreatedWindows(from: [app.walked(a), app.walked(b)]), [])

        XCTAssertTrue(leaf(11) === a)
        XCTAssertTrue(leaf(13) === b)
    }

    /// a window id handed to another app is a different window, not a
    /// re-created element. discovery deals with that one
    func testAnotherAppsWindowUnderTheSameIDIsNotAdopted() {
        let a = app.window(11)
        let other = HyprWindow(element: AXUIElementCreateApplication(7001), windowID: 11, ownerPID: 200)

        XCTAssertFalse(a.wasRecreated(as: other))
        XCTAssertFalse(a.wasRecreated(as: a))
        XCTAssertFalse(a.wasRecreated(as: app.walked(a)))
        XCTAssertTrue(a.wasRecreated(as: app.recreated(a)))
    }

    /// hover focus and its synthetic click go through `cachedWindows`
    func testTheWindowCacheSwapsInTheNewElement() {
        let cache = WindowStateCache()
        let a = app.window(11), b = app.window(13)
        a.isFloating = true
        cache.cachedWindows = [11: a, 13: b]
        let a2 = app.recreated(a), c = app.window(17)

        XCTAssertEqual(cache.adoptRecreatedWindows(from: [a2, app.walked(b), c]), [11])

        XCTAssertTrue(cache.cachedWindows[11] === a2)
        XCTAssertTrue(a2.isFloating, "the floating stamp carries over")
        XCTAssertTrue(cache.cachedWindows[13] === b, "same element, same object")
        XCTAssertNil(cache.cachedWindows[17], "a window the cache did not hold is not added")
    }
}
