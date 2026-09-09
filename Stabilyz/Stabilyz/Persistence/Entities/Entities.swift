import Foundation
import SwiftData

/// Scalar columns exist only for fields that are actually queried; everything
/// else rides in a Codable JSON blob (docs/05 §5.2, docs/06 §6.2).
///
/// Query needs are narrow — mode, date, validity, score — so blobs avoid a
/// 30-column table and keep metric evolution schema-light. Accepted trade-off:
/// individual metrics are not queryable, and no PRD requirement queries them.

@Model
nonisolated final class UserProfileEntity {
    /// Uniqueness invariant: exactly one profile (docs/06 §6.3).
    #Unique<UserProfileEntity>([\.id])

    var id: UUID = UUID()
    var amputationLevel: String = ""
    var side: String = ""
    var timeSinceAmputationMonths: Int = 0
    var prosthesisType: String?
    var kLevel: String?
    var disclaimerAcceptedAt: Date = Date.distantPast
    var createdAt: Date = Date.distantPast

    init(
        id: UUID,
        amputationLevel: String,
        side: String,
        timeSinceAmputationMonths: Int,
        prosthesisType: String?,
        kLevel: String?,
        disclaimerAcceptedAt: Date,
        createdAt: Date
    ) {
        self.id = id
        self.amputationLevel = amputationLevel
        self.side = side
        self.timeSinceAmputationMonths = timeSinceAmputationMonths
        self.prosthesisType = prosthesisType
        self.kLevel = kLevel
        self.disclaimerAcceptedAt = disclaimerAcceptedAt
        self.createdAt = createdAt
    }
}

@Model
nonisolated final class GaitSessionEntity {
    #Unique<GaitSessionEntity>([\.id])

    var id: UUID = UUID()
    /// `TestMode.rawValue` — the segregation key on every query [PRD OQ-5].
    var mode: String = ""
    var startedAt: Date = Date.distantPast
    /// `SessionValidity.valid` or an `InvalidReason.rawValue`.
    var validity: String = ""
    /// Nil for unscored sessions; the only score field worth querying.
    var relativeIndex: Int?
    var algorithmVersion: String = ""
    /// JSON `GaitSessionPayload`.
    var payload: Data = Data()

    init(
        id: UUID,
        mode: String,
        startedAt: Date,
        validity: String,
        relativeIndex: Int?,
        algorithmVersion: String,
        payload: Data
    ) {
        self.id = id
        self.mode = mode
        self.startedAt = startedAt
        self.validity = validity
        self.relativeIndex = relativeIndex
        self.algorithmVersion = algorithmVersion
        self.payload = payload
    }
}

@Model
nonisolated final class BaselineEntity {
    /// One baseline per mode, enforced at the store as well as in the
    /// repository — belt and braces for [PRD OQ-5] (docs/06 §6.3).
    #Unique<BaselineEntity>([\.mode])

    var id: UUID = UUID()
    var mode: String = ""
    var cadenceBPM: Double = 0
    var establishedAt: Date = Date.distantPast
    var algorithmVersion: String = ""
    /// JSON `BaselinePayload`.
    var payload: Data = Data()

    init(
        id: UUID,
        mode: String,
        cadenceBPM: Double,
        establishedAt: Date,
        algorithmVersion: String,
        payload: Data
    ) {
        self.id = id
        self.mode = mode
        self.cadenceBPM = cadenceBPM
        self.establishedAt = establishedAt
        self.algorithmVersion = algorithmVersion
        self.payload = payload
    }
}
