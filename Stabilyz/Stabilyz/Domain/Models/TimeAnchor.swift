import Foundation

/// The single time reference captured once at session start (docs/07 §7.4).
///
/// CoreMotion timestamps are device uptime: monotonic and gap-revealing, but
/// meaningless as calendar time. Pairing one uptime reading with one `Date`
/// lets every sample be placed on the wall clock without ever doing `Date`
/// arithmetic per sample.
///
/// This survives a wall-clock change mid-session — if the user crosses a time
/// zone or NTP corrects the clock, sample spacing is unaffected because it is
/// derived from uptime alone. **All durations come from device timestamps,
/// never from `Date` subtraction** [REC — docs/07 §7.4].
struct TimeAnchor: Sendable, Hashable, Codable {
    /// Wall clock at the moment of capture.
    let wallClock: Date
    /// Device uptime at that same moment, on the CoreMotion timebase.
    let uptime: TimeInterval

    init(wallClock: Date, uptime: TimeInterval) {
        self.wallClock = wallClock
        self.uptime = uptime
    }

    /// Captures the pair. Taken once, at start.
    init(clock: Clock) {
        self.init(wallClock: clock.now, uptime: clock.uptime)
    }

    /// Wall-clock time for a CoreMotion device timestamp.
    func wallClockTime(forDeviceTimestamp deviceTimestamp: TimeInterval) -> Date {
        wallClock.addingTimeInterval(deviceTimestamp - uptime)
    }

    /// Elapsed time since the anchor, from the monotonic clock.
    func elapsed(atDeviceTimestamp deviceTimestamp: TimeInterval) -> Duration {
        .seconds(deviceTimestamp - uptime)
    }

    /// Places a pedometer event on the device timebase, so pedometer and
    /// accelerometer data share one timeline (docs/07 §7.4).
    func deviceTimestamp(forWallClock date: Date) -> TimeInterval {
        uptime + date.timeIntervalSince(wallClock)
    }
}
