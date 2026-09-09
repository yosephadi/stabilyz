import Foundation

/// The non-queried half of a session, stored as one JSON blob (docs/05 §5.2).
struct GaitSessionPayload: Codable, Equatable {
    let endedAt: Date
    let advertisedClockElapsed: Duration
    let validWalkingDuration: Duration
    let metrics: GaitMetrics?
    let score: SessionScore?
    let audioConfig: SessionAudioConfig
    let appVersion: String
    let deviceModel: String
    let interruptionCount: Int
    let gapInfo: SessionGapInfo
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
