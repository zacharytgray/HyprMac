// What the menu bar says about a pending update, when a downloaded update
// may install on its own, and how the updater's windows stay above the
// tiles. No Sparkle here, so the debug variant and the tests build it.

import Cocoa

/// An update the menu bar should point at.
enum UpdateNotice: Equatable {
    /// a scheduled check found it; the update window waits for a click
    case available(version: String)
    /// downloaded. installs on quit, on a click, or once the Mac is idle
    case ready(version: String)

    var version: String {
        switch self {
        case .available(let version), .ready(let version): return version
        }
    }
}

/// Bridge between the updater and the menu bar views, like `MenuBarState`.
final class UpdateState: ObservableObject {
    static let shared = UpdateState()
    @Published var notice: UpdateNotice?
}

// MARK: - idle install

/// What the Mac is doing, as far as an unattended relaunch cares.
struct IdleInstallConditions: Equatable {
    /// seconds since the last key, click, scroll or pointer move
    var idleSeconds: TimeInterval
    /// locked, at the login window, or switched to another user
    var screenLocked: Bool
    var displayAsleep: Bool
    var fullscreenInFront: Bool
}

/// Decides when a downloaded update may relaunch HyprMac with nobody watching.
///
/// Idle means no keyboard or pointer input for five minutes. A keep-awake
/// tool does not count as someone watching, so display-sleep assertions are
/// not read: they would hold updates back for everyone who runs one.
///
/// The relaunch must run before the display sleeps or the screen locks:
/// behind either one AX lists only part of the desk, and a launch would
/// lay out what it could see. macOS turns the display off after ten
/// minutes on power by default, which is why the wait is five.
enum IdleInstallPolicy {
    static let idleThreshold: TimeInterval = 5 * 60
    /// `defaults write` this many seconds to test with a shorter wait
    static let thresholdDefaultsKey = "updateIdleInstallSeconds"

    enum Wait: String, Equatable, CaseIterable {
        case inUse = "the Mac is in use"
        case locked = "the screen is locked"
        case displayAsleep = "the display is asleep"
        case fullscreen = "a fullscreen app is in front"
    }

    /// `nil` means install now.
    static func wait(_ conditions: IdleInstallConditions,
                     threshold: TimeInterval = idleThreshold) -> Wait? {
        if conditions.screenLocked { return .locked }
        if conditions.displayAsleep { return .displayAsleep }
        if conditions.fullscreenInFront { return .fullscreen }
        if conditions.idleSeconds < threshold { return .inUse }
        return nil
    }

    static func threshold(defaults: UserDefaults = .standard) -> TimeInterval {
        let override = defaults.double(forKey: thresholdDefaultsKey)
        return override > 0 ? override : idleThreshold
    }
}

extension IdleInstallConditions {
    /// Read the live values. `fullscreenInFront` comes from the window
    /// manager, which already asks AX about the front window.
    static func current(fullscreenInFront: Bool) -> IdleInstallConditions {
        // hardware events only, so HyprMac's own warps and clicks don't count
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        let locked = (session["CGSSessionScreenIsLocked"] as? Bool ?? false)
            || !(session[kCGSessionOnConsoleKey as String] as? Bool ?? true)
        return IdleInstallConditions(
            idleSeconds: idle,
            screenLocked: locked,
            displayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0,
            fullscreenInFront: fullscreenInFront)
    }
}

// MARK: - updater windows

/// Keeps the updater's windows (update available, release notes, download
/// progress, relaunch prompt) above the tiles.
///
/// They get the level Settings and the overlays use. That level is above
/// every tile and floater, and it is outside the layers discovery reads,
/// so the tiler never sees them. A scheduled check shows its window
/// without making HyprMac active, so the window is also ordered front by
/// hand; left alone it opens behind the focused tile.
enum UpdateWindows {
    static let sparkleBundleID = "org.sparkle-project.Sparkle"

    /// Whether the updater owns `window`: its controller, delegate or own
    /// class comes from the Sparkle framework.
    static func isUpdateWindow(_ window: NSWindow,
                               bundleID: (AnyClass) -> String? = { Bundle(for: $0).bundleIdentifier }) -> Bool {
        let owners: [AnyObject?] = [window.windowController, window.delegate, window]
        return owners.contains { owner in
            owner.map { bundleID(type(of: $0)) == sparkleBundleID } ?? false
        }
    }

    /// Lift one window to the interface level. A window already above it
    /// (a modal alert) keeps its level.
    static func float(_ window: NSWindow, bringForward: Bool) {
        if window.level.rawValue < Constants.interfaceWindowLevel.rawValue {
            window.level = Constants.interfaceWindowLevel
        }
        if bringForward && window.isVisible {
            window.orderFrontRegardless()
        }
    }

    /// Lift every updater window in `windows`.
    /// - Returns: how many were found.
    @discardableResult
    static func floatAll(in windows: [NSWindow], bringForward: Bool,
                         bundleID: (AnyClass) -> String? = { Bundle(for: $0).bundleIdentifier }) -> Int {
        let ours = windows.filter { isUpdateWindow($0, bundleID: bundleID) }
        ours.forEach { float($0, bringForward: bringForward) }
        return ours.count
    }
}
