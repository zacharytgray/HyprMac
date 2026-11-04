// Two-tier logger built on `os.Logger`. Trace tier
// (`.debug`/`.info`) is developer-only and gated by build
// configuration plus a per-category filter. Diagnostic tier
// (`.notice`/`.warning`/`.error`/`.fault`) always emits so users can
// grab them in Console for bug reports.

import Foundation
import os

/// Severity for `hyprLog`. Maps onto `os.Logger`'s methods.
enum LogLevel: Int, Comparable {
    case debug = 0, info, notice, warning, error, fault
    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }

    /// Stable name used in the debug log file's `[level]` field.
    var label: String {
        switch self {
        case .debug:   return "debug"
        case .info:    return "info"
        case .notice:  return "notice"
        case .warning: return "warning"
        case .error:   return "error"
        case .fault:   return "fault"
        }
    }
}

/// Routing category for `hyprLog`. Each maps to an `os.Logger`
/// instance, enabling Console filters per category.
enum LogCategory: String, CaseIterable {
    case orchestration, state, focus, tiling, workspace, discovery
    case input, mouse, drag, hotkey, floating
    case ui, animator, border, dimming, overlay
    case config, persistence, migration, sync
    case lifecycle, accessibility, space, display
}

private let subsystem = Bundle.main.bundleIdentifier ?? "com.zachgray.HyprMac"

private let loggers: [LogCategory: Logger] = Dictionary(
    uniqueKeysWithValues: LogCategory.allCases.map {
        ($0, Logger(subsystem: subsystem, category: $0.rawValue))
    }
)

/// Runtime knobs for the logger.
///
/// `traceMinimum` is the lowest `.debug`/`.info` level honored in DEBUG;
/// `enabledCategories` filters trace output by category;
/// `verboseInRelease` reads the `HyprMacVerboseLogging` `UserDefault`
/// so a user can flip on trace logging in a Release build for a
/// support session via:
/// `defaults write com.zachgray.HyprMac HyprMacVerboseLogging -bool YES`.
enum LogConfig {
    static var traceMinimum: LogLevel = .debug
    static var enabledCategories: Set<LogCategory> = Set(LogCategory.allCases)

    static var verboseInRelease: Bool {
        UserDefaults.standard.bool(forKey: "HyprMacVerboseLogging")
    }

    /// Frame reads around every setter for the `frame write trace:` line.
    /// They cost AX round trips inside the write deadline, so they are
    /// opt-in in every build:
    /// `defaults write <bundle id> HyprMacFrameWriteTrace -bool YES`.
    static let frameWriteTraceKey = "HyprMacFrameWriteTrace"
    static var frameWriteTrace: Bool {
        UserDefaults.standard.bool(forKey: frameWriteTraceKey)
    }

    /// Mirror every `hyprLog` call into `DebugLogFile`, at every level
    /// and category, ignoring the trace-tier gating above. On by default
    /// in DEBUG because os_log discards `.debug` before it persists, so
    /// the file is the only evidence left after a bug. In Release it
    /// follows the same `HyprMacVerboseLogging` toggle as trace output.
    #if DEBUG
    static var persistentFileLog = true
    #else
    static var persistentFileLog: Bool { verboseInRelease }
    #endif
}

/// Emit a log line.
///
/// `.notice` and above always emit through `os.Logger` and are
/// visible in Console under `subsystem == "com.zachgray.HyprMac"`.
/// `.debug`/`.info` are gated by `LogConfig` in DEBUG and by
/// `verboseInRelease` in Release.
///
/// Independently of all that, every call is appended to
/// `DebugLogFile` while `LogConfig.persistentFileLog` is on.
///
/// `privacy: .public` is applied across the board, so nothing is redacted.
/// Most lines carry only window IDs, workspace numbers, screen names, action
/// names and durations. Some lines also carry window titles. Command
/// text must not enter log strings.
func hyprLog(_ level: LogLevel = .debug,
             _ category: LogCategory,
             _ message: @autoclosure () -> String) {
    // file log takes every line regardless of tier or category — it is
    // the only copy of the trace tier that outlives the process.
    var rendered: String?
    if LogConfig.persistentFileLog {
        let m = message()
        rendered = m
        DebugLogFile.shared.append(level: level, category: category, message: m)
    }

    // diagnostic tier — always emits, visible in Console.app for support.
    if level >= .notice {
        let m = rendered ?? message()
        let logger = loggers[category]!
        switch level {
        case .notice:  logger.notice("\(m, privacy: .public)")
        case .warning: logger.warning("\(m, privacy: .public)")
        case .error:   logger.error("\(m, privacy: .public)")
        case .fault:   logger.fault("\(m, privacy: .public)")
        default:       break
        }
        return
    }
    // trace tier — gated by build configuration and category filter.
    #if DEBUG
    let allowed = level >= LogConfig.traceMinimum && LogConfig.enabledCategories.contains(category)
    if allowed {
        let m = rendered ?? message()
        loggers[category]!.debug("\(m, privacy: .public)")
    }
    #else
    if LogConfig.verboseInRelease && LogConfig.enabledCategories.contains(category) {
        let m = rendered ?? message()
        loggers[category]!.debug("\(m, privacy: .public)")
    }
    #endif
}
