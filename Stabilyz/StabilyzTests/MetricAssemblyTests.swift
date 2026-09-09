import Foundation
import Testing
@testable import Stabilyz

private let config = AlgorithmConfiguration.v1
private let rate = config.preprocessing.targetSampleRateHz
private let anchor = TimeAnchor(wallClock: Date(timeIntervalSince1970: 1_700_000_000), uptime: 0)

private func pulse(phase: Double, width: Double) -> Double {
    phase < width ? sin(.pi * phase / width) : 0
}

/// Builds a walking signal with independent control of the two things that can
/// make a gait asymmetric.
///
/// - `firstHalf` / `secondHalf`: the durations of the two half-cycles. Unequal
///   values are **timing** asymmetry, which is what `stepTimeAsymmetry` measures.
/// - `firstAmplitude` / `secondAmplitude`: how hard each footfall lands. Unequal
///   values are **amplitude** asymmetry, which separates Ad1 from Ad2 but is a
///   different phenomenon.
/// - `mediolateralAlternates`: whether the trunk leans opposite ways on
///   consecutive footfalls. Without it, the two half-cycles are not
///   distinguishable limbs.
private func walkingSignal(
    seconds: Double,
    firstHalf: Double,
    secondHalf: Double,
    firstAmplitude: Double = 1.0,
    secondAmplitude: Double = 1.0,
    mediolateralAlternates: Bool = true,
    pulseWidth: Double = 0.12
) -> [SensorSample] {
    var footfalls: [(time: Double, amplitude: Double, lean: Double)] = []
    var t = 0.0
    var index = 0
    while t < seconds + firstHalf + secondHalf {
        let isFirst = index.isMultiple(of: 2)
        let lean = mediolateralAlternates ? (isFirst ? 1.0 : -1.0) : 1.0
        footfalls.append((t, isFirst ? firstAmplitude : secondAmplitude, lean))
        t += isFirst ? firstHalf : secondHalf
        index += 1
    }

    return (0..<Int(seconds * rate)).map { sampleIndex in
        let time = Double(sampleIndex) / rate
        var vertical = 0.0
        var mediolateral = 0.0
        for footfall in footfalls where time >= footfall.time && time < footfall.time + pulseWidth {
            let shape = pulse(phase: time - footfall.time, width: pulseWidth)
            vertical += footfall.amplitude * shape
            mediolateral += footfall.lean * 0.4 * shape
        }
        return SensorSample(
            deviceTimestamp: time,
            anchor: anchor,
            acceleration: Vector3(x: mediolateral, y: 0, z: -vertical),
            gravity: Vector3(x: 0, y: 0, z: -1)
        )
    }
}

private func pipeline(
    _ samples: [SensorSample],
    profile: UserProfile?,
    pedometer: [PedometerEvent] = []
) -> GaitMetrics? {
    let aligned = SampleIngestion.align(samples, sampleRateHz: rate, policy: config.gapDetection)
    let series = Preprocessing.process(aligned, configuration: config)
    let segmentation = WalkingSegmentDetector.detect(in: series, pedometerEvents: pedometer, configuration: config)
    let features = FeatureExtraction.extract(series: series, segmentation: segmentation, configuration: config)

    let buffer = RawSessionBuffer(
        mode: .quickTest, audioConfig: .none, anchor: anchor, series: aligned,
        pedometerEvents: pedometer, startedAt: anchor.wallClock,
        endedAt: anchor.wallClock.addingTimeInterval(120),
        advertisedClockElapsed: .seconds(120), interruptionCount: 0,
        pedometerAvailable: !pedometer.isEmpty
    )
    return MetricAssembly.assemble(
        features: features, segmentation: segmentation, buffer: buffer,
        profile: profile, configuration: config
    )
}

private func asymmetryResult(
    _ samples: [SensorSample],
    profile: UserProfile?
) -> MetricAssembly.AsymmetryResult {
    let aligned = SampleIngestion.align(samples, sampleRateHz: rate, policy: config.gapDetection)
    let series = Preprocessing.process(aligned, configuration: config)
    let segmentation = WalkingSegmentDetector.detect(in: series, configuration: config)
    let features = FeatureExtraction.extract(series: series, segmentation: segmentation, configuration: config)
    return MetricAssembly.stepTimeAsymmetry(
        windows: features.windows, profile: profile, configuration: config
    )
}

private let unilateral = UserProfile.fixture(level: .transtibial, side: .left)
private let bilateral = UserProfile.fixture(level: .bilateral, side: .both)

/// Unequal step durations, equal footfall amplitudes: timing asymmetry.
private func timingAsymmetricWalk(seconds: Double = 60, mediolateralAlternates: Bool = true) -> [SensorSample] {
    walkingSignal(
        seconds: seconds, firstHalf: 0.50, secondHalf: 0.60,
        mediolateralAlternates: mediolateralAlternates
    )
}

/// Equal step durations: symmetric timing.
private func symmetricWalk(seconds: Double = 60) -> [SensorSample] {
    walkingSignal(seconds: seconds, firstHalf: 0.55, secondHalf: 0.55)
}

/// The Task 5.2.4 fixture: unequal amplitudes, equal timing.
private func amplitudeAsymmetricWalk(seconds: Double = 60) -> [SensorSample] {
    walkingSignal(
        seconds: seconds, firstHalf: 0.55, secondHalf: 0.55,
        firstAmplitude: 1.0, secondAmplitude: 0.45
    )
}

// MARK: - The feature measures timing, not amplitude

@Test func unequalStepDurationsProduceNonzeroAsymmetry() {
    // 0.50 s and 0.60 s half-cycles: (0.60 - 0.50) / 1.10 ≈ 0.091.
    let metrics = try! #require(pipeline(timingAsymmetricWalk(), profile: unilateral))
    let asymmetry = try! #require(metrics.stepTimeAsymmetry)

    #expect(asymmetry > 0.03)
    #expect(abs(asymmetry - 0.091) < 0.05)
}

@Test func theAmplitudeAsymmetricFixtureMeasuresNearZero() {
    // Landing harder on one side is not step-time asymmetry. This fixture
    // separates Ad1 from Ad2 (Task 5.2.4) but its step durations are equal, so
    // the timing comparison is correctly ≈0 — a measurement, not an absence.
    let metrics = try! #require(pipeline(amplitudeAsymmetricWalk(), profile: unilateral))
    let asymmetry = try! #require(metrics.stepTimeAsymmetry)

    #expect(abs(asymmetry) < 0.03)
    // And the regularity metrics still see the amplitude difference, which is
    // what makes the two features genuinely distinct.
    #expect(metrics.strideRegularity > metrics.stepRegularity)
}

@Test func symmetricTimingIsAMeasuredZeroNotAnAbsence() {
    let result = asymmetryResult(symmetricWalk(), profile: unilateral)

    let value = try! #require(result.value)
    #expect(abs(value) < 0.03)
    #expect(result.unavailability == nil)
}

@Test func asymmetryIsNotDerivableFromTheRegularityMetrics() {
    // The two features must be independently meaningful [PRD OQ-1]. Both walks
    // show a regularity contrast — Ad2 above Ad1 — yet only the one with
    // unequal step durations reports asymmetry. If the index were arithmetic on
    // Ad1 and Ad2, as reading 1 made it, both would report the same sign of
    // result and this test could not separate them.
    let amplitude = try! #require(pipeline(amplitudeAsymmetricWalk(), profile: unilateral))
    let timing = try! #require(pipeline(timingAsymmetricWalk(), profile: unilateral))

    #expect(amplitude.strideRegularity > amplitude.stepRegularity)
    #expect(timing.strideRegularity > timing.stepRegularity)

    #expect(abs(amplitude.stepTimeAsymmetry ?? 1) < 0.03)
    #expect((timing.stepTimeAsymmetry ?? 0) > 0.03)
}

// MARK: - The fabrication trap [PRD §7, OQ-1]

@Test func bilateralUsersGetAbsentAsymmetryNeverZero() {
    let metrics = try! #require(pipeline(timingAsymmetricWalk(), profile: bilateral))

    #expect(metrics.stepTimeAsymmetry == nil)
    #expect(metrics.stepTimeAsymmetry != 0)
    #expect(metrics.value(for: .stepTimeAsymmetry) == nil)
    #expect(metrics.availableMetrics.contains(.stepTimeAsymmetry) == false)

    let result = asymmetryResult(timingAsymmetricWalk(), profile: bilateral)
    #expect(result.unavailability == .bilateralProfile)
}

@Test func aSessionWithNoProfileGetsAbsenceWithAReason() {
    let metrics = try! #require(pipeline(timingAsymmetricWalk(), profile: nil))

    #expect(metrics.stepTimeAsymmetry == nil)
    #expect(metrics.stepTimeAsymmetry != 0)

    let result = asymmetryResult(timingAsymmetricWalk(), profile: nil)
    #expect(result.unavailability == .noProfile)
}

@Test func timingAsymmetryWithoutAlternatingPolarityIsAbsentWithAReason() {
    // The step durations really are unequal, but the two half-cycles cannot be
    // told apart as limbs. Reporting a number would attribute a difference to
    // limbs that were never distinguished.
    let result = asymmetryResult(
        timingAsymmetricWalk(mediolateralAlternates: false),
        profile: unilateral
    )

    #expect(result.value == nil)
    #expect(result.value != 0)
    #expect(result.unavailability == .sideNotReliablyIdentifiable)
    // The side is still carried as context.
    #expect(result.side == .left)
}

@Test func aWalkWithoutProminentPeaksIsAbsentWithAReason() {
    let windows = [
        WindowFeatures(
            intervalIndex: 0, startTimestamp: 0, duration: .seconds(10),
            stepTimes: [0.55, 0.55], ad1: 0.05, ad2: 0.04,
            stepLag: 0.55, strideLag: 1.1,
            trunkRMSMediolateral: 0.2, trunkRMSVertical: 0.5,
            firstHalfStrideLag: nil, secondHalfStrideLag: nil,
            mediolateralPolarityAlternates: true
        )
    ]
    let result = MetricAssembly.stepTimeAsymmetry(
        windows: windows, profile: unilateral, configuration: config
    )

    #expect(result.value == nil)
    #expect(result.unavailability == .peaksNotProminent)
}

// MARK: - Sign convention and limb attribution

@Test func theIndexIsNonNegativeAndCarriesNoLimbAttribution() {
    // Longer minus shorter, so the value says how unequal the steps are, never
    // which limb is which (docs/decisions.md entry 13).
    let left = try! #require(
        pipeline(timingAsymmetricWalk(), profile: UserProfile.fixture(level: .transfemoral, side: .left))
    )
    let right = try! #require(
        pipeline(timingAsymmetricWalk(), profile: UserProfile.fixture(level: .transfemoral, side: .right))
    )

    #expect((left.stepTimeAsymmetry ?? -1) >= 0)
    // Identical measurement; only the context label differs.
    #expect(left.stepTimeAsymmetry == right.stepTimeAsymmetry)
    #expect(left.asymmetryAffectedSide == .left)
    #expect(right.asymmetryAffectedSide == .right)
}

// MARK: - Profile blindness everywhere else

@Test func theProfileChangesOnlyAsymmetryAndItsLabel() {
    let samples = timingAsymmetricWalk()
    let uni = try! #require(pipeline(samples, profile: unilateral))
    let bi = try! #require(pipeline(samples, profile: bilateral))

    #expect(uni.stepRegularity == bi.stepRegularity)
    #expect(uni.strideRegularity == bi.strideRegularity)
    #expect(uni.cadenceMean == bi.cadenceMean)
    #expect(uni.stepTimeCV == bi.stepTimeCV)
    #expect(uni.trunkMotionML == bi.trunkMotionML)
    #expect(uni.trunkMotionVT == bi.trunkMotionVT)
    #expect(uni.validStrideCount == bi.validStrideCount)

    #expect(uni.stepTimeAsymmetry != nil)
    #expect(bi.stepTimeAsymmetry == nil)
}

// MARK: - Aggregation into the docs/05 contract

@Test func knownSignalYieldsKnownMetrics() {
    // Two 0.55 s steps per stride is about 109 steps per minute.
    let metrics = try! #require(pipeline(symmetricWalk(), profile: unilateral))

    #expect(abs(metrics.cadenceMean - 109) < 8)
    #expect(metrics.stepRegularity > 0.5)
    #expect(metrics.strideRegularity > 0.5)
    #expect(metrics.validStrideCount >= config.quality.minimumValidStrides)
    #expect(metrics.windowCount > 1)
}

@Test func jitteredStepTimesRaiseTheVariabilityMetric() {
    let steady = try! #require(pipeline(symmetricWalk(), profile: unilateral))
    let uneven = try! #require(pipeline(timingAsymmetricWalk(), profile: unilateral))

    // Alternating 0.50/0.60 s steps are more variable than a steady 0.55 s.
    #expect(uneven.stepTimeCV > steady.stepTimeCV)
    #expect(steady.stepTimeCV >= 0)
}

@Test func pedometerDataIsCarriedAsContextOnly() {
    let samples = symmetricWalk()
    let events = [PedometerEvent(steps: 109, distance: 72, timestamp: anchor.wallClock.addingTimeInterval(60))]

    let withPedometer = try! #require(pipeline(samples, profile: unilateral, pedometer: events))
    let without = try! #require(pipeline(samples, profile: unilateral))

    #expect(withPedometer.steps == 109)
    #expect(withPedometer.distance == 72)
    #expect(without.steps == nil)
    #expect(withPedometer.stepRegularity == without.stepRegularity)
    #expect(withPedometer.cadenceMean == without.cadenceMean)
}

// MARK: - Provenance carries the entry-11 tripwire

@Test func observedLagsReachTheMetricLevel() {
    let metrics = try! #require(pipeline(symmetricWalk(), profile: unilateral))
    let step = try! #require(metrics.observedStepPeriod)
    let stride = try! #require(metrics.observedStrideLag)

    #expect(abs(step - 0.55) < 0.12)
    #expect(abs(stride - 1.1) < 0.2)
    #expect(stride / step > 1.7)
    #expect(stride / step < 2.3)
}

@Test func metricsRoundTripThroughCoding() throws {
    let metrics = try! #require(pipeline(timingAsymmetricWalk(), profile: unilateral))

    let data = try JSONEncoder().encode(metrics)
    let decoded = try JSONDecoder().decode(GaitMetrics.self, from: data)

    #expect(decoded == metrics)
    #expect(decoded.observedStepPeriod != nil)
    #expect(decoded.asymmetryAffectedSide == .left)
}

// MARK: - Nothing assembled from nothing

@Test func aStandingSessionAssemblesNoMetrics() {
    let still = (0..<Int(60 * rate)).map { index in
        SensorSample(
            deviceTimestamp: Double(index) / rate, anchor: anchor,
            acceleration: Vector3(x: 0, y: 0, z: -0.001),
            gravity: Vector3(x: 0, y: 0, z: -1)
        )
    }
    #expect(pipeline(still, profile: unilateral) == nil)
}

// MARK: - Aggregation statistics

@Test func medianAggregationResistsASingleOutlierWindow() {
    let steady = (0..<5).map { index in
        WindowFeatures(
            intervalIndex: 0, startTimestamp: Double(index) * 10, duration: .seconds(10),
            stepTimes: [0.55, 0.55, 0.55], ad1: 0.8, ad2: 0.8,
            stepLag: 0.55, strideLag: 1.1,
            trunkRMSMediolateral: 0.2, trunkRMSVertical: 0.5,
            firstHalfStrideLag: 0.55, secondHalfStrideLag: 0.55,
            mediolateralPolarityAlternates: true
        )
    }
    let outlier = WindowFeatures(
        intervalIndex: 0, startTimestamp: 50, duration: .seconds(10),
        stepTimes: [0.55, 0.55, 0.55], ad1: 0.05, ad2: 0.05,
        stepLag: 0.55, strideLag: 1.1,
        trunkRMSMediolateral: 4.0, trunkRMSVertical: 9.0,
        firstHalfStrideLag: 0.55, secondHalfStrideLag: 0.55,
        mediolateralPolarityAlternates: true
    )

    #expect(MetricAssembly.median((steady + [outlier]).map(\.ad1)) == 0.8)
    #expect(MetricAssembly.median((steady + [outlier]).map(\.trunkRMSVertical)) == 0.5)
}

@Test func aWindowWithTooFewStepsContributesNoVariability() {
    let single = WindowFeatures(
        intervalIndex: 0, startTimestamp: 0, duration: .seconds(10),
        stepTimes: [0.55], ad1: 0.8, ad2: 0.8,
        stepLag: 0.55, strideLag: 1.1,
        trunkRMSMediolateral: 0.2, trunkRMSVertical: 0.5,
        firstHalfStrideLag: 0.55, secondHalfStrideLag: 0.55,
        mediolateralPolarityAlternates: true
    )
    #expect(MetricAssembly.coefficientOfVariation(single) == nil)
}

// MARK: - Registry directions (entry 3)

@Test func onlyTheFourCompositeTermsCarryDirections() {
    let directions = config.metricDirections

    #expect(directions.direction(for: .stepRegularity) != nil)
    #expect(directions.direction(for: .strideRegularity) != nil)
    #expect(directions.direction(for: .stepTimeCV) != nil)
    #expect(directions.direction(for: .trunkMotionML) != nil)
    #expect(directions.direction(for: .trunkMotionVT) != nil)

    #expect(directions.direction(for: .cadenceMean) == nil)
    #expect(directions.direction(for: .stepTimeAsymmetry) == nil)
}
