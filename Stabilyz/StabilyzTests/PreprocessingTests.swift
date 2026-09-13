import Foundation
import Testing
@testable import Stabilyz

private let config = AlgorithmConfiguration.v1
private let rate = config.preprocessing.targetSampleRateHz
private let anchor = TimeAnchor(wallClock: Date(timeIntervalSince1970: 1_700_000_000), uptime: 0)

/// Root-mean-square, the amplitude measure used throughout these assertions.
private func rms(_ signal: [Double]) -> Double {
    guard !signal.isEmpty else { return 0 }
    return (signal.reduce(0) { $0 + $1 * $1 } / Double(signal.count)).squareRoot()
}

/// Builds a capture whose acceleration is `signal(t)` along `axis`, with
/// gravity along -Z so the vertical axis is known.
private func capture(
    seconds: Double,
    sampleRateHz: Double = 100,
    gravity: Vector3? = Vector3(x: 0, y: 0, z: -1),
    startTime: TimeInterval = 0,
    signal: (Double) -> Vector3
) -> [SensorSample] {
    let count = Int(seconds * sampleRateHz)
    return (0..<count).map { index in
        let t = Double(index) / sampleRateHz
        return SensorSample(
            deviceTimestamp: startTime + t,
            anchor: anchor,
            acceleration: signal(t),
            gravity: gravity
        )
    }
}

private func aligned(_ samples: [SensorSample]) -> AlignedSampleSeries {
    SampleIngestion.align(samples, sampleRateHz: 100, policy: config.gapDetection)
}

private func preprocess(_ samples: [SensorSample]) -> PreprocessedSeries {
    Preprocessing.process(aligned(samples), configuration: config)
}

// MARK: - Filtering: known frequencies in, known amplitudes out

@Test func aWalkingFrequencySinusoidPassesThroughLargelyIntact() {
    // 1.8 Hz is a brisk cadence and sits inside the 0.5-20 Hz band.
    let samples = capture(seconds: 8) { t in
        Vector3(x: 0, y: 0, z: -sin(2 * .pi * 1.8 * t))
    }
    let series = preprocess(samples)
    let segment = try! #require(series.segments.first)

    // Amplitude 1 ⇒ RMS 1/√2 ≈ 0.707. Allow for filter roll-off and edges.
    #expect(rms(segment.vertical) > 0.6)
    #expect(rms(segment.vertical) < 0.75)
}

@Test func driftBelowTheHighPassIsRemoved() {
    // A slow 0.05 Hz sway plus a real 1.8 Hz stride: only the stride survives.
    let samples = capture(seconds: 8) { t in
        Vector3(x: 0, y: 0, z: -(sin(2 * .pi * 1.8 * t) + 3 * sin(2 * .pi * 0.05 * t)))
    }
    let series = preprocess(samples)
    let segment = try! #require(series.segments.first)

    // Without high-passing, the 3× drift would dominate the RMS.
    #expect(rms(segment.vertical) < 1.0)
    #expect(rms(segment.vertical) > 0.5)
}

@Test func aConstantOffsetIsRemoved() {
    // A DC offset carries no gait information and would bias every metric.
    let samples = capture(seconds: 6) { t in
        Vector3(x: 0, y: 0, z: -(5.0 + sin(2 * .pi * 1.8 * t)))
    }
    let series = preprocess(samples)
    let segment = try! #require(series.segments.first)

    let mean = segment.vertical.reduce(0, +) / Double(segment.count)
    #expect(abs(mean) < 0.05)
}

@Test func highFrequencyNoiseIsAttenuated() {
    // 40 Hz is well above the 20 Hz cutoff.
    let clean = capture(seconds: 6) { t in
        Vector3(x: 0, y: 0, z: -sin(2 * .pi * 1.8 * t))
    }
    let noisy = capture(seconds: 6) { t in
        Vector3(x: 0, y: 0, z: -(sin(2 * .pi * 1.8 * t) + 0.8 * sin(2 * .pi * 40 * t)))
    }

    let cleanRMS = rms(try! #require(preprocess(clean).segments.first).vertical)
    let noisyRMS = rms(try! #require(preprocess(noisy).segments.first).vertical)

    // The 40 Hz component contributes almost nothing after filtering.
    #expect(abs(noisyRMS - cleanRMS) < 0.1)
}

@Test func zeroPhaseFilteringLeavesPeaksWhereTheyHappened() {
    // Step times are measured off this signal, so a peak must not move.
    let period = 1.0 / 1.8
    let samples = capture(seconds: 8) { t in
        Vector3(x: 0, y: 0, z: -sin(2 * .pi * 1.8 * t))
    }
    let segment = try! #require(preprocess(samples).segments.first)

    // The first interior maximum should sit near the first peak of the input,
    // at a quarter period, not shifted by a filter delay.
    let searchWindow = Array(segment.vertical.prefix(Int(rate * period * 1.5)))
    let peakIndex = searchWindow.indices.dropFirst(10).max { searchWindow[$0] < searchWindow[$1] } ?? 0
    let peakTime = Double(peakIndex) / rate

    #expect(abs(peakTime - period / 4) < 0.03)
}

// MARK: - Resampling

@Test func irregularSamplingIsPlacedOnAUniformGrid() {
    // Real delivery jitters; every later stage assumes a fixed rate.
    var samples: [SensorSample] = []
    var t = 0.0
    var index = 0
    while t < 6 {
        samples.append(
            SensorSample(
                deviceTimestamp: t,
                anchor: anchor,
                acceleration: Vector3(x: 0, y: 0, z: -sin(2 * .pi * 1.8 * t)),
                gravity: Vector3(x: 0, y: 0, z: -1)
            )
        )
        // Jitter between 8 and 12 ms.
        t += 0.008 + 0.004 * Double(index % 2)
        index += 1
    }

    let segment = try! #require(preprocess(samples).segments.first)

    #expect(segment.sampleRateHz == rate)
    // Uniform grid: timestamps are exactly one step apart.
    #expect(abs(segment.timestamp(at: 1) - segment.timestamp(at: 0) - 1 / rate) < 1e-9)
    // The signal survives resampling.
    #expect(rms(segment.vertical) > 0.6)
}

@Test func aSlowerCaptureIsResampledUpToTheTargetRate() {
    let samples = capture(seconds: 6, sampleRateHz: 50) { t in
        Vector3(x: 0, y: 0, z: -sin(2 * .pi * 1.8 * t))
    }
    let segment = try! #require(preprocess(samples).segments.first)

    #expect(segment.sampleRateHz == rate)
    // Roughly 6 seconds at the target rate, not at the capture rate.
    #expect(segment.count > 550)
    #expect(rms(segment.vertical) > 0.6)
}

// MARK: - Gaps are never bridged

@Test func aDropoutSplitsTheSeriesRatherThanBeingInterpolatedAcross() {
    // [PRD §6] a suspended session must never look like continuous walking.
    let before = capture(seconds: 4) { t in Vector3(x: 0, y: 0, z: -sin(2 * .pi * 1.8 * t)) }
    let after = capture(seconds: 4, startTime: 7) { t in Vector3(x: 0, y: 0, z: -sin(2 * .pi * 1.8 * t)) }

    let series = preprocess(before + after)

    #expect(series.segments.count == 2)
    // Neither segment spans the missing three seconds.
    for segment in series.segments {
        #expect(segment.duration < .seconds(5))
    }
    // Total clean signal excludes the gap.
    #expect(series.totalDuration < .seconds(9))
    #expect(series.totalDuration > .seconds(7))
}

@Test func fragmentsTooShortToBeUsefulAreDiscardedAndCounted() {
    // A sliver between two dropouts carries no gait and only adds filter edges.
    let long = capture(seconds: 5) { t in Vector3(x: 0, y: 0, z: -sin(2 * .pi * 1.8 * t)) }
    let sliver = capture(seconds: 0.5, startTime: 20) { t in Vector3(x: 0, y: 0, z: -sin(2 * .pi * 1.8 * t)) }

    let series = preprocess(long + sliver)

    #expect(series.segments.count == 1)
    #expect(series.discardedSegmentCount == 1)
}

// MARK: - Orientation (docs/08 §8.2)

@Test func verticalIsTakenFromGravityRatherThanAnAssumedAxis() {
    // Gravity along +X: vertical must follow it, not a hardcoded Z.
    let samples = capture(seconds: 6, gravity: Vector3(x: 1, y: 0, z: 0)) { t in
        Vector3(x: sin(2 * .pi * 1.8 * t), y: 0, z: 0)
    }
    let series = preprocess(samples)

    #expect(abs(series.verticalAxis.x - 1) < 0.01)
    #expect(abs(series.verticalAxis.z) < 0.01)
    // The stride signal lands on the vertical channel.
    #expect(rms(try! #require(series.segments.first).vertical) > 0.6)
}

@Test func aTiltedPhoneStillProjectsOntoTheGravityDirection() {
    // No fixed phone placement is assumed [docs/08 §8.2].
    let tilt = Vector3(x: 0, y: 0.6, z: -0.8)
    let samples = capture(seconds: 6, gravity: tilt) { t in
        let amplitude = sin(2 * .pi * 1.8 * t)
        return Vector3(x: 0, y: amplitude * 0.6, z: amplitude * -0.8)
    }
    let series = preprocess(samples)
    let segment = try! #require(series.segments.first)

    // The signal is along gravity, so it belongs to vertical, not the
    // horizontal channels.
    #expect(rms(segment.vertical) > 0.6)
    #expect(rms(segment.mediolateral) < 0.1)
}

@Test func mediolateralIsTheDominantHorizontalVarianceDirection() {
    // Sway along +X, a smaller surge along +Y, gravity along -Z.
    let samples = capture(seconds: 8) { t in
        Vector3(
            x: 0.9 * sin(2 * .pi * 0.9 * t),
            y: 0.2 * sin(2 * .pi * 1.8 * t),
            z: 0
        )
    }
    let series = preprocess(samples)
    let segment = try! #require(series.segments.first)

    // The dominant direction is X, so ML should align with it.
    #expect(abs(abs(series.mediolateralAxis.x) - 1) < 0.05)
    #expect(rms(segment.mediolateral) > rms(segment.anteroposterior))
}

@Test func axesAreMutuallyPerpendicularUnitVectors() {
    let samples = capture(seconds: 6) { t in
        Vector3(x: 0.5 * sin(2 * .pi * 0.9 * t), y: 0.2 * cos(2 * .pi * 1.8 * t), z: -sin(2 * .pi * 1.8 * t))
    }
    let series = preprocess(samples)

    func length(_ v: Vector3) -> Double { (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot() }
    func dot(_ a: Vector3, _ b: Vector3) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }

    #expect(abs(length(series.verticalAxis) - 1) < 1e-6)
    #expect(abs(length(series.mediolateralAxis) - 1) < 1e-6)
    #expect(abs(dot(series.verticalAxis, series.mediolateralAxis)) < 1e-6)
}

@Test func aCaptureWithoutGravityStillFindsVertical() {
    // Accelerometer-only captures carry gravity inside the acceleration, so it
    // is recovered from the low-frequency content instead.
    let samples = capture(seconds: 6, gravity: nil) { t in
        Vector3(x: 0, y: 0, z: -(1.0 + 0.3 * sin(2 * .pi * 1.8 * t)))
    }
    let series = preprocess(samples)

    #expect(abs(abs(series.verticalAxis.z) - 1) < 0.05)
    #expect(series.segments.isEmpty == false)
}

// MARK: - Edge cases

@Test func anEmptySeriesProducesNoSegments() {
    let series = Preprocessing.process(
        SampleIngestion.align([], sampleRateHz: 100, policy: config.gapDetection),
        configuration: config
    )

    #expect(series.isEmpty)
    #expect(series.totalDuration == .zero)
}

@Test func aCaptureShorterThanTheMinimumYieldsNothing() {
    let samples = capture(seconds: 1) { t in Vector3(x: 0, y: 0, z: -sin(2 * .pi * 1.8 * t)) }
    let series = preprocess(samples)

    #expect(series.isEmpty)
    #expect(series.discardedSegmentCount == 1)
}

@Test func segmentTimestampsStayOnTheSessionTimeline() {
    // Findings have to be placeable back against the gap record and pedometer.
    let samples = capture(seconds: 5, startTime: 1_234) { t in
        Vector3(x: 0, y: 0, z: -sin(2 * .pi * 1.8 * t))
    }
    let segment = try! #require(preprocess(samples).segments.first)

    #expect(abs(segment.startTimestamp - 1_234) < 1e-9)
    #expect(abs(segment.timestamp(at: Int(rate)) - 1_235) < 1e-6)
}

// MARK: - Lead-in trimming

@Test func theFirstThreeSecondsAreDropped() {
    // The walk begins at T-0; the user does not. The first seconds carry the
    // phone going into a pocket and a first step from standing, none of it gait.
    let samples = capture(seconds: 20) { t in
        Vector3(x: 0, y: 0, z: -1 + 0.4 * sin(2 * .pi * 1.8 * t))
    }
    let trimmed = SessionLeadIn.trimmed(aligned(samples), configuration: config)

    #expect(config.preprocessing.leadInTrim == .seconds(3))
    // 100 Hz for 3s.
    #expect(trimmed.samples.count == samples.count - 300)
    #expect(trimmed.samples.first?.deviceTimestamp == 3)
}

@Test func nothingIsTrimmedFromTheEnd() {
    // Stop is a deliberate act and the user is walking right up to it. Trimming
    // there would discard real gait to guard against an artefact that is not
    // symmetric with the start.
    let samples = capture(seconds: 20) { _ in Vector3(x: 0, y: 0, z: -1) }
    let trimmed = SessionLeadIn.trimmed(aligned(samples), configuration: config)

    #expect(trimmed.samples.last?.deviceTimestamp == samples.last?.deviceTimestamp)
}

@Test func theTrimIsMeasuredFromTheFirstSampleNotFromZero() {
    // A recorder whose first sample lands late must still lose three seconds of
    // signal, not three seconds of clock.
    let samples = capture(seconds: 20, startTime: 812.5) { _ in Vector3(x: 0, y: 0, z: -1) }
    let trimmed = SessionLeadIn.trimmed(aligned(samples), configuration: config)

    #expect(trimmed.samples.first?.deviceTimestamp == 815.5)
    #expect(trimmed.samples.count == samples.count - 300)
}

@Test func aRecordingShorterThanTheTrimSurvivesAsEmpty() {
    // It becomes the too-short session it already was; the quality stage gives
    // the reason rather than this stage inventing one.
    let samples = capture(seconds: 2) { _ in Vector3(x: 0, y: 0, z: -1) }
    let trimmed = SessionLeadIn.trimmed(aligned(samples), configuration: config)

    #expect(trimmed.samples.isEmpty)
}

@Test func theTrimReachesTheRealPipeline() async throws {
    // Asserted through the pipeline, not just the helper: a trim that was
    // written and never wired in would pass every test above.
    let samples = capture(seconds: 20) { t in
        Vector3(x: 0, y: 0, z: -1 + 0.4 * sin(2 * .pi * 1.8 * t))
    }
    let untrimmed = preprocess(samples)
    let trimmed = Preprocessing.process(
        SessionLeadIn.trimmed(aligned(samples), configuration: config),
        configuration: config
    )

    #expect(untrimmed.segments.first?.startTimestamp == 0)
    #expect(trimmed.segments.first?.startTimestamp == 3)
    // The tail is intact: exactly the lead-in was lost, and nothing else.
    #expect(untrimmed.totalDuration - trimmed.totalDuration == .seconds(3))
}

@Test func theLeadInArtefactDoesNotReachTheAnalysedSignal() {
    // A violent first two seconds — the phone being pocketed — followed by
    // steady walking. What survives must look like the walking.
    let samples = capture(seconds: 20) { t in
        let gait = 0.3 * sin(2 * .pi * 1.8 * t)
        let insertion = t < 2 ? 6.0 * sin(2 * .pi * 11 * t) : 0
        return Vector3(x: 0, y: 0, z: -1 + gait + insertion)
    }
    let series = Preprocessing.process(
        SessionLeadIn.trimmed(aligned(samples), configuration: config),
        configuration: config
    )
    let vertical = series.segments.flatMap(\.vertical)

    let clean = preprocess(capture(seconds: 20) { t in
        Vector3(x: 0, y: 0, z: -1 + 0.3 * sin(2 * .pi * 1.8 * t))
    }).segments.flatMap(\.vertical)

    // Within a factor of two of the same walk recorded without the artefact.
    // Untrimmed, the 6g burst dominates the amplitude outright.
    #expect(rms(vertical) < rms(clean) * 2)
}
