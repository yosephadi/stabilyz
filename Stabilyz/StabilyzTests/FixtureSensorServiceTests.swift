import Foundation
import Testing
@testable import Stabilyz

private struct FixtureClock: Clock {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let uptime: TimeInterval = 500
}

// MARK: - File format

@Test func fixtureRoundTripsThroughItsFileFormat() throws {
    let fixture = GaitFixture.steadyWalk
    let decoded = try GaitFixture.decode(from: try fixture.encoded())

    #expect(decoded == fixture)
    #expect(decoded.metadata.formatVersion == GaitFixture.currentFormatVersion)
    #expect(decoded.metadata.cadenceBPM == 108)
}

@Test func aFutureFormatVersionIsRefusedRatherThanMisread() throws {
    let future = GaitFixture(
        metadata: .init(
            name: "future",
            formatVersion: GaitFixture.currentFormatVersion + 1,
            sampleRateHz: 100,
            deviceMotionIncluded: true
        ),
        samples: [.init(t: 0, ax: 0, ay: 0, az: 1)]
    )

    #expect(throws: GaitFixture.LoadError.unsupportedFormatVersion(GaitFixture.currentFormatVersion + 1)) {
        _ = try GaitFixture.decode(from: try future.encoded())
    }
}

@Test func anEmptyCaptureIsRejected() throws {
    let empty = GaitFixture(
        metadata: .init(name: "empty", sampleRateHz: 100, deviceMotionIncluded: false),
        samples: []
    )

    #expect(throws: GaitFixture.LoadError.empty) {
        _ = try GaitFixture.decode(from: try empty.encoded())
    }
}

@Test func capturesCarryTheKnownGaitParametersTheyRepresent() {
    // docs/07 §7.9: fixtures record cadence and SNR so tests assert against
    // what the capture is meant to be, not against magic numbers.
    let fixture = GaitFixture.makeWalk(name: "probe", cadenceBPM: 96, seconds: 1, noise: 0.02)

    #expect(fixture.metadata.cadenceBPM == 96)
    #expect(fixture.metadata.signalToNoiseRatio == 50)
    #expect(fixture.metadata.sampleRateHz == 100)
}

// MARK: - Gaps

@Test func gapsAreRepresentedByAbsentSamplesNotBySentinels() {
    let fixture = GaitFixture.walkWithSensorGap
    let timestamps = fixture.samples.map(\.t)

    // The capture spans four seconds but is missing the middle two.
    #expect(fixture.duration > 3.9)
    #expect(timestamps.contains { $0 < 1.0 })
    #expect(timestamps.contains { $0 > 3.0 })
    #expect(timestamps.contains { $0 > 1.0 && $0 < 3.0 } == false)

    // Duration comes from device timestamps, so the gap does not shorten it
    // (docs/07 §7.4).
    let expectedIfNoGap = Double(fixture.samples.count) / fixture.metadata.sampleRateHz
    #expect(fixture.duration > expectedIfNoGap)
}

// MARK: - Replay

@Test func replayEmitsEverySampleInOrder() async throws {
    let fixture = GaitFixture.makeWalk(name: "replay", cadenceBPM: 108, seconds: 1)
    let service = FixtureSensorService(fixture: fixture, clock: FixtureClock())

    var received: [SensorSample] = []
    for await sample in try await service.start(policy: .recommendedDefault) {
        received.append(sample)
    }

    #expect(received.count == fixture.samples.count)
    #expect(received.map(\.deviceTimestamp) == fixture.samples.map(\.t))
    #expect(zip(received, received.dropFirst()).allSatisfy { $0.deviceTimestamp < $1.deviceTimestamp })
}

@Test func replayedSamplesShareOneStartAnchor() async throws {
    // docs/07 §7.4: one anchor per session, captured at start.
    let clock = FixtureClock()
    let service = FixtureSensorService(fixture: .steadyWalk, clock: clock)

    var anchors: Set<Date> = []
    for await sample in try await service.start(policy: .recommendedDefault) {
        anchors.insert(sample.wallClockAnchor)
    }

    #expect(anchors == [clock.now])
}

@Test func replayPreservesTheGapAsATimestampJump() async throws {
    let service = FixtureSensorService(fixture: .walkWithSensorGap, clock: FixtureClock())

    var timestamps: [TimeInterval] = []
    for await sample in try await service.start(policy: .recommendedDefault) {
        timestamps.append(sample.deviceTimestamp)
    }

    let largestStep = zip(timestamps, timestamps.dropFirst()).map { $1 - $0 }.max() ?? 0
    // The gap survives replay, so the recorder's gap detection sees it.
    #expect(largestStep > 1.9)
}

@Test func fixtureServiceIsAlwaysAvailableSoSuccessPathsAreTestable() async {
    let service = FixtureSensorService(fixture: .steadyWalk, clock: FixtureClock())

    #expect(await service.isAvailable)
    #expect(await service.authorizationStatus == .authorized)
}

@Test func anEmptyFixtureRefusesToStart() async {
    let empty = GaitFixture(
        metadata: .init(name: "empty", sampleRateHz: 100, deviceMotionIncluded: false),
        samples: []
    )
    let service = FixtureSensorService(fixture: empty, clock: FixtureClock())

    await #expect(throws: StabilyzError.sensor(.unavailable)) {
        _ = try await service.start(policy: .recommendedDefault)
    }
}

@Test func deviceMotionCapturesCarryGravity() async throws {
    let service = FixtureSensorService(fixture: .steadyWalk, clock: FixtureClock())

    var sawGravity = false
    for await sample in try await service.start(policy: .recommendedDefault) {
        if sample.gravity != nil { sawGravity = true }
    }
    #expect(sawGravity)
}

// MARK: - Scripted pedometer

@Test func scriptedPedometerReplaysItsEvents() async throws {
    let fixture = GaitFixture.makeWalk(name: "ped", cadenceBPM: 120, seconds: 3)
    let service = FixturePedometerService(fixture: fixture, clock: FixtureClock())

    var events: [PedometerEvent] = []
    for await event in try await service.start() {
        events.append(event)
    }

    #expect(events.count == fixture.pedometerScript.count)
    #expect(events.map(\.steps) == fixture.pedometerScript.map(\.steps))
    // 120 steps/min is 2 steps/sec.
    #expect(events.first?.cadence == 2)
}

@Test func scriptedPedometerAnswersTheGapContinuityQuery() async throws {
    let fixture = GaitFixture.makeWalk(name: "ped", cadenceBPM: 120, seconds: 3)
    let clock = FixtureClock()
    let service = FixturePedometerService(fixture: fixture, clock: clock)

    let inWindow = try await service.events(
        from: clock.now,
        to: clock.now.addingTimeInterval(2.5)
    )
    #expect(inWindow?.steps == 4)

    let outside = try await service.events(
        from: clock.now.addingTimeInterval(60),
        to: clock.now.addingTimeInterval(120)
    )
    #expect(outside == nil)
}
