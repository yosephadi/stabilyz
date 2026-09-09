import Foundation
import SwiftData

/// The single write path into the store (docs/06 §6.3, docs/14 §14.2).
///
/// A background `ModelActor`, so session commits, baseline creation and restore
/// never block the UI. Reads for SwiftUI go through the main context instead.
///
/// Every method is one transaction: mutate, then a single `save()`. On failure
/// the context is rolled back so a failed commit leaves the store untouched —
/// the guarantee docs/15 §15.1 makes for the persistence category.
@ModelActor
actor StoreWriter {
    nonisolated enum WriteError: Error, Equatable {
        /// A baseline already exists for that mode. Baselines are create-only
        /// and frozen in v1 [PRD §6, docs/09 §9.3].
        case baselineAlreadyExists(mode: TestMode)
        case saveFailed
    }

    // MARK: - Sessions

    /// Inserts a session, or replaces the row with the same id.
    func save(_ session: GaitSession) throws {
        let entity = try EntityMapping.entity(from: session)
        let id = session.id

        try transaction {
            let existing = try modelContext.fetch(
                FetchDescriptor<GaitSessionEntity>(predicate: #Predicate { $0.id == id })
            )
            for row in existing { modelContext.delete(row) }
            modelContext.insert(entity)
        }
    }

    // MARK: - Baselines

    /// Creates a baseline for its mode.
    ///
    /// Create-only: the repository-level half of the one-baseline-per-mode
    /// guarantee, alongside the store's unique constraint (docs/09 §9.7).
    func establish(_ baseline: Baseline) throws {
        let mode = baseline.mode
        let modeRaw = mode.rawValue
        let entity = try EntityMapping.entity(from: baseline)

        try transaction {
            let existing = try modelContext.fetch(
                FetchDescriptor<BaselineEntity>(predicate: #Predicate { $0.mode == modeRaw })
            )
            guard existing.isEmpty else {
                throw WriteError.baselineAlreadyExists(mode: mode)
            }
            modelContext.insert(entity)
        }
    }

    // MARK: - Profile

    /// Inserts or replaces the single profile row (docs/06 §6.3).
    func save(_ profile: UserProfile) throws {
        let entity = EntityMapping.entity(from: profile)

        try transaction {
            for row in try modelContext.fetch(FetchDescriptor<UserProfileEntity>()) {
                modelContext.delete(row)
            }
            modelContext.insert(entity)
        }
    }

    // MARK: - Restore

    /// Deletes everything and inserts the supplied data as one transaction.
    ///
    /// Import is a restore, not a merge [PRD OQ-2]: no duplicate resolution and
    /// no baseline merging, ever. A failure rolls the whole thing back, leaving
    /// the store unchanged (docs/13 §13.5 step 3).
    func replaceAll(profile: UserProfile?, sessions: [GaitSession], baselines: [Baseline]) throws {
        let profileEntity = profile.map(EntityMapping.entity(from:))
        let sessionEntities = try sessions.map(EntityMapping.entity(from:))
        let baselineEntities = try baselines.map(EntityMapping.entity(from:))

        try transaction {
            try modelContext.delete(model: GaitSessionEntity.self)
            try modelContext.delete(model: BaselineEntity.self)
            try modelContext.delete(model: UserProfileEntity.self)

            if let profileEntity { modelContext.insert(profileEntity) }
            for entity in sessionEntities { modelContext.insert(entity) }
            for entity in baselineEntities { modelContext.insert(entity) }
        }
    }

    // MARK: - Transaction

    /// Runs `body` and saves once. Any throw rolls the context back so no
    /// partial write survives.
    private func transaction(_ body: () throws -> Void) throws {
        do {
            try body()
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}
