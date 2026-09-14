import Foundation

/// What an export carries, as domain values (docs/13 §13.1, [PRD §5, §7]).
///
/// **Valid sessions only, by construction** (EPIC 6 audit: invalid sessions
/// are never exported). The initializer drops every session that is not
/// user-visible, whatever it is handed, so no call site — including a snapshot
/// read that someone later changes to `includeInvalid: true` — can put one in
/// an archive.
struct ArchivePayload: Sendable, Equatable {
    let profile: UserProfile
    /// At most one per mode [PRD OQ-5].
    let baselines: [Baseline]
    /// Valid sessions only, both modes.
    let sessions: [GaitSession]
    let appVersion: String
    /// The algorithm version of the build that wrote the archive.
    let algorithmVersion: String
    let exportedAt: Date

    init(
        profile: UserProfile,
        baselines: [Baseline],
        sessions: [GaitSession],
        appVersion: String,
        algorithmVersion: String,
        exportedAt: Date
    ) {
        self.profile = profile
        self.baselines = baselines
        self.sessions = sessions.filter(\.isUserVisible)
        self.appVersion = appVersion
        self.algorithmVersion = algorithmVersion
        self.exportedAt = exportedAt
    }

    /// Reads the store into a payload: the profile, each mode's baseline, and
    /// each mode's **valid** sessions, oldest first.
    ///
    /// Every read names its mode [PRD OQ-5], and sessions are asked for with
    /// `includeInvalid: false` — then filtered again by the initializer.
    static func snapshot(
        profiles: UserProfileRepository,
        sessions: GaitSessionRepository,
        baselines: BaselineRepository,
        buildInfo: BuildInfoProviding,
        clock: Clock,
        algorithmVersion: String = AlgorithmConfiguration.v1.version
    ) async throws -> ArchivePayload {
        guard let profile = try await profiles.fetchProfile() else {
            throw ArchiveEncodingError.missingProfile
        }

        var storedBaselines: [Baseline] = []
        var storedSessions: [GaitSession] = []
        for mode in TestMode.allCases {
            if let baseline = try await baselines.baseline(mode: mode) {
                storedBaselines.append(baseline)
            }
            storedSessions += try await sessions.sessions(mode: mode, includeInvalid: false, limit: nil)
        }

        return ArchivePayload(
            profile: profile,
            baselines: storedBaselines,
            sessions: storedSessions.sorted { lhs, rhs in
                lhs.startedAt != rhs.startedAt
                    ? lhs.startedAt < rhs.startedAt
                    : lhs.id.uuidString < rhs.id.uuidString
            },
            appVersion: buildInfo.appVersion,
            algorithmVersion: algorithmVersion,
            exportedAt: clock.now
        )
    }

    /// The first reason this payload could not be a consistent archive, if
    /// any. The same rules on the way out and the way in (docs/13 §13.4
    /// "verify archive completeness").
    var inconsistency: ArchiveEncodingError? {
        guard profile.hasAcceptedDisclaimer else { return .disclaimerNotAccepted }

        var modes = Set<TestMode>()
        for baseline in baselines {
            guard modes.insert(baseline.mode).inserted else { return .duplicateBaselineMode(baseline.mode) }
        }

        guard Set(sessions.map(\.id)).count == sessions.count else { return .duplicateSessionID }
        return nil
    }
}

/// A decrypted, validated, migrated export — nothing local has been touched
/// yet (docs/13 §13.4 step 5).
struct DecodedArchivePayload: Sendable, Equatable {
    let payload: ArchivePayload
    /// The schema the file was *written* with, before any migration.
    let schemaVersion: Int
}

/// Why an export could not be written.
///
/// Every case is either a caller bug or a platform crypto failure. The export
/// flow (Task 10.2.2) maps them all to its one plain-language message —
/// "Export didn't complete — nothing was changed" (docs/15 §15.1).
enum ArchiveEncodingError: Error, Equatable {
    case emptyPassphrase
    /// Below the configured minimum, or above `ArchiveFormat.maximumIterations`.
    case iterationsOutOfRange(Int)
    case invalidAlgorithmVersion
    case missingProfile
    case disclaimerNotAccepted
    case duplicateBaselineMode(TestMode)
    case duplicateSessionID
    case randomGenerationFailed
    case keyDerivationFailed
    case encryptionFailed
    /// The key-check and the payload drew the same nonce under one key. A
    /// 1-in-2^96 event with a real RNG; refused rather than written, because
    /// it would expose the payload.
    case nonceCollision
    case serializationFailed
    case headerNotRepresentable
}
