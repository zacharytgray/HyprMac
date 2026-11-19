import Foundation

enum RuntimeVariant {
    static let releaseBundleIdentifier = "com.zachgray.HyprMac"

    #if HYPRMAC_DEBUG_VARIANT
    static let isDebugApp = true
    #else
    static let isDebugApp = false
    #endif

    static func inheritedBool(forKey key: String,
                              standard: UserDefaults = .standard,
                              releaseDomain: [String: Any]? = nil,
                              debugApp: Bool = isDebugApp) -> Bool {
        if let local = standard.object(forKey: key) as? Bool {
            return local
        }
        guard debugApp else { return false }
        let release = releaseDomain
            ?? standard.persistentDomain(forName: releaseBundleIdentifier)
        return release?[key] as? Bool ?? false
    }

    /// True when Nix installed this copy: the bundle sits in the Nix store
    /// or in a folder nix-darwin or Home Manager fills with store apps.
    /// Sparkle would replace a bundle Nix owns, so it stays off.
    static let updatesManagedByNix = isNixInstall(bundlePath: Bundle.main.bundlePath)

    static func isNixInstall(bundlePath: String) -> Bool {
        let folders = URL(fileURLWithPath: bundlePath).deletingLastPathComponent().pathComponents
        return bundlePath.hasPrefix("/nix/store/")
            || folders.contains("Nix Apps") || folders.contains("Home Manager Apps")
    }

    static func shouldShowWelcome(hasSeenOnboarding: Bool,
                                  lastVersion: String?,
                                  currentVersion: String?,
                                  debugApp: Bool = isDebugApp) -> WelcomeMode? {
        if !hasSeenOnboarding { return .firstRun }
        if debugApp { return nil }
        if lastVersion == nil || lastVersion != currentVersion { return .whatsNew }
        return nil
    }
}
