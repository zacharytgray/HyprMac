import XCTest
import Cocoa
@testable import HyprMac

// the declared-vs-enforced verdict behind the measurement logs. the
// declared limits feed nothing else, so the verdict is all there is to pin

final class DeclaredSizeLimitsTests: XCTestCase {

    private func limits(min: CGSize) -> DeclaredSizeLimits {
        DeclaredSizeLimits(min: min, max: CGSize(width: 100_000, height: 100_000), preferred: .zero)
    }

    private func verdict(_ declared: DeclaredSizeLimits?, enforced: CGSize,
                         width: Bool = false, height: Bool = false) -> DeclaredSizeLimits.Verdict {
        DeclaredSizeLimits.verdict(declared: declared, enforced: enforced,
                                   widthRefused: width, heightRefused: height)
    }

    func testAMatchingFloorWithinAPointIsAMatch() {
        // Teams declared and enforced 414x414
        XCTAssertEqual(verdict(limits(min: CGSize(width: 414, height: 414)),
                               enforced: CGSize(width: 414, height: 414), height: true), .match)
        XCTAssertEqual(verdict(limits(min: CGSize(width: 600.5, height: 0)),
                               enforced: CGSize(width: 600, height: 835), width: true), .match)
    }

    func testADeclaredFloorAboveTheEnforcedOneIsDeclaredHigh() {
        // Fantastical declared 838 wide and took 541
        XCTAssertEqual(verdict(limits(min: CGSize(width: 838, height: 480)),
                               enforced: CGSize(width: 541, height: 835), width: true), .declaredHigh)
    }

    func testADeclaredFloorBelowTheEnforcedOneIsDeclaredLow() {
        XCTAssertEqual(verdict(limits(min: CGSize(width: 300, height: 200)),
                               enforced: CGSize(width: 744, height: 400), height: true), .declaredLow)
    }

    func testNoDeclaredFloorOnTheRefusedAxisIsUndeclared() {
        for floor in [CGSize.zero, CGSize(width: 1, height: 1)] {
            XCTAssertEqual(verdict(limits(min: floor), enforced: CGSize(width: 600, height: 400), width: true),
                           .undeclared)
        }
        // a non-resizable window reads all zeros
        XCTAssertEqual(verdict(DeclaredSizeLimits(min: .zero, max: .zero, preferred: .zero),
                               enforced: CGSize(width: 600, height: 400), height: true), .undeclared)
    }

    func testOnlyTheRefusedAxisCounts() {
        // the width is far off, but only the height was refused
        XCTAssertEqual(verdict(limits(min: CGSize(width: 900, height: 480)),
                               enforced: CGSize(width: 541, height: 480), height: true), .match)
    }

    func testDeclaredHighWinsAcrossTwoRefusedAxes() {
        XCTAssertEqual(verdict(limits(min: CGSize(width: 900, height: 300)),
                               enforced: CGSize(width: 541, height: 480), width: true, height: true),
                       .declaredHigh)
        XCTAssertEqual(verdict(limits(min: CGSize(width: 0, height: 300)),
                               enforced: CGSize(width: 541, height: 480), width: true, height: true),
                       .declaredLow)
    }

    func testNoAxisNamedComparesBoth() {
        XCTAssertEqual(verdict(limits(min: CGSize(width: 541, height: 600)),
                               enforced: CGSize(width: 541, height: 480)), .declaredHigh)
    }

    func testNothingReadIsUnreadable() {
        XCTAssertEqual(verdict(nil, enforced: CGSize(width: 541, height: 480), width: true), .unreadable)
    }

    func testANonexistentWindowReadsNil() {
        XCTAssertNil(DeclaredSizeLimits.read(CGWindowID.max - 7))
    }

    func testTheLogTextNamesEveryLimit() {
        let declared = DeclaredSizeLimits(min: CGSize(width: 414, height: 414),
                                          max: CGSize(width: CGFloat.infinity, height: 100_000),
                                          preferred: CGSize(width: 1040, height: 835))
        XCTAssertEqual(declared.logText, "min=414x414 max=infx100000 pref=1040x835")
    }

    func testAReadIsEmptyUntilEitherAxisDeclaresAMinimum() {
        XCTAssertTrue(DeclaredSizeLimits.isEmpty(nil))
        XCTAssertTrue(DeclaredSizeLimits.isEmpty(DeclaredSizeLimits(min: .zero, max: .zero, preferred: .zero)))
        XCTAssertTrue(DeclaredSizeLimits.isEmpty(limits(min: CGSize(width: 1, height: 1))))
        XCTAssertFalse(DeclaredSizeLimits.isEmpty(limits(min: CGSize(width: 0, height: 320))))
        XCTAssertFalse(DeclaredSizeLimits.isEmpty(limits(min: CGSize(width: 637, height: 320))))
    }

    // the fake window id reads nil, so every re-read stays empty
    private func watch(_ engine: TilingEngine, readAtAssign: DeclaredSizeLimits?) -> () -> [TimeInterval] {
        var waits: [TimeInterval] = []
        var pending: [() -> Void] = []
        engine.scheduleDeclaredLimitsRead = { wait, body in
            waits.append(wait)
            pending.append(body)
        }
        engine.watchDeclaredLimits(makeWindow(id: CGWindowID.max - 7), readAtAssign: readAtAssign)
        return {
            while !pending.isEmpty { pending.removeFirst()() }
            return waits
        }
    }

    func testAnEmptyAssignReadIsTriedAgainOnTheSchedule() {
        let engine = TilingEngine(displayManager: DisplayManager(screenSource: { [] }))
        let waits = watch(engine, readAtAssign: nil)()
        let ms = waits.reduce(into: [Int]()) { out, wait in
            out.append((out.last ?? 0) + Int((wait * 1000).rounded()))
        }
        XCTAssertEqual(ms, TilingEngine.declaredLimitsRereadMilliseconds)
        XCTAssertEqual(ms, [50, 100, 200, 400, 800, 1600, 3200, 6400])
    }

    func testADeclaredAssignReadIsNotTriedAgain() {
        let engine = TilingEngine(displayManager: DisplayManager(screenSource: { [] }))
        let waits = watch(engine, readAtAssign: limits(min: CGSize(width: 637, height: 320)))()
        XCTAssertEqual(waits, [])
    }

    func testAForgottenWindowStopsTheReReads() {
        let engine = TilingEngine(displayManager: DisplayManager(screenSource: { [] }))
        let drain = watch(engine, readAtAssign: nil)
        engine.forgetMinimumSize(windowID: CGWindowID.max - 7)
        XCTAssertEqual(drain().count, 1, "the first read was already scheduled; it finds the window gone")
    }
}
