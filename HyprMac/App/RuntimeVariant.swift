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
