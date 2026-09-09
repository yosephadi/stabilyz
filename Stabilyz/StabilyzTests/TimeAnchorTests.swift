import Foundation
import Testing
@testable import Stabilyz

private struct StubClock: Clock {
    let now: Date
    let uptime: TimeInterval
}

private let wallClock = Date(timeIntervalSince1970: 1_700_000_000)

@Test func anchorConvertsDeviceTimestampsToWallClock() {
    // docs/07 §7.4: wall-clock time = anchor + (deviceTimestamp - anchorUptime).
    let anchor = TimeAnchor(wallClock: wallClock, uptime: 1_000)

    #expect(anchor.wallClockTime(forDeviceTimestamp: 1_000) == wallClock)
    #expect(anchor.wallClockTime(forDeviceTimestamp: 1_090) == wallClock.addingTimeInterval(90))
    // Timestamps before the anchor are representable, not clamped.
    #expect(anchor.wallClockTime(forDeviceTimestamp: 990) == wallClock.addingTimeInterval(-10))
}

@Test func elapsedComesFromTheMonotonicClock() {
    let anchor = TimeAnchor(wallClock: wallClock, uptime: 1_000)

    #expect(anchor.elapsed(atDeviceTimestamp: 1_090) == .seconds(90))
    #expect(anchor.elapsed(atDeviceTimestamp: 1_000) == .zero)
}

@Test func aWallClockChangeMidSessionDoesNotDistortSampleSpacing() {
    // The point of anchoring: if the system clock jumps, sample spacing is
    // still derived from uptime, so durations are unaffected (docs/07 §7.4).
    let anchor = TimeAnchor(wallClock: wallClock, uptime: 1_000)
    let shifted = TimeAnchor(wallClock: wallClock.addingTimeInterval(3_600), uptime: 1_000)

    let firstSpacing = anchor.elapsed(atDeviceTimestamp: 1_090)
    let shiftedSpacing = shifted.elapsed(atDeviceTimestamp: 1_090)
    #expect(firstSpacing == shiftedSpacing)

    // Only the wall-clock projection moves.
    #expect(shifted.wallClockTime(forDeviceTimestamp: 1_090) ==
            anchor.wallClockTime(forDeviceTimestamp: 1_090).addingTimeInterval(3_600))
}

@Test func anchorIsCapturedOnceFromTheClock() {
    let clock = StubClock(now: wallClock, uptime: 42)
    let anchor = TimeAnchor(clock: clock)

    #expect(anchor.wallClock == wallClock)
    #expect(anchor.uptime == 42)
}

@Test func pedometerEventsMapOntoTheSameDeviceTimeline() {
    // docs/07 §7.4: both streams share one timeline.
    let anchor = TimeAnchor(wallClock: wallClock, uptime: 1_000)

    #expect(anchor.deviceTimestamp(forWallClock: wallClock) == 1_000)
    #expect(anchor.deviceTimestamp(forWallClock: wallClock.addingTimeInterval(30)) == 1_030)

    // Round trip.
    let deviceTime = anchor.deviceTimestamp(forWallClock: wallClock.addingTimeInterval(12.5))
    #expect(anchor.wallClockTime(forDeviceTimestamp: deviceTime) == wallClock.addingTimeInterval(12.5))
}

@Test func samplesProjectTheirOwnWallClockTime() {
    let anchor = TimeAnchor(wallClock: wallClock, uptime: 1_000)
    let sample = SensorSample(
        deviceTimestamp: 1_045,
        anchor: anchor,
        acceleration: Vector3(x: 0, y: 0, z: 1)
    )

    #expect(sample.wallClockTime == wallClock.addingTimeInterval(45))
}
