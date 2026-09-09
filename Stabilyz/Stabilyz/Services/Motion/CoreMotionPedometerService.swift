import CoreMotion
import Foundation

/// Production `PedometerService` over `CMPedometer`
/// (docs/07-motion-sensor-architecture.md §7.2, §7.7).
///
/// Co-recorded with the accelerometer signal and used as a cross-check input
/// for segmentation and step detection, and to verify step continuity across a
/// sensor gap.
actor CoreMotionPedometerService: PedometerService {
    private let pedometer: CMPedometer
    private let logService: LogService
    private var continuation: AsyncStream<PedometerEvent>.Continuation?

    init(logService: LogService, pedometer: CMPedometer = CMPedometer()) {
        self.logService = logService
        self.pedometer = pedometer
    }

    var isAvailable: Bool {
        CMPedometer.isStepCountingAvailable()
    }

    func start() async throws -> AsyncStream<PedometerEvent> {
        guard CMPedometer.isStepCountingAvailable() else {
            logService.log(.error, .motion, "step counting unavailable")
            throw StabilyzError.sensor(.unavailable)
        }

        stopUpdates()

        let (stream, continuation) = AsyncStream<PedometerEvent>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation

        pedometer.startUpdates(from: Date()) { data, error in
            guard let data else {
                if error != nil { continuation.finish() }
                return
            }
            continuation.yield(Self.event(from: data))
        }

        logService.log(.info, .motion, "pedometer updates started")
        return stream
    }

    func stop() async {
        stopUpdates()
        logService.log(.info, .motion, "pedometer updates stopped")
    }

    /// Historical query used to verify step continuity across a sensor gap
    /// (docs/07 §7.7). Returns nil when no data covers the window.
    func events(from start: Date, to end: Date) async throws -> PedometerEvent? {
        guard CMPedometer.isStepCountingAvailable() else {
            throw StabilyzError.sensor(.unavailable)
        }

        let pedometer = self.pedometer
        return try await withCheckedThrowingContinuation { continuation in
            pedometer.queryPedometerData(from: start, to: end) { data, error in
                if let data {
                    continuation.resume(returning: Self.event(from: data))
                } else if error != nil {
                    // A query that cannot answer is not a session failure; the
                    // gap check simply has no continuity evidence.
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Internals

    private func stopUpdates() {
        pedometer.stopUpdates()
        continuation?.finish()
        continuation = nil
    }

    /// Pure conversion, so the mapping is testable without hardware.
    ///
    /// CoreMotion reports cadence in steps/second and pace in seconds/metre;
    /// both are optional because not every device supplies them.
    nonisolated static func event(from data: CMPedometerData) -> PedometerEvent {
        PedometerEvent(
            steps: data.numberOfSteps.intValue,
            cadence: data.currentCadence?.doubleValue,
            pace: data.currentPace?.doubleValue,
            distance: data.distance?.doubleValue,
            timestamp: data.endDate
        )
    }
}
