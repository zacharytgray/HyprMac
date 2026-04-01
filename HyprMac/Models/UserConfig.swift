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
        } else {
            self.keybinds = Keybind.defaults
            self.gapSize = 8
            self.outerPadding = 8
            self.enabled = true
            self.focusFollowsMouse = true
        }
    }

    func save() {
        let saved = SavedConfig(keybinds: keybinds, gapSize: gapSize,
                                outerPadding: outerPadding, enabled: enabled,
                                focusFollowsMouse: focusFollowsMouse)
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
    }
}

private struct SavedConfig: Codable {
    let keybinds: [Keybind]
    let gapSize: CGFloat
    let outerPadding: CGFloat
    let enabled: Bool
    let focusFollowsMouse: Bool?  // optional for backwards compat with old configs
}
