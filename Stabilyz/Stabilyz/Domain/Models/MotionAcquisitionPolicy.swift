import Foundation

/// Sensor acquisition settings (docs/07-motion-sensor-architecture.md §7.5).
///
/// The shape the motion service is configured with. The values come from
/// `AlgorithmConfiguration` and are declared nowhere else, so tuning never
/// touches a call site (docs/07 §7.5).
struct MotionAcquisitionPolicy: Sendable, Equatable {
    let sampleRateHz: Double
    /// Device-motion updates supply the gravity vector used for orientation handling.
    let deviceMotionEnabled: Bool

    init(sampleRateHz: Double, deviceMotionEnabled: Bool) {
        self.sampleRateHz = sampleRateHz
        self.deviceMotionEnabled = deviceMotionEnabled
    }
}

/// Motion & Fitness authorization, surfaced as a domain value so the Feature
/// layer never sees CoreMotion types (docs/07 §7.6, docs/03 boundary rule 4).
enum MotionAuthorizationStatus: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
}
