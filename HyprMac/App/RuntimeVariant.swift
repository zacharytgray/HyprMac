import Foundation

/// What a launch shows after access: onboarding on a fresh install, What's
/// New after an update.
enum WelcomeMode {
    case onboarding
    case whatsNew
}

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

    /// Set with `defaults write com.zachgray.HyprMac HyprMacUpdatesManagedExternally -bool true`
    /// when something outside HyprMac updates a copy Nix detection can't see,
    /// such as `brew upgrade --greedy` or an MDM. Read once at launch.
    static let updatesManagedExternallyKey = "HyprMacUpdatesManagedExternally"

    /// True when something other than Sparkle updates this copy: a Nix
    /// install, or the user-defaults key above. Sparkle stays off, Settings
    /// hides the sidebar update row, and the menu and the Updates panel say
    /// who manages updates.
    static let updatesManagedExternally = updatesManagedExternally(nixInstall: updatesManagedByNix)

    static func updatesManagedExternally(nixInstall: Bool,
                                         defaults: UserDefaults = .standard) -> Bool {
        nixInstall || defaults.bool(forKey: updatesManagedExternallyKey)
    }

    static func isNixInstall(bundlePath: String) -> Bool {
        let folders = URL(fileURLWithPath: bundlePath).deletingLastPathComponent().pathComponents
        return bundlePath.hasPrefix("/nix/store/")
            || folders.contains("Nix Apps") || folders.contains("Home Manager Apps")
    }

    /// A Mac that ran HyprMac before is already set up: it has access, a
    /// Hypr key and its settings. Any one sign counts: the old welcome's
    /// `hasSeenOnboarding`, a `lastSeenVersion` from any earlier launch, or
    /// a config.json that was there when this launch loaded it.
    static func alreadyOnboarded(hasSeenOnboarding: Bool,
                                 lastVersion: String?,
                                 hadConfigFile: Bool) -> Bool {
        hasSeenOnboarding || lastVersion != nil || hadConfigFile
    }

    static func shouldShowWelcome(alreadyOnboarded: Bool,
                                  lastVersion: String?,
                                  currentVersion: String?,
                                  debugApp: Bool = isDebugApp) -> WelcomeMode? {
        if !alreadyOnboarded { return .onboarding }
        if debugApp { return nil }
        if lastVersion == nil || lastVersion != currentVersion { return .whatsNew }
        return nil
    }
}
