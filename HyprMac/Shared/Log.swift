import Foundation

// lightweight logger — @autoclosure skips string interpolation entirely
// when logging is disabled. in release builds this compiles to nothing.
#if DEBUG
var hyprLogEnabled = true

func hyprLog(_ message: @autoclosure () -> String) {
    if hyprLogEnabled {
        print("[HyprMac] \(message())")
    }
}
#else
@inlinable func hyprLog(_ message: @autoclosure () -> String) {}
#endif
