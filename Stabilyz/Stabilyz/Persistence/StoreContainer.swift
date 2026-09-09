import Foundation
import SwiftData

/// Schema version 1 (docs/06 §6.3).
///
/// The version is carried by `VersionedSchema` so migration gating is a first
/// class concern rather than a loose constant. The narrow schema and blob-based
/// metric storage are what keep future migrations cheap (docs/06 §6.2).
enum StabilyzSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [UserProfileEntity.self, GaitSessionEntity.self, BaselineEntity.self]
    }
}

/// Builds the SwiftData container at the composition root (docs/06 §6.3).
enum StoreContainer {
    /// The schema version stamped on this build.
    static var schemaVersion: Schema.Version { StabilyzSchemaV1.versionIdentifier }

    /// - Parameter inMemory: used by tests and previews (docs/19 §19.2).
    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: StabilyzSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
