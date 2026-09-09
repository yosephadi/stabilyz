import Foundation
import SwiftData

/// The read path used by repositories (docs/06 §6.3).
///
/// A `ModelActor` so queries stay off the main actor. SwiftUI's own `@Query`
/// reads through the main context separately; this is for repository callers.
///
/// Every session query is filtered by mode at the store, never in Swift after
/// the fact — cross-mode mixing has to be impossible by construction
/// [PRD OQ-5, docs/09 §9.7].
@ModelActor
actor StoreReader {
    // MARK: - Sessions

    func session(id: UUID) throws -> GaitSession? {
        let descriptor = FetchDescriptor<GaitSessionEntity>(predicate: #Predicate { $0.id == id })
        guard let entity = try modelContext.fetch(descriptor).first else { return nil }
        return try EntityMapping.session(from: entity)
    }

    /// Newest first. `includeInvalid` is opt-in so History and export cannot
    /// pick up invalid sessions by omission [PRD §5, §6].
    func sessions(mode: TestMode, includeInvalid: Bool, limit: Int?) throws -> [GaitSession] {
        let modeRaw = mode.rawValue
        let validColumn = SessionValidity.valid

        var descriptor = FetchDescriptor<GaitSessionEntity>(
            predicate: includeInvalid
                ? #Predicate { $0.mode == modeRaw }
                : #Predicate { $0.mode == modeRaw && $0.validity == validColumn },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        if let limit { descriptor.fetchLimit = limit }

        return try modelContext.fetch(descriptor).map(EntityMapping.session(from:))
    }

    /// Valid sessions of that mode only — the number the baseline state machine
    /// derives "Session X of 5" from. Invalid sessions never count
    /// [PRD §6, §7, docs/09 §9.4].
    func validSessionCount(mode: TestMode) throws -> Int {
        let modeRaw = mode.rawValue
        let validColumn = SessionValidity.valid

        return try modelContext.fetchCount(
            FetchDescriptor<GaitSessionEntity>(
                predicate: #Predicate { $0.mode == modeRaw && $0.validity == validColumn }
            )
        )
    }

    // MARK: - Baselines

    /// There is no mode-less baseline query, by design: cross-mode comparison
    /// is a compile-time impossibility rather than a convention (docs/09 §9.3).
    func baseline(mode: TestMode) throws -> Baseline? {
        let modeRaw = mode.rawValue
        let descriptor = FetchDescriptor<BaselineEntity>(predicate: #Predicate { $0.mode == modeRaw })
        guard let entity = try modelContext.fetch(descriptor).first else { return nil }
        return try EntityMapping.baseline(from: entity)
    }

    /// Both modes' baselines, for the clinician summary and export.
    func allBaselines() throws -> [Baseline] {
        try modelContext.fetch(FetchDescriptor<BaselineEntity>()).map(EntityMapping.baseline(from:))
    }
}
