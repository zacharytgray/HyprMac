// Main-thread precondition for UI, AX, and CGEvent code. Crashes
// loudly in DEBUG when called off-main; no-op in Release.

import Foundation

/// Main-thread precondition.
///
/// Every UI-touching public method runs on the main thread. Without
/// this assertion, an off-main caller fails silently (NSPanel
/// mutation, stale CALayer state) — this turns those into a loud
/// crash in DEBUG. Release skips the check entirely so there is no
/// runtime cost in shipping builds.
@inlinable
func mainThreadOnly(_ file: StaticString = #fileID, _ line: UInt = #line) {
    #if DEBUG
    precondition(Thread.isMainThread, "must be called on main thread", file: file, line: line)
    #endif
}
