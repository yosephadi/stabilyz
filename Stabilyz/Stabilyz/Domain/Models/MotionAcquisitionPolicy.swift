import Foundation

/// Sensor acquisition settings (docs/07-motion-sensor-architecture.md §7.5).
///
/// The tunable values move into the versioned `AlgorithmConfiguration` in
/// Task 5.1.2 so tuning never touches call sites; this type is the shape the
/// motion service is configured with.
///
/// [OPEN/REC] Sample rate: docs/07 §7.2 recommends 100 Hz but requires empirical
/// validation (docs/21). `recommendedDefault` carries that recommendation and is
/// NOT a resolved decision.
nonisolated struct MotionAcquisitionPolicy: Sendable, Equatable {
    let sampleRateHz: Double
    /// Device-motion updates supply the gravity vector used for orientation handling.
    let deviceMotionEnabled: Bool

    init(sampleRateHz: Double, deviceMotionEnabled: Bool) {
        self.sampleRateHz = sampleRateHz
        self.deviceMotionEnabled = deviceMotionEnabled
    }

    /// [OPEN/REC — docs/07 §7.2] 100 Hz pending empirical validation.
    static let recommendedDefault = MotionAcquisitionPolicy(sampleRateHz: 100, deviceMotionEnabled: true)
}

/// Motion & Fitness authorization, surfaced as a domain value so the Feature
/// layer never sees CoreMotion types (docs/07 §7.6, docs/03 boundary rule 4).
nonisolated enum MotionAuthorizationStatus: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
}
