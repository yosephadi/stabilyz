import Foundation

/// Production `Clock`: system wall-clock plus monotonic device uptime.
///
/// `uptime` uses `ProcessInfo.systemUptime`, the same timebase as
/// `CMLogItem.timestamp`, so it lines up with `SensorSample.deviceTimestamp`
/// (docs/07-motion-sensor-architecture.md §7.4).
struct SystemClock: Clock {
    var now: Date { Date() }
    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init() {}
}
