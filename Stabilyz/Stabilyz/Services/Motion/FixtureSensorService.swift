import Foundation

/// Replays a recorded or synthesised capture as if it came from the hardware
/// (docs/07 §7.9, docs/12 §12.2).
///
/// This is what makes the recorder, the pipeline and the session flow testable
/// without a device — and what drives SwiftUI previews. It is a real
/// `MotionSensorService`, so nothing downstream can tell the difference.
actor FixtureSensorService: MotionSensorService {
    /// How fast the capture is replayed.
    enum Pacing: Sendable, Equatable {
        /// Emit everything immediately. Deterministic and fast; the default for
        /// unit tests.
        case immediate
        /// Emit in wall-clock time, honouring the gaps in the capture. Used
        /// when a human needs to watch the session flow behave.
        case realTime
    }

    private let fixture: GaitFixture
    private let clock: Clock
    private let pacing: Pacing
    private var replayTask: Task<Void, Never>?
    private var continuation: AsyncStream<SensorSample>.Continuation?

    init(fixture: GaitFixture, clock: Clock, pacing: Pacing = .immediate) {
        self.fixture = fixture
        self.clock = clock
        self.pacing = pacing
    }

    /// Always true: a fixture is always "available", which is what lets a test
    /// exercise the success path on a simulator with no sensors.
    var isAvailable: Bool { true }

    var authorizationStatus: MotionAuthorizationStatus { .authorized }

    func requestAuthorization() async -> MotionAuthorizationStatus { .authorized }

    func start(policy: MotionAcquisitionPolicy) async throws -> AsyncStream<SensorSample> {
        guard !fixture.samples.isEmpty else {
            throw StabilyzError.sensor(.unavailable)
        }

        stopReplay()

        let anchor = TimeAnchor(clock: clock)
        let samples = fixture.sensorSamples(anchoredAt: anchor)
        let pacing = self.pacing

        let (stream, continuation) = AsyncStream<SensorSample>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation

        switch pacing {
        case .immediate:
            // Yield everything before returning, so the whole capture is
            // buffered by the time recording starts. Anything lazier races the
            // caller's stop() and silently truncates the replay.
            for sample in samples { continuation.yield(sample) }
            continuation.finish()

        case .realTime:
            replayTask = Task {
                var previous: TimeInterval?
                for sample in samples {
                    if Task.isCancelled { break }
                    if let previous {
                        let delay = sample.deviceTimestamp - previous
                        if delay > 0 {
                            try? await Task.sleep(for: .seconds(delay))
                        }
                    }
                    previous = sample.deviceTimestamp
                    continuation.yield(sample)
                }
                continuation.finish()
            }
        }

        return stream
    }

    func stop() async {
        stopReplay()
    }

    private func stopReplay() {
        replayTask?.cancel()
        replayTask = nil
        continuation?.finish()
        continuation = nil
    }
}

/// Replays a capture's scripted pedometer updates (docs/12 §12.2).
actor FixturePedometerService: PedometerService {
    private let fixture: GaitFixture
    private let clock: Clock
    private var continuation: AsyncStream<PedometerEvent>.Continuation?

    init(fixture: GaitFixture, clock: Clock) {
        self.fixture = fixture
        self.clock = clock
    }

    var isAvailable: Bool { true }

    func start() async throws -> AsyncStream<PedometerEvent> {
        continuation?.finish()

        let anchor = clock.now
        let events = fixture.pedometerScript.map { entry in
            PedometerEvent(
                steps: entry.steps,
                cadence: entry.cadence,
                pace: entry.pace,
                distance: entry.distance,
                timestamp: anchor.addingTimeInterval(entry.t)
            )
        }

        let (stream, continuation) = AsyncStream<PedometerEvent>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation

        for event in events { continuation.yield(event) }
        continuation.finish()

        return stream
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
    }

    /// Answers from the script, mirroring the real service's continuity check
    /// across a gap (docs/07 §7.7).
    func events(from start: Date, to end: Date) async throws -> PedometerEvent? {
        let anchor = clock.now
        return fixture.pedometerScript
            .map { entry in
                PedometerEvent(
                    steps: entry.steps,
                    cadence: entry.cadence,
                    pace: entry.pace,
                    distance: entry.distance,
                    timestamp: anchor.addingTimeInterval(entry.t)
                )
            }
            .last { $0.timestamp >= start && $0.timestamp <= end }
    }
}
