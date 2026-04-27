// Bundle-ID display helper. Used by Settings to render
// human-friendly app names in the launcher list.

import AppKit

/// Resolve `bundleID` to the corresponding app's display name,
/// falling back to the raw bundle identifier when the app is not
/// installed.
func appDisplayName(for bundleID: String) -> String {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        return url.deletingPathExtension().lastPathComponent
    }
    return bundleID
}
