// One running copy of HyprMac per bundle id. The copy that holds the lock
// file runs; any other copy quits before it starts anything.

import Foundation

/// Keeps a second copy of HyprMac from running beside the first.
///
/// macOS only folds a second launch into the running app when it goes
/// through LaunchServices and names the same bundle path. A launchd agent
/// that runs the binary directly, a copy at another path, and `open -n`
/// all start a second process, and `LSMultipleInstancesProhibited` does
/// not stop them. Two copies then run two event taps and two tiling
/// engines over the same windows, and the first to quit takes the Hypr key
/// remap away from the other.
///
/// So each copy takes an exclusive `flock` on a file named for its bundle
/// id. The kernel gives the lock to exactly one process, which settles two
/// copies starting at the same moment, and frees it when that process
/// ends, a crash included, so there is never a stale lock to clear.
enum SingleInstance {
    enum Claim: Equatable {
        /// This copy runs. The descriptor stays open for the life of the process.
        case held(descriptor: Int32)
        /// Another copy holds the lock.
        case taken
        /// The lock file can't be used, so this copy runs unguarded.
        case unavailable
    }

    /// How long a new copy waits for the old one to finish quitting.
    /// Sparkle starts the new version only after the old process is gone,
    /// so this covers a quit that is still running when the next launch
    /// arrives, such as a quit followed at once by a reopen.
    static let quitGrace: TimeInterval = 3
    static let pollInterval: TimeInterval = 0.1

    // the lock lives as long as this descriptor is open
    private static var heldDescriptor: Int32 = -1

    #if DEBUG
    static let isDebugBuild = true
    #else
    static let isDebugBuild = false
    #endif

    /// Called first thing at launch. Returns in the copy that runs. A
    /// second copy exits here with code 0, which a launchd agent with
    /// `KeepAlive = { SuccessfulExit = false; }` does not restart.
    static func claimOrExit(arguments: [String] = CommandLine.arguments,
                            environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard guards(arguments: arguments, environment: environment) else { return }
        let bundleID = Bundle.main.bundleIdentifier ?? RuntimeVariant.releaseBundleIdentifier
        let url = lockURL(bundleID: bundleID, directory: ConfigStore.configDir)
        switch claim(at: url) {
        case let .held(descriptor):
            heldDescriptor = descriptor
        case .taken:
            hyprLog(.notice, .lifecycle, "another copy of HyprMac is running; this one is quitting")
            exit(0)
        case .unavailable:
            hyprLog(.notice, .lifecycle, "single-instance lock unavailable at \(url.path); running without it")
        }
    }

    /// False for launches that are not the window manager and must be free
    /// to run beside it: an XCTest host, and the one-shot diagnostic flags.
    static func guards(arguments: [String], environment: [String: String],
                       debugApp: Bool = RuntimeVariant.isDebugApp,
                       debugBuild: Bool = isDebugBuild) -> Bool {
        if environment.keys.contains(where: { $0.hasPrefix("XCTest") }) { return false }
        return !isOneShotDiagnostic(arguments, debugApp: debugApp, debugBuild: debugBuild)
    }

    /// The flags `AppDelegate.applicationDidFinishLaunching` answers and
    /// then quits on, without starting the window manager. Each exists
    /// only in the builds named here; elsewhere it is an ordinary launch.
    /// A new diagnostic flag belongs in this list too.
    static func isOneShotDiagnostic(_ arguments: [String], debugApp: Bool, debugBuild: Bool) -> Bool {
        var flags: Set<String> = []
        if debugApp {
            flags.formUnion(["--request-accessibility", "--check-accessibility", "--check-input-monitoring"])
        }
        if debugBuild {
            flags.formUnion(["--preview-overlays", "--probe-frame"])
        }
        return arguments.contains(where: flags.contains)
    }

    /// One file per bundle id, so the Debug app and the release, which
    /// share this folder, never shut each other out.
    static func lockURL(bundleID: String, directory: URL) -> URL {
        directory.appendingPathComponent("instance-\(bundleID).lock")
    }

    /// Tries for the lock, then keeps trying every `interval` until
    /// `grace` has passed. `pause` is the wait between tries.
    static func claim(at url: URL,
                      grace: TimeInterval = quitGrace,
                      interval: TimeInterval = pollInterval,
                      pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> Claim {
        var waited: TimeInterval = 0
        while true {
            let attempt = tryClaim(at: url)
            guard attempt == .taken, interval > 0, waited + interval <= grace else { return attempt }
            pause(interval)
            waited += interval
        }
    }

    /// One try, no waiting.
    static func tryClaim(at url: URL) -> Claim {
        // close-on-exec, so a command HyprMac starts can't inherit the
        // lock and hold it after HyprMac is gone
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return .unavailable }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return .held(descriptor: descriptor) }
        let taken = errno == EWOULDBLOCK
        close(descriptor)
        return taken ? .taken : .unavailable
    }

    /// Gives the lock back. Only tests need this; the app keeps its lock
    /// until the process ends.
    static func release(_ claim: Claim) {
        if case let .held(descriptor) = claim { close(descriptor) }
    }
}
