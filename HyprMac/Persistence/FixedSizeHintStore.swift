// The per-app lengths windows kept, so a restart doesn't repeat the resize and
// rollback each app already showed. Per machine, never synced.

import Foundation

final class FixedSizeHintStore {
    static let shared = FixedSizeHintStore(
        fileURL: ConfigStore.configDir.appendingPathComponent("fixed-size-hints.json"))

    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // learned data, so an unreadable file costs one more try per app and no more
    func load() -> [FixedSize] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode([FixedSize].self, from: data)
        } catch {
            hyprLog(.warning, .persistence, "fixed-size-hints.json unreadable; starting over")
            return []
        }
    }

    func save(_ hints: [FixedSize]) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(hints).write(to: fileURL, options: .atomic)
        } catch {
            hyprLog(.warning, .persistence, "fixed-size hints not saved: \((error as NSError).code)")
        }
    }
}
