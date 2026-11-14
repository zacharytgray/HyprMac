// Secure Event Input detection. While any process holds secure input
// (a focused password field, a password manager overlay, a terminal's
// Secure Keyboard Entry, a leaked holder), macOS withholds key events
// from HyprMac's event tap, so every Hypr chord silently does nothing.
// HyprMac can't get around that; it notices, resets the Hypr state and
// tells the user.

import AppKit
import Carbon
import IOKit

/// What macOS reports as the secure input holder. The PID comes from
/// `kCGSSessionSecureInputPID` and is not always the real holder: it can
/// name the frontmost app instead of a background process.
struct SecureInputHolder: Equatable {
    let pid: pid_t
    let appName: String?

    var displayName: String { appName ?? "pid \(pid)" }
}

/// Edge detector for secure input. Pure apart from the injected reads, so
/// tests drive it with plain closures.
final class SecureInputMonitor {
    enum Transition: Equatable {
        case enabled(SecureInputHolder?)
        case disabled
    }

    private let isEnabled: () -> Bool
    private let holder: () -> SecureInputHolder?
    private(set) var isActive = false

    init(isEnabled: @escaping () -> Bool = SecureInputMonitor.systemIsEnabled,
         holder: @escaping () -> SecureInputHolder? = SecureInputMonitor.systemHolder) {
        self.isEnabled = isEnabled
        self.holder = holder
    }

    /// Reads the current state and returns a transition when it changed
    /// since the last call. The holder is read only on the way in.
    func poll() -> Transition? {
        let now = isEnabled()
        guard now != isActive else { return nil }
        isActive = now
        return now ? .enabled(holder()) : .disabled
    }

    /// Forget the last state, so the next poll reports an active secure
    /// input again. Used when the tap stops.
    func reset() {
        isActive = false
    }

    static func systemIsEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }

    static func systemHolder() -> SecureInputHolder? {
        guard let pid = systemHolderPID() else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        return SecureInputHolder(pid: pid, appName: app?.localizedName ?? app?.bundleIdentifier)
    }

    /// `kCGSSessionSecureInputPID` from the console users list in the IO
    /// registry, the same value `ioreg -l -w 0 | grep -i SecureInput` shows.
    static func systemHolderPID() -> pid_t? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let users = IORegistryEntryCreateCFProperty(
            root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]] else { return nil }
        return holderPID(inConsoleUsers: users)
    }

    static func holderPID(inConsoleUsers users: [[String: Any]]) -> pid_t? {
        for user in users {
            if let pid = (user["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value, pid > 0 {
                return pid
            }
        }
        return nil
    }
}
