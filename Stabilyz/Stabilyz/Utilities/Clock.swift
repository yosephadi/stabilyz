import Foundation

/// Wall-clock and monotonic uptime, injected so timestamps are deterministic in
/// tests (docs/12 §12.2).
///
/// docs/07 §7.4: `uptime` is the primary clock for all durations; `now` is only
/// used for the anchor captured once at session start. Durations are never
/// computed from `Date` arithmetic.
nonisolated protocol Clock: Sendable {
    var now: Date { get }
    /// Seconds since device boot, on the same timebase as `SensorSample.deviceTimestamp`.
    var uptime: TimeInterval { get }
}
