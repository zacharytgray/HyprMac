import Foundation

// main-thread precondition for UI / AX / CGEvent code.
//
// HyprMac's policy (§5.3 of REFACTOR_PLAN): every UI-touching public method
// runs on the main thread. nothing in the codebase asserts this today; if a
// background queue ever calls into FocusBorder, DimmingOverlay, etc. the
// failure mode is silent corruption (NSPanel mutation off-main, stale
// CALayer state). this assertion turns that into a loud crash in DEBUG.
//
// release builds skip the check — preconditionFailure has cost, and the
// invariant is enforced via test coverage in DEBUG.
@inlinable
func mainThreadOnly(_ file: StaticString = #fileID, _ line: UInt = #line) {
    #if DEBUG
    precondition(Thread.isMainThread, "must be called on main thread", file: file, line: line)
    #endif
}
