import Foundation

// MARK: - Schema v1
//
// The encrypted payload's JSON (docs/13 §13.1). Export types convert to and
// from domain values explicitly, so the archive is a contract of its own rather
// than whatever a domain type's synthesized `Codable` happens to produce
// (`Baseline`'s comment anticipates exactly this).
//
// The nested value types — `GaitMetrics`, `SessionScore`,
// `ProvisionalStabilityScore`, `SessionAudioConfig`, `SessionGapInfo`,
// `BaselineMetricStat` — are carried as their own `Codable` forms, the same
// ones the store persists. **Any change to their coding is an archive schema
// change** and needs a `schemaVersion` bump and a migration step.
//
// Dates use `JSONEncoder`'s default strategy, which round-trips a `Date`
// exactly; ISO 8601 would drop the sub-second part of every session time.

/// The decrypted document.
struct ArchiveDocument: Codable {
    let schemaVersion: Int
    let appVersion: String
    let algorithmVersion: String
    let exportedAt: Date
    /// SHA-256 of `body`, hex. The inner integrity check [PRD] beside GCM's
    /// tag (docs/13 §13.1 [REC]).
    let bodySHA256: String
    /// The JSON of `ArchiveBody`, carried as bytes so its digest is over
    /// exactly what was written.
    let body: Data
}

struct ArchiveBody: Codable {
    let profile: ArchivedProfile
    let baselines: [ArchivedBaseline]
    let sessions: [ArchivedSession]
    let preferences: ArchivedPreferences
}

/// The PRD's settings/preferences slot [PRD §5 AC].
///
/// **Empty in schema v1, and deliberately so.** No preference is persisted
/// yet — docs/05 §5.1's `Preferences` has not been built — and inventing one
/// to fill the slot would be worse than an honest empty object. When a
/// preference is persisted it is added here as an optional field, which old
/// archives decode without a migration.
struct ArchivedPreferences: Codable, Equatable {
    init() {}
}

struct ArchivedProfile: Codable, Equatable {
    let id: UUID
    let amputationLevel: AmputationLevel
    let side: AmputationSide
    let timeSinceAmputationMonths: Int
    let prosthesisType: String?
    let kLevel: KLevel?
    let disclaimerAcceptedAt: Date
    let createdAt: Date

    init(_ profile: UserProfile) {
        id = profile.id
        amputationLevel = profile.amputationLevel
        side = profile.side
        timeSinceAmputationMonths = profile.timeSinceAmputationMonths
        prosthesisType = profile.prosthesisType
        kLevel = profile.kLevel
        disclaimerAcceptedAt = profile.disclaimerAcceptedAt
        createdAt = profile.createdAt
    }

    /// Through `UserProfile`'s own validation, so an archive cannot restore a
    /// profile the app could not have created.
    func domain() throws -> UserProfile {
        try UserProfile(
            id: id,
            amputationLevel: amputationLevel,
            side: side,
            timeSinceAmputationMonths: timeSinceAmputationMonths,
            prosthesisType: prosthesisType,
            kLevel: kLevel,
            disclaimerAcceptedAt: disclaimerAcceptedAt,
            createdAt: createdAt
        )
    }
}

struct ArchivedBaseline: Codable, Equatable {
    let id: UUID
    let mode: TestMode
    let stats: [BaselineMetricStat]
    let cadenceBPM: Double
    let algorithmVersion: String
    let establishedAt: Date
    let sourceSessionIDs: [UUID]

    init(_ baseline: Baseline) {
        id = baseline.id
        mode = baseline.mode
        stats = baseline.stats
        cadenceBPM = baseline.cadenceBPM
        algorithmVersion = baseline.algorithmVersion
        establishedAt = baseline.establishedAt
        sourceSessionIDs = baseline.sourceSessionIDs
    }

    /// Through `Baseline`'s initializer, which re-checks the five-session
    /// invariant.
    func domain() throws -> Baseline {
        try Baseline(
            id: id,
            mode: mode,
            stats: stats,
            cadenceBPM: cadenceBPM,
            algorithmVersion: algorithmVersion,
            establishedAt: establishedAt,
            sourceSessionIDs: sourceSessionIDs
        )
    }
}

/// A **valid** session. There is no outcome field and metrics are required:
/// an invalid session has no representation in the archive at all.
struct ArchivedSession: Codable, Equatable {
    let id: UUID
    let mode: TestMode
    let startedAt: Date
    let endedAt: Date
    let advertisedClockElapsed: Duration
    let validWalkingDuration: Duration
    let metrics: GaitMetrics
    let score: SessionScore?
    let provisionalScore: ProvisionalStabilityScore?
    let audioConfig: SessionAudioConfig
    let audioSilencedAt: Duration?
    let algorithmVersion: String
    let appVersion: String
    let deviceModel: String
    let interruptionCount: Int
    let gapInfo: SessionGapInfo
    let pedometerAvailable: Bool

    /// Nil for any session that is not valid — the structural half of the
    /// EPIC 6 rule, under `ArchivePayload`'s filter.
    init?(_ session: GaitSession) {
        guard session.isUserVisible, let metrics = session.metrics else { return nil }
        id = session.id
        mode = session.mode
        startedAt = session.startedAt
        endedAt = session.endedAt
        advertisedClockElapsed = session.advertisedClockElapsed
        validWalkingDuration = session.validWalkingDuration
        self.metrics = metrics
        score = session.score
        provisionalScore = session.provisionalScore
        audioConfig = session.audioConfig
        audioSilencedAt = session.audioSilencedAt
        algorithmVersion = session.algorithmVersion
        appVersion = session.appVersion
        deviceModel = session.deviceModel
        interruptionCount = session.interruptionCount
        gapInfo = session.gapInfo
        pedometerAvailable = session.pedometerAvailable
    }

    /// Through `GaitSession.valid`, the only way a valid session can be made.
    func domain() -> GaitSession {
        GaitSession.valid(
            id: id,
            mode: mode,
            startedAt: startedAt,
            endedAt: endedAt,
            advertisedClockElapsed: advertisedClockElapsed,
            validWalkingDuration: validWalkingDuration,
            metrics: metrics,
            score: score,
            provisionalScore: provisionalScore,
            audioConfig: audioConfig,
            audioSilencedAt: audioSilencedAt,
            algorithmVersion: algorithmVersion,
            appVersion: appVersion,
            deviceModel: deviceModel,
            interruptionCount: interruptionCount,
            gapInfo: gapInfo,
            pedometerAvailable: pedometerAvailable
        )
    }
}

enum ArchiveJSON {
    /// Sorted keys, so the same payload always serializes to the same bytes.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}
