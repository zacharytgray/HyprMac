import AppKit

// resolve a bundle ID to its display name, falling back to the raw ID
func appDisplayName(for bundleID: String) -> String {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        return url.deletingPathExtension().lastPathComponent
    }
    return bundleID
}
