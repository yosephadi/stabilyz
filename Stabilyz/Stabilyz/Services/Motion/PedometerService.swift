import Foundation

/// Streams pedometer updates co-recorded with the accelerometer signal
/// (docs/07-motion-sensor-architecture.md §7.2).
///
/// The production implementation wraps `CMPedometer`; tests use a scripted
/// event sequence (docs/12 §12.2).
nonisolated protocol PedometerService: Sendable {
    var isAvailable: Bool { get }

    /// Begins live updates and returns the event stream.
    func start() async throws -> AsyncStream<PedometerEvent>

    /// Stops live updates. Safe to call when not started.
    func stop() async

    /// Historical query used to verify step continuity across a sensor gap
    /// (docs/07 §7.7). Returns nil when no data covers the window.
    func events(from start: Date, to end: Date) async throws -> PedometerEvent?
}
