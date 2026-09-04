// App Intents representation of an installed application.

import AppIntents
import Foundation

/// A persistent application choice exposed to Shortcuts and Spotlight.
///
/// Bundle identifiers are stable across app moves and updates, unlike paths.
/// The query resolves the current path and display name whenever the system
/// restores an entity from a previous invocation.
struct InstalledApplicationEntity: AppEntity, Hashable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Application")
    static let defaultQuery = InstalledApplicationQuery()

    let id: String
    let displayName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(displayName)",
            subtitle: "\(id)",
            image: .init(systemName: "app")
        )
    }

    init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    init(_ application: InstalledApplicationRecord) {
        self.init(id: application.bundleIdentifier, displayName: application.displayName)
    }
}

/// Supplies a small suggestion list and full typed search on demand.
struct InstalledApplicationQuery: EntityStringQuery {
    private let catalog: InstalledApplicationCatalog

    init() {
        catalog = .shared
    }

    /// Injectable for deterministic unit tests without changing production use.
    init(catalog: InstalledApplicationCatalog) {
        self.catalog = catalog
    }

    func entities(for identifiers: [InstalledApplicationEntity.ID]) async throws
        -> [InstalledApplicationEntity] {
        await catalog.applications(for: identifiers).map(InstalledApplicationEntity.init)
    }

    func entities(matching string: String) async throws -> [InstalledApplicationEntity] {
        if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try await suggestedEntities()
        }
        return await catalog.applications(matching: string).map(InstalledApplicationEntity.init)
    }

    func suggestedEntities() async throws -> [InstalledApplicationEntity] {
        await catalog.suggestedApplications().map(InstalledApplicationEntity.init)
    }
}
