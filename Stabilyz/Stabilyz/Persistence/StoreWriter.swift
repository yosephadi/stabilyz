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
    enum WriteError: Error, Equatable {
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

    /// Commits a session and, optionally, the baseline it establishes — as one
    /// transaction (docs/06 §6.3).
    ///
    /// Both land or neither does. Writing them separately would leave a window
    /// where the fifth valid session is stored but its baseline is not: the
    /// count would read 5 with nothing established, and the next commit would
    /// try to establish again from a set that now includes a sixth session.
    func commit(_ session: GaitSession, establishing baseline: Baseline?) throws {
        let sessionEntity = try EntityMapping.entity(from: session)
        let id = session.id
        let baselineEntity = try baseline.map(EntityMapping.entity(from:))
        let mode = baseline?.mode
        let modeRaw = mode?.rawValue

        try transaction {
            let existing = try modelContext.fetch(
                FetchDescriptor<GaitSessionEntity>(predicate: #Predicate { $0.id == id })
            )
            for row in existing { modelContext.delete(row) }
            modelContext.insert(sessionEntity)

            guard let baselineEntity, let mode, let modeRaw else { return }

            // Create-only, checked inside the same transaction so a concurrent
            // establish cannot slip between the check and the insert.
            let existingBaselines = try modelContext.fetch(
                FetchDescriptor<BaselineEntity>(predicate: #Predicate { $0.mode == modeRaw })
            )
            guard existingBaselines.isEmpty else {
                throw WriteError.baselineAlreadyExists(mode: mode)
            }
            modelContext.insert(baselineEntity)
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
    ///
    /// - Parameter beforeSave: runs inside the transaction after every delete
    ///   and insert, immediately before the save. **A test seam only**: it lets
    ///   a test fail the real save and prove the rollback undoes everything
    ///   staged (Task 10.3.4). Production passes nothing.
    func replaceAll(
        profile: UserProfile?,
        sessions: [GaitSession],
        baselines: [Baseline],
        beforeSave: (@Sendable () throws -> Void)? = nil
    ) throws {
        let profileEntity = profile.map(EntityMapping.entity(from:))
        let sessionEntities = try sessions.map(EntityMapping.entity(from:))
        let baselineEntities = try baselines.map(EntityMapping.entity(from:))

        try transaction {
            // Row by row, not `modelContext.delete(model:)`. That call is a
            // batch delete that reaches the store at once, outside this
            // transaction, so a failed save used to leave the store emptied
            // rather than untouched (found by Task 10.3.4's
            // `aFailedReplaceAllRollsBackEveryDeleteAndInsert`). Deleting
            // fetched objects stages the deletes in the context, where
            // `rollback()` undoes them. The store is small; the cost is nil.
            for row in try modelContext.fetch(FetchDescriptor<GaitSessionEntity>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<BaselineEntity>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<UserProfileEntity>()) { modelContext.delete(row) }

            if let profileEntity { modelContext.insert(profileEntity) }
            for entity in sessionEntities { modelContext.insert(entity) }
            for entity in baselineEntities { modelContext.insert(entity) }

            try beforeSave?()
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
