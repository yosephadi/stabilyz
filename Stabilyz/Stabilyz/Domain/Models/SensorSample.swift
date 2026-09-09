import Foundation

/// A 3-axis reading. Used for both acceleration and gravity components.
struct Vector3: Sendable, Equatable {
    let x: Double
    let y: Double
    let z: Double

    init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// One accelerometer (and optionally device-motion) sample, converted from the
/// CoreMotion type at the service boundary (docs/03 boundary rule 4).
///
/// See docs/07-motion-sensor-architecture.md §7.2 and §7.4: `deviceTimestamp` is
/// device uptime in seconds and is the primary, monotonic, gap-revealing clock.
/// `wallClockAnchor` is the `Date` captured once at session start, so every
/// sample's wall-clock time is `wallClockAnchor + (deviceTimestamp - anchorUptime)`.
struct SensorSample: Sendable, Equatable {
    let deviceTimestamp: TimeInterval
    let wallClockAnchor: Date
    let acceleration: Vector3
    /// Non-nil only when device-motion updates are enabled by the acquisition policy.
    let gravity: Vector3?

    init(deviceTimestamp: TimeInterval, wallClockAnchor: Date, acceleration: Vector3, gravity: Vector3? = nil) {
        self.deviceTimestamp = deviceTimestamp
        self.wallClockAnchor = wallClockAnchor
        self.acceleration = acceleration
        self.gravity = gravity
    }
}

/// One pedometer update, mapped onto the same timeline as `SensorSample`
/// (docs/07 §7.2, §7.4). `distance` is carried for the context/reference metrics
/// in docs/05 §5.1.
struct PedometerEvent: Sendable, Equatable {
    let steps: Int
    /// Steps per second, as reported by the platform. Nil when unavailable.
    let cadence: Double?
    /// Seconds per meter, as reported by the platform. Nil when unavailable.
    let pace: Double?
    /// Meters. Nil when unavailable.
    let distance: Double?
    let timestamp: Date

    init(steps: Int, cadence: Double? = nil, pace: Double? = nil, distance: Double? = nil, timestamp: Date) {
        self.steps = steps
        self.cadence = cadence
        self.pace = pace
        self.distance = distance
        self.timestamp = timestamp
    }
}
