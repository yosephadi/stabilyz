import CoreMotion
import Foundation

/// Production `MotionSensorService` over `CMMotionManager`
/// (docs/07-motion-sensor-architecture.md §7.2, §7.3, §7.6).
///
/// An actor because `CMMotionManager` owns hardware lifecycle state that must
/// not be started or stopped concurrently. Raw CoreMotion values are converted
/// to `SensorSample` here and never leak upward (docs/03 boundary rule 4).
/// Set from the CoreMotion callback queue, read by the priming wait.
/// A reference box so the escaping CoreMotion callback and the priming wait
/// share one flag.
private final class SampleArrivalFlag: Sendable {
    private let flag = Locked(false)

    func markArrived() { flag.withLock { $0 = true } }
    var hasArrived: Bool { flag.withLock { $0 } }
}

actor CoreMotionSensorService: MotionSensorService {
    private let manager: CMMotionManager
    private let activityManager: CMMotionActivityManager
    private let clock: Clock
    private let logService: LogService
    /// Start-latency budget: if the first sample does not arrive inside this,
    /// the session fails fast rather than recording nothing (docs/07 §7.3).
    private let primingBudget: Duration

    private let updateQueue: OperationQueue
    private var continuation: AsyncStream<SensorSample>.Continuation?

    init(
        clock: Clock,
        logService: LogService,
        primingBudget: Duration = .seconds(2),
        manager: CMMotionManager = CMMotionManager(),
        activityManager: CMMotionActivityManager = CMMotionActivityManager()
    ) {
        self.clock = clock
        self.logService = logService
        self.primingBudget = primingBudget
        self.manager = manager
        self.activityManager = activityManager

        let queue = OperationQueue()
        queue.name = "com.stabilyz.motion"
        // Serial: samples must stay in acquisition order.
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        self.updateQueue = queue
    }

    var isAvailable: Bool {
        manager.isAccelerometerAvailable
    }

    var authorizationStatus: MotionAuthorizationStatus {
        Self.mapAuthorization(CMMotionActivityManager.authorizationStatus())
    }

    /// CoreMotion has no explicit request call — the prompt appears on first
    /// query, so a trivial historical query is issued to trigger it.
    func requestAuthorization() async -> MotionAuthorizationStatus {
        guard CMMotionActivityManager.isActivityAvailable() else {
            return Self.mapAuthorization(CMMotionActivityManager.authorizationStatus())
        }

        let activityManager = self.activityManager
        let queue = updateQueue
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // The handler can fire more than once; resume exactly once.
            let resumed = SampleArrivalFlag()
            activityManager.queryActivityStarting(from: Date(timeIntervalSinceNow: -1), to: Date(), to: queue) { _, _ in
                guard !resumed.hasArrived else { return }
                resumed.markArrived()
                continuation.resume()
            }
        }

        return Self.mapAuthorization(CMMotionActivityManager.authorizationStatus())
    }

    func start(policy: MotionAcquisitionPolicy) async throws -> AsyncStream<SensorSample> {
        guard manager.isAccelerometerAvailable else {
            logService.log(.error, .motion, "accelerometer unavailable")
            throw StabilyzError.sensor(.unavailable)
        }
        if policy.deviceMotionEnabled && !manager.isDeviceMotionAvailable {
            logService.log(.error, .motion, "device motion unavailable")
            throw StabilyzError.sensor(.unavailable)
        }

        stopUpdates()

        // docs/07 §7.4: one anchor captured at start. Every sample's wall-clock
        // time is anchor + (deviceTimestamp - anchorUptime); durations always
        // come from device timestamps, never from Date arithmetic.
        let anchor = clock.now
        let interval = 1.0 / policy.sampleRateHz
        let arrival = SampleArrivalFlag()

        let (stream, continuation) = AsyncStream<SensorSample>.makeStream(
            // Recording is the irreplaceable data: never drop samples because a
            // consumer is slow (docs/14 §14.3).
            bufferingPolicy: .unbounded
        )
        self.continuation = continuation

        if policy.deviceMotionEnabled {
            manager.deviceMotionUpdateInterval = interval
            manager.startDeviceMotionUpdates(to: updateQueue) { motion, _ in
                guard let motion else { return }
                arrival.markArrived()
                continuation.yield(
                    SensorSample(
                        deviceTimestamp: motion.timestamp,
                        wallClockAnchor: anchor,
                        acceleration: Vector3(
                            x: motion.userAcceleration.x,
                            y: motion.userAcceleration.y,
                            z: motion.userAcceleration.z
                        ),
                        gravity: Vector3(x: motion.gravity.x, y: motion.gravity.y, z: motion.gravity.z)
                    )
                )
            }
        } else {
            manager.accelerometerUpdateInterval = interval
            manager.startAccelerometerUpdates(to: updateQueue) { data, _ in
                guard let data else { return }
                arrival.markArrived()
                continuation.yield(
                    SensorSample(
                        deviceTimestamp: data.timestamp,
                        wallClockAnchor: anchor,
                        acceleration: Vector3(
                            x: data.acceleration.x,
                            y: data.acceleration.y,
                            z: data.acceleration.z
                        ),
                        gravity: nil
                    )
                )
            }
        }

        try await confirmPriming(arrival: arrival)
        logService.log(.info, .motion, "motion updates started at \(policy.sampleRateHz) Hz")
        return stream
    }

    func stop() async {
        stopUpdates()
        logService.log(.info, .motion, "motion updates stopped")
    }

    // MARK: - Internals

    /// Waits for the first real sample, so `start` returning means the sensor is
    /// actually delivering — no silent failure (docs/07 §7.3).
    private func confirmPriming(arrival: SampleArrivalFlag) async throws {
        let deadline = ContinuousClock.now + primingBudget

        while !arrival.hasArrived {
            if ContinuousClock.now >= deadline {
                stopUpdates()
                logService.log(.error, .motion, "priming exceeded budget")
                throw StabilyzError.sensor(.primingTimeout)
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func stopUpdates() {
        manager.stopAccelerometerUpdates()
        manager.stopDeviceMotionUpdates()
        continuation?.finish()
        continuation = nil
    }

    /// Pure mapping, so the translation is testable without the framework.
    nonisolated static func mapAuthorization(_ status: CMAuthorizationStatus) -> MotionAuthorizationStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .notDetermined
        }
    }
}
