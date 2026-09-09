import Foundation

/// Streams trunk acceleration for a recording session
/// (docs/07-motion-sensor-architecture.md §7.2, §7.6).
///
/// The production implementation wraps `CMMotionManager`; tests and previews use
/// a fixture replay service (docs/12 §12.2). Raw CoreMotion types are converted
/// to `SensorSample` here and never leak upward (docs/03 boundary rule 4).
protocol MotionSensorService: Sendable {
    /// Whether the hardware exists on this device (docs/07 §7.6).
    ///
    /// Async because the production implementation is an actor guarding
    /// `CMMotionManager`, which is not safe to touch from arbitrary contexts.
    var isAvailable: Bool { get async }

    var authorizationStatus: MotionAuthorizationStatus { get async }

    func requestAuthorization() async -> MotionAuthorizationStatus

    /// Begins updates and returns the sample stream. Throws if priming fails or
    /// exceeds the start-latency budget — never fails silently (docs/07 §7.3).
    func start(policy: MotionAcquisitionPolicy) async throws -> AsyncStream<SensorSample>

    /// Stops updates. Safe to call when not started.
    func stop() async
}
