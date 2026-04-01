import Foundation

class UserConfig: ObservableObject {
    static let shared = UserConfig()

    @Published var keybinds: [Keybind] {
        didSet { save() }
    }
    @Published var gapSize: CGFloat {
        didSet { save() }
    }
    @Published var outerPadding: CGFloat {
        didSet { save() }
    }
    @Published var enabled: Bool {
        didSet { save() }
    }
    @Published var focusFollowsMouse: Bool {
        didSet { save() }
    }
    @Published var doubleTapAction: Keybind.ActionDescriptor? {
        didSet { save() }
    }
    @Published var excludedBundleIDs: Set<String> {
        didSet { save() }
    }
    @Published var animateWindows: Bool {
        didSet { save() }
    }
    @Published var animationDuration: Double {
        didSet { save() }
    }

    private let configURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HyprMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }()

    init() {
        if let data = try? Data(contentsOf: configURL),
           let saved = try? JSONDecoder().decode(SavedConfig.self, from: data) {
            self.keybinds = saved.keybinds
            self.gapSize = saved.gapSize
            self.outerPadding = saved.outerPadding
            self.enabled = saved.enabled
            self.focusFollowsMouse = saved.focusFollowsMouse ?? true
            self.doubleTapAction = saved.doubleTapAction ?? .focusMenuBar
            self.excludedBundleIDs = Set(saved.excludedBundleIDs ?? Self.defaultExcludedBundleIDs)
            self.animateWindows = saved.animateWindows ?? true
            self.animationDuration = saved.animationDuration ?? 0.15
        } else {
            self.keybinds = Keybind.defaults
            self.gapSize = 8
            self.outerPadding = 8
            self.enabled = true
            self.focusFollowsMouse = true
            self.doubleTapAction = .focusMenuBar
            self.excludedBundleIDs = Set(Self.defaultExcludedBundleIDs)
            self.animateWindows = true
            self.animationDuration = 0.15
        }
    }

    static let defaultExcludedBundleIDs: [String] = [
        "com.apple.FaceTime",
        "com.apple.systempreferences",
    ]

    func save() {
        let saved = SavedConfig(keybinds: keybinds, gapSize: gapSize,
                                outerPadding: outerPadding, enabled: enabled,
                                focusFollowsMouse: focusFollowsMouse,
                                doubleTapAction: doubleTapAction,
                                excludedBundleIDs: Array(excludedBundleIDs),
                                animateWindows: animateWindows,
                                animationDuration: animationDuration)
        if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: configURL)
        }
    }

    func resetToDefaults() {
        keybinds = Keybind.defaults
        gapSize = 8
        outerPadding = 8
        enabled = true
        focusFollowsMouse = true
        doubleTapAction = .focusMenuBar
        excludedBundleIDs = Set(Self.defaultExcludedBundleIDs)
        animateWindows = true
        animationDuration = 0.15
    }
}

private struct SavedConfig: Codable {
    let keybinds: [Keybind]
    let gapSize: CGFloat
    let outerPadding: CGFloat
    let enabled: Bool
    let focusFollowsMouse: Bool?
    let doubleTapAction: Keybind.ActionDescriptor?
    let excludedBundleIDs: [String]?
    let animateWindows: Bool?
    let animationDuration: Double?
}
