import Foundation
import os

// two-tier logger.
// trace tier (.debug/.info): developer-only, gated by build config + category filter.
//   in DEBUG, emits when level >= LogConfig.traceMinimum and category is enabled.
//   in RELEASE, emits only when HyprMacVerboseLogging UserDefault is true (for support sessions).
// diagnostic tier (.notice/.warning/.error/.fault): always emits via os.Logger.
//   visible in Console.app under subsystem com.zachgray.HyprMac so users can grab them for bug reports.
//
// privacy: .public is applied only to safe metadata (window IDs, workspace numbers, screen names,
// action names, durations). free-text user input must not enter log strings.

enum LogLevel: Int, Comparable {
    case debug = 0, info, notice, warning, error, fault
    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
}

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

enum LogConfig {
    // trace-tier ceiling. .debug/.info are gated by this in DEBUG.
    static var traceMinimum: LogLevel = .debug
    // categories enabled for trace logging. empty == all.
    static var enabledCategories: Set<LogCategory> = Set(LogCategory.allCases)

    // release-build escape hatch — set via:
    //   defaults write com.zachgray.HyprMac HyprMacVerboseLogging -bool YES
    static var verboseInRelease: Bool {
        UserDefaults.standard.bool(forKey: "HyprMacVerboseLogging")
    }
}

func hyprLog(_ level: LogLevel = .debug,
             _ category: LogCategory,
             _ message: @autoclosure () -> String) {
    // diagnostic tier — always emits, visible in Console.app for support.
    if level >= .notice {
        let m = message()
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
        let m = message()
        loggers[category]!.debug("\(m, privacy: .public)")
    }
    #else
    if LogConfig.verboseInRelease && LogConfig.enabledCategories.contains(category) {
        let m = message()
        loggers[category]!.debug("\(m, privacy: .public)")
    }
    #endif
}
