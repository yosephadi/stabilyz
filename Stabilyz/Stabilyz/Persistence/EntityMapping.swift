import Foundation

/// Entity ↔ domain mapping (docs/05 §5.2, docs/06 §6.3).
///
/// Mapping failures are real: a blob can fail to decode, a raw value can be
/// unknown after a bad migration. Those surface as `StabilyzError.persistence`
/// rather than crashing or silently producing a wrong-looking session.
enum EntityMapping {
    enum MappingError: Error, Equatable {
        case unknownTestMode(String)
        case unknownValidity(String)
        case unknownAmputationLevel(String)
        case unknownAmputationSide(String)
        case unknownKLevel(String)
        case corruptPayload
        /// A valid session must carry metrics; an invalid one must not.
        case outcomeMetricsMismatch
    }

    // MARK: - Session

    static func entity(from session: GaitSession) throws -> GaitSessionEntity {
        let payload = GaitSessionPayload(
            endedAt: session.endedAt,
            advertisedClockElapsed: session.advertisedClockElapsed,
            validWalkingDuration: session.validWalkingDuration,
            metrics: session.metrics,
            score: session.score,
            audioConfig: session.audioConfig,
            appVersion: session.appVersion,
            deviceModel: session.deviceModel,
            interruptionCount: session.interruptionCount,
            gapInfo: session.gapInfo
        )

        return GaitSessionEntity(
            id: session.id,
            mode: session.mode.rawValue,
            startedAt: session.startedAt,
            validity: SessionValidity.column(for: session.outcome),
            relativeIndex: session.score?.relativeIndex,
            algorithmVersion: session.algorithmVersion,
            payload: try JSONEncoder().encode(payload)
        )
    }

    static func session(from entity: GaitSessionEntity) throws -> GaitSession {
        guard let mode = TestMode(rawValue: entity.mode) else {
            throw MappingError.unknownTestMode(entity.mode)
        }
        guard let outcome = SessionValidity.outcome(from: entity.validity) else {
            throw MappingError.unknownValidity(entity.validity)
        }
        guard let payload = try? JSONDecoder().decode(GaitSessionPayload.self, from: entity.payload) else {
            throw MappingError.corruptPayload
        }

        switch outcome {
        case .valid:
            guard let metrics = payload.metrics else { throw MappingError.outcomeMetricsMismatch }
            return GaitSession.valid(
                id: entity.id,
                mode: mode,
                startedAt: entity.startedAt,
                endedAt: payload.endedAt,
                advertisedClockElapsed: payload.advertisedClockElapsed,
                validWalkingDuration: payload.validWalkingDuration,
                metrics: metrics,
                score: payload.score,
                audioConfig: payload.audioConfig,
                algorithmVersion: entity.algorithmVersion,
                appVersion: payload.appVersion,
                deviceModel: payload.deviceModel,
                interruptionCount: payload.interruptionCount,
                gapInfo: payload.gapInfo
            )
        case .invalid(let reason):
            // An invalid row carrying metrics or a score means the store was
            // written by something that bypassed the domain constructors.
            guard payload.metrics == nil, payload.score == nil else {
                throw MappingError.outcomeMetricsMismatch
            }
            return GaitSession.invalid(
                id: entity.id,
                mode: mode,
                reason: reason,
                startedAt: entity.startedAt,
                endedAt: payload.endedAt,
                advertisedClockElapsed: payload.advertisedClockElapsed,
                validWalkingDuration: payload.validWalkingDuration,
                audioConfig: payload.audioConfig,
                algorithmVersion: entity.algorithmVersion,
                appVersion: payload.appVersion,
                deviceModel: payload.deviceModel,
                interruptionCount: payload.interruptionCount,
                gapInfo: payload.gapInfo
            )
        }
    }

    // MARK: - Baseline

    static func entity(from baseline: Baseline) throws -> BaselineEntity {
        let payload = BaselinePayload(stats: baseline.stats, sourceSessionIDs: baseline.sourceSessionIDs)

        return BaselineEntity(
            id: baseline.id,
            mode: baseline.mode.rawValue,
            cadenceBPM: baseline.cadenceBPM,
            establishedAt: baseline.establishedAt,
            algorithmVersion: baseline.algorithmVersion,
            payload: try JSONEncoder().encode(payload)
        )
    }

    static func baseline(from entity: BaselineEntity) throws -> Baseline {
        guard let mode = TestMode(rawValue: entity.mode) else {
            throw MappingError.unknownTestMode(entity.mode)
        }
        guard let payload = try? JSONDecoder().decode(BaselinePayload.self, from: entity.payload) else {
            throw MappingError.corruptPayload
        }

        // Baseline's own initializer re-checks the five-session invariant, so a
        // store row that violates it cannot become a domain object.
        return try Baseline(
            id: entity.id,
            mode: mode,
            stats: payload.stats,
            cadenceBPM: entity.cadenceBPM,
            algorithmVersion: entity.algorithmVersion,
            establishedAt: entity.establishedAt,
            sourceSessionIDs: payload.sourceSessionIDs
        )
    }

    // MARK: - Profile

    static func entity(from profile: UserProfile) -> UserProfileEntity {
        UserProfileEntity(
            id: profile.id,
            amputationLevel: profile.amputationLevel.rawValue,
            side: profile.side.rawValue,
            timeSinceAmputationMonths: profile.timeSinceAmputationMonths,
            prosthesisType: profile.prosthesisType,
            kLevel: profile.kLevel?.rawValue,
            disclaimerAcceptedAt: profile.disclaimerAcceptedAt,
            createdAt: profile.createdAt
        )
    }

    static func profile(from entity: UserProfileEntity) throws -> UserProfile {
        guard let level = AmputationLevel(rawValue: entity.amputationLevel) else {
            throw MappingError.unknownAmputationLevel(entity.amputationLevel)
        }
        guard let side = AmputationSide(rawValue: entity.side) else {
            throw MappingError.unknownAmputationSide(entity.side)
        }
        var kLevel: KLevel?
        if let raw = entity.kLevel {
            guard let parsed = KLevel(rawValue: raw) else { throw MappingError.unknownKLevel(raw) }
            kLevel = parsed
        }

        // UserProfile re-validates level/side consistency on the way out.
        return try UserProfile(
            id: entity.id,
            amputationLevel: level,
            side: side,
            timeSinceAmputationMonths: entity.timeSinceAmputationMonths,
            prosthesisType: entity.prosthesisType,
            kLevel: kLevel,
            disclaimerAcceptedAt: entity.disclaimerAcceptedAt,
            createdAt: entity.createdAt
        )
    }
}
