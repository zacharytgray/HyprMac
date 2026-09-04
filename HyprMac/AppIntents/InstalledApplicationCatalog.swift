// Public-API-only discovery of launchable macOS applications for App Intents.

import AppKit
import Foundation

/// The small, Sendable value the Spotlight entity layer needs for an app.
struct InstalledApplicationRecord: Hashable, Sendable {
    let bundleIdentifier: String
    let displayName: String
    let url: URL
}

/// Discovers applications without relying on private LaunchServices symbols.
///
/// There is no public API that enumerates every registered application. The
/// catalog therefore scans the standard application folders, then uses
/// `NSWorkspace` only to resolve persistent bundle identifiers. Apps installed
/// elsewhere can still be restored by identifier when LaunchServices knows
/// about them.
actor InstalledApplicationCatalog {
    static let shared = InstalledApplicationCatalog()

    static var defaultSearchRoots: [URL] {
        let fileManager = FileManager.default
        return [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true),
        ]
    }

    private let fileManager: FileManager
    private let searchRoots: [URL]
    private let cacheLifetime: TimeInterval
    private var cachedApplications: [InstalledApplicationRecord]?
    private var cacheDate: Date?

    init(
        searchRoots: [URL] = InstalledApplicationCatalog.defaultSearchRoots,
        fileManager: FileManager = .default,
        cacheLifetime: TimeInterval = 300
    ) {
        self.searchRoots = searchRoots
        self.fileManager = fileManager
        self.cacheLifetime = cacheLifetime
    }

    /// Return the cached catalog, rescanning after the short cache lifetime.
    func applications(forceRefresh: Bool = false) -> [InstalledApplicationRecord] {
        if !forceRefresh,
           let cachedApplications,
           let cacheDate,
           Date().timeIntervalSince(cacheDate) < cacheLifetime {
            return cachedApplications
        }

        let applications = scanSearchRoots()
        cachedApplications = applications
        cacheDate = Date()
        return applications
    }

    /// Resolve stable entity identifiers while preserving the caller's order.
    func applications(for bundleIdentifiers: [String]) async -> [InstalledApplicationRecord] {
        var byIdentifier = Dictionary(
            uniqueKeysWithValues: applications().map { ($0.bundleIdentifier, $0) }
        )

        for identifier in bundleIdentifiers where byIdentifier[identifier] == nil {
            guard let url = await applicationURL(for: identifier),
                  let application = application(at: url) else { continue }
            byIdentifier[identifier] = application
        }

        return bundleIdentifiers.compactMap { byIdentifier[$0] }
    }

    /// Search by the user-visible name or bundle identifier.
    func applications(matching query: String, limit: Int = 50) -> [InstalledApplicationRecord] {
        let normalizedQuery = Self.normalized(query)
        guard !normalizedQuery.isEmpty else {
            return Array(applications().prefix(max(0, limit)))
        }

        return applications()
            .compactMap { application -> (InstalledApplicationRecord, Int)? in
                guard let score = Self.matchScore(application, query: normalizedQuery) else {
                    return nil
                }
                return (application, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return Self.sortsBefore(lhs.0, rhs.0)
            }
            .prefix(max(0, limit))
            .map(\.0)
    }

    /// Stable suggestions also suit the App Shortcut parameter snapshot;
    /// launching or quitting an app does not invalidate that snapshot.
    func suggestedApplications(limit: Int = 24) -> [InstalledApplicationRecord] {
        Array(applications().prefix(max(0, limit)))
    }

    func invalidate() {
        cachedApplications = nil
        cacheDate = nil
    }

    private func scanSearchRoots() -> [InstalledApplicationRecord] {
        var byIdentifier: [String: InstalledApplicationRecord] = [:]
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]

        for root in searchRoots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            var candidates: [URL] = []
            for case let url as URL in enumerator {
                guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { continue }
                candidates.append(url)
            }

            // FileManager does not promise enumeration order. Sorting within
            // each priority-ordered root makes duplicate bundle IDs stable.
            for url in candidates.sorted(by: { $0.path < $1.path }) {
                guard let application = application(at: url),
                      byIdentifier[application.bundleIdentifier] == nil else { continue }
                byIdentifier[application.bundleIdentifier] = application
            }
        }

        return byIdentifier.values.sorted(by: Self.sortsBefore)
    }

    private func application(at url: URL) -> InstalledApplicationRecord? {
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let bundle = Bundle(url: canonicalURL),
              bundle.executableURL != nil,
              let rawIdentifier = bundle.bundleIdentifier else { return nil }

        let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return nil }

        if let packageType = bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String,
           packageType != "APPL" {
            return nil
        }
        if (bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool) == true {
            return nil
        }
        if (bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool) == true {
            return nil
        }

        let displayName = Self.nonEmptyString(bundle.object(forInfoDictionaryKey: "CFBundleDisplayName"))
            ?? Self.nonEmptyString(bundle.object(forInfoDictionaryKey: "CFBundleName"))
            ?? canonicalURL.deletingPathExtension().lastPathComponent

        return InstalledApplicationRecord(
            bundleIdentifier: identifier,
            displayName: displayName,
            url: canonicalURL
        )
    }

    private func applicationURL(for bundleIdentifier: String) async -> URL? {
        await MainActor.run {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matchScore(
        _ application: InstalledApplicationRecord,
        query: String
    ) -> Int? {
        let name = normalized(application.displayName)
        let identifier = normalized(application.bundleIdentifier)
        let terms = query.split(whereSeparator: \Character.isWhitespace).map(String.init)

        guard terms.allSatisfy({ name.contains($0) || identifier.contains($0) }) else {
            return nil
        }

        if name == query { return 0 }
        if identifier == query { return 1 }
        if name.hasPrefix(query) { return 10 }
        if name.split(whereSeparator: \Character.isWhitespace).contains(where: { $0.hasPrefix(query) }) {
            return 20
        }
        if name.contains(query) { return 30 }
        return 40
    }

    private static func sortsBefore(
        _ lhs: InstalledApplicationRecord,
        _ rhs: InstalledApplicationRecord
    ) -> Bool {
        let nameComparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
        return lhs.bundleIdentifier < rhs.bundleIdentifier
    }
}
