import Foundation

/// The non-queried half of a session, stored as one JSON blob (docs/05 §5.2).
struct GaitSessionPayload: Codable, Equatable {
    let endedAt: Date
    let advertisedClockElapsed: Duration
    let validWalkingDuration: Duration
    let metrics: GaitMetrics?
    let score: SessionScore?
    /// Optional for the same reason as the two fields below: absent means the
    /// row was written before the pre-baseline score existed. It is **not** a
    /// queried column — nothing filters or charts on it, and nothing may, since
    /// it is a different scale from `relativeIndex`.
    let provisionalScore: ProvisionalStabilityScore?
    let audioConfig: SessionAudioConfig
    /// Optional for the same reason as `pedometerAvailable` below: absent means
    /// the session was never silenced, which is what every row written before
    /// this field existed was.
    let audioSilencedAt: Duration?
    let appVersion: String
    let deviceModel: String
    let interruptionCount: Int
    let gapInfo: SessionGapInfo
    /// Optional so a row written before this field was added still decodes;
    /// absent means the cross-check availability was not recorded, which is
    /// read as available.
    let pedometerAvailable: Bool?
}

/// The non-queried half of a baseline (docs/05 §5.2).
struct BaselinePayload: Codable, Equatable {
    let stats: [BaselineMetricStat]
    let sourceSessionIDs: [UUID]
}

/// The stored form of `SessionOutcome`, flattened into the queryable `validity`
/// column so History and baseline counting can filter without decoding a blob.
enum SessionValidity {
    static let valid = "valid"

    static func column(for outcome: SessionOutcome) -> String {
        switch outcome {
        case .valid: valid
        case .invalid(let reason): reason.rawValue
        }
    }

    static func outcome(from column: String) -> SessionOutcome? {
        if column == valid { return .valid }
        guard let reason = InvalidReason(rawValue: column) else { return nil }
        return .invalid(reason: reason)
    }
}
