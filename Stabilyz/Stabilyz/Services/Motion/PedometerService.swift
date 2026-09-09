import Foundation

/// Streams pedometer updates co-recorded with the accelerometer signal
/// (docs/07-motion-sensor-architecture.md §7.2).
///
/// The production implementation wraps `CMPedometer`; tests use a scripted
/// event sequence (docs/12 §12.2).
protocol PedometerService: Sendable {
    /// Whether this device has step counting hardware at all.
    var isAvailable: Bool { get async }

    /// Motion & Fitness authorization. Distinct from `isAvailable`: a denied
    /// permission must stop a session, whereas absent hardware only removes the
    /// cross-check (docs/07 §7.6, docs/15 §15.1).
    var authorizationStatus: MotionAuthorizationStatus { get async }

    /// Begins live updates and returns the event stream.
    func start() async throws -> AsyncStream<PedometerEvent>

    /// Stops live updates. Safe to call when not started.
    func stop() async

    /// Historical query used to verify step continuity across a sensor gap
    /// (docs/07 §7.7). Returns nil when no data covers the window.
    func events(from start: Date, to end: Date) async throws -> PedometerEvent?
}
