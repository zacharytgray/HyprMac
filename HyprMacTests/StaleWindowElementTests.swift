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
        displayManager: DisplayManager(),
        frameSizingIOFactory: { [app] windows, generation in app.io(windows, generation) })

    /// two tiles, then the app re-creates 11's element
    private func tileThenRecreate() -> (walk: [HyprWindow], old: HyprWindow) {
        let a = app.window(11), b = app.window(13)
        XCTAssertNil(engine.tileWindows([a, b], onWorkspace: 1, screen: screen).failure)
        return ([app.recreated(a), app.walked(b)], a)
    }

    /// the tree kept the object from the first pass, on the dead element.
    /// every later layout of that workspace failed until the window left it
    func testAPassHandedTheNewElementLaysTheWindowOut() {
        let (walk, _) = tileThenRecreate()
        // moved since, so the pass has to write
        app.frames[11]?.origin.x += 40

        let result = engine.tileWindows(walk, onWorkspace: 1, screen: screen)

        XCTExpectFailure("the pass writes through the tree's object, which is on the dead element")
        XCTAssertNil(result.failure)
    }
}
