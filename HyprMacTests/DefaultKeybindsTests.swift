import XCTest
@testable import HyprMac

// DefaultKeybindsTests verify the shipped default keybind table.
// these are cheap structural invariants — we don't simulate hotkey
// dispatch, just confirm the table is internally consistent.

final class DefaultKeybindsTests: XCTestCase {

    func testEveryDefaultRoundTripsThroughCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for kb in Keybind.defaults {
            let data = try encoder.encode(kb)
            let decoded = try decoder.decode(Keybind.self, from: data)
            XCTAssertEqual(decoded.action, kb.action,
                           "default keybind action did not round-trip: \(kb)")
            XCTAssertEqual(decoded.keyCode, kb.keyCode)
            XCTAssertEqual(decoded.modifiers, kb.modifiers)
        }
    }

    func testEveryDefaultUsesUniqueChord() {
        var seen: Set<String> = []
        for kb in Keybind.defaults {
            let chord = "\(kb.modifiers.rawValue)-\(kb.keyCode)"
            XCTAssertFalse(seen.contains(chord),
                           "duplicate default chord \(chord) on action \(kb.action)")
            seen.insert(chord)
        }
    }

    func testDefaultsCoverEachWorkspaceNumber() {
        // Hypr+1..9 → switchWorkspace(N), Hypr+Shift+1..9 → moveToWorkspace(N).
        var switchN: Set<Int> = []
        var moveN: Set<Int> = []
        for kb in Keybind.defaults {
            switch kb.action {
            case .switchWorkspace(let n): switchN.insert(n)
            case .moveToWorkspace(let n): moveN.insert(n)
            default: break
            }
        }
        XCTAssertEqual(switchN, Set(1...9))
        XCTAssertEqual(moveN, Set(1...9))
    }

    func testDefaultsContainAllDirectionsForFocusAndSwap() {
        var focusDirs: Set<Direction> = []
        var swapDirs: Set<Direction> = []
        for kb in Keybind.defaults {
            switch kb.action {
            case .focusDirection(let d): focusDirs.insert(d)
            case .swapDirection(let d): swapDirs.insert(d)
            default: break
            }
        }
        XCTAssertEqual(focusDirs, Set([.left, .right, .up, .down]))
        XCTAssertEqual(swapDirs, Set([.left, .right, .up, .down]))
    }

    func testDefaultsAreNonEmpty() {
        XCTAssertFalse(Keybind.defaults.isEmpty)
    }
}
