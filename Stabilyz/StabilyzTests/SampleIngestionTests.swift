import Foundation
import Testing
@testable import Stabilyz

private let anchor = TimeAnchor(wallClock: Date(timeIntervalSince1970: 1_700_000_000), uptime: 0)

private func sample(_ t: TimeInterval) -> SensorSample {
    SensorSample(deviceTimestamp: t, anchor: anchor, acceleration: Vector3(x: 0, y: 0, z: 1))
}

/// 100 Hz samples from `from` to `to`, exclusive of `to`.
private func run(from start: TimeInterval, to end: TimeInterval, rate: Double = 100) -> [SensorSample] {
    var samples: [SensorSample] = []
    var t = start
    while t < end - 1e-9 {
        samples.append(sample(t))
        t += 1 / rate
    }
    return samples
}

// MARK: - Ordering and de-duplication (docs/08 stage 1)

@Test func samplesAreOrderedByDeviceTimestamp() {
    let series = SampleIngestion.align([sample(0.3), sample(0.1), sample(0.2)], sampleRateHz: 10)

    #expect(series.samples.map(\.deviceTimestamp) == [0.1, 0.2, 0.3])
}

@Test func repeatedTimestampsAreTreatedAsRedeliveryNotAsMeasurements() {
    let series = SampleIngestion.align([sample(0.1), sample(0.1), sample(0.2)], sampleRateHz: 10)

    #expect(series.samples.count == 2)
    #expect(series.samples.map(\.deviceTimestamp) == [0.1, 0.2])
}

@Test func anEmptySeriesProducesNoGapsRatherThanFailing() {
    // docs/08 stage 1 maps an empty buffer to invalid sensorFailure, which is
    // the pipeline's call; ingestion itself just reports emptiness.
    let series = SampleIngestion.align([], sampleRateHz: 100)

    #expect(series.samples.isEmpty)
    #expect(series.gaps.isEmpty)
    #expect(series.recordedSpan == .zero)
    #expect(series.gapInfo == .none)
}

// MARK: - Gap detection

@Test func normalJitterIsNotReportedAsAGap() {
    // Spacing under the tolerance is ordinary scheduling noise.
    let samples = [sample(0), sample(0.010), sample(0.021), sample(0.029)]
    let series = SampleIngestion.align(samples, sampleRateHz: 100)

    #expect(series.gaps.isEmpty)
    #expect(series.gapInfo.gapCount == 0)
}

@Test func aSuspensionIsDetectedAsOneGap() {
    // docs/07 §7.7: a suspension delivers nothing, leaving a timestamp jump.
    let samples = run(from: 0, to: 1) + run(from: 3, to: 4)
    let series = SampleIngestion.align(samples, sampleRateHz: 100)

    #expect(series.gaps.count == 1)
    let gap = try! #require(series.gaps.first)
    #expect(abs(gap.start - 0.99) < 0.01)
    #expect(gap.end == 3)
    #expect(gap.duration > .seconds(2))
}

@Test func multipleGapsAreReportedIndependently() {
    let samples = run(from: 0, to: 1) + run(from: 2, to: 3) + run(from: 6, to: 7)
    let series = SampleIngestion.align(samples, sampleRateHz: 100)

    #expect(series.gaps.count == 2)
    #expect(series.gapInfo.gapCount == 2)
    // The longest gap is the second one, ~3 s.
    #expect(series.gapInfo.longestGapDuration > .seconds(2.9))
    #expect(series.gapInfo.totalGapDuration > .seconds(3.9))
}

@Test func gapThresholdScalesWithSampleRate() {
    // The same absolute jump is a gap at 100 Hz and ordinary spacing at 10 Hz.
    let jump = [sample(0), sample(0.05)]

    #expect(SampleIngestion.align(jump, sampleRateHz: 100).gaps.count == 1)
    #expect(SampleIngestion.align(jump, sampleRateHz: 10).gaps.isEmpty)

    #expect(GapDetectionPolicy.recommendedDefault.gapThreshold(sampleRateHz: 100) == 0.03)
    #expect(GapDetectionPolicy.recommendedDefault.gapThreshold(sampleRateHz: 50) == 0.06)
}

@Test func aStricterPolicyDetectsMoreGapsWithoutChangingTheData() {
    // The threshold is tunable and moves into AlgorithmConfiguration in 5.1.2.
    let samples = [sample(0), sample(0.015), sample(0.030)]

    let lenient = SampleIngestion.align(samples, sampleRateHz: 100, policy: .recommendedDefault)
    let strict = SampleIngestion.align(
        samples,
        sampleRateHz: 100,
        policy: GapDetectionPolicy(toleranceMultiplier: 1.2)
    )

    #expect(lenient.gaps.isEmpty)
    #expect(strict.gaps.count == 2)
    #expect(lenient.samples == strict.samples)
}

// MARK: - Durations

@Test func gapTimeIsExcludedFromCoveredDurationButNotFromTheSpan() {
    // Elapsed clock time and time the sensor was delivering are different
    // quantities, and neither is "valid walking" — stages 3 and 4 decide that.
    let samples = run(from: 0, to: 1) + run(from: 3, to: 4)
    let series = SampleIngestion.align(samples, sampleRateHz: 100)

    #expect(series.recordedSpan > .seconds(3.9))
    #expect(series.coveredDuration < .seconds(2.1))
    #expect(series.coveredDuration > .seconds(1.9))
}

@Test func gapsAreNotInterpolatedAway() {
    // [PRD §6] a suspended session must never look like clean walking.
    let before = run(from: 0, to: 1)
    let after = run(from: 3, to: 4)
    let series = SampleIngestion.align(before + after, sampleRateHz: 100)

    // No samples were manufactured to bridge the gap.
    #expect(series.samples.count == before.count + after.count)
    #expect(series.samples.contains { $0.deviceTimestamp > 1.1 && $0.deviceTimestamp < 2.9 } == false)
}

// MARK: - Fixture integration

@Test func theScriptedGapFixtureIsDetected() async throws {
    // The Task 4.1.3 fixture exists precisely to drive this.
    let clock = StubIngestionClock()
    let service = FixtureSensorService(fixture: .walkWithSensorGap, clock: clock)

    var samples: [SensorSample] = []
    for await sample in try await service.start(policy: .recommendedDefault) {
        samples.append(sample)
    }

    let series = SampleIngestion.align(samples, sampleRateHz: 100)
    #expect(series.gaps.count == 1)
    #expect(series.gapInfo.longestGapDuration > .seconds(1.9))
}

private struct StubIngestionClock: Clock {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let uptime: TimeInterval = 0
}

// MARK: - Pedometer alignment

@Test func pedometerEventsAreSortedOntoTheDeviceTimeline() {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let events = [
        PedometerEvent(steps: 30, timestamp: base.addingTimeInterval(30)),
        PedometerEvent(steps: 10, timestamp: base.addingTimeInterval(10))
    ]

    let aligned = SampleIngestion.deviceTimestamps(for: events, anchor: anchor)

    #expect(aligned.map(\.deviceTimestamp) == [10, 30])
    #expect(aligned.map(\.event.steps) == [10, 30])
}
