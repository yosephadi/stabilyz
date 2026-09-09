import Foundation
import Testing
@testable import Stabilyz

private let config = AlgorithmConfiguration.v1
private let rate = config.preprocessing.targetSampleRateHz
private let anchor = TimeAnchor(wallClock: Date(timeIntervalSince1970: 1_700_000_000), uptime: 0)

private func pulse(phase: Double, width: Double) -> Double {
    phase < width ? sin(.pi * phase / width) : 0
}

/// The same signal generator as the 5.2.4 tests, so the asymmetric fixture that
/// separated Ad1 from Ad2 is the one exercised here.
private func walkingSignal(
    seconds: Double,
    strideSeconds: Double,
    firstAmplitude: Double = 1.0,
    secondAmplitude: Double = 1.0,
    stepJitter: Double = 0,
    pulseWidth: Double = 0.12
) -> [SensorSample] {
    let count = Int(seconds * rate)
    var footfalls: [(time: Double, amplitude: Double)] = []
    var strideStart = 0.0
    var index = 0
    while strideStart < seconds + strideSeconds {
        let wobble = stepJitter * ((index % 3 == 0) ? 1.0 : (index % 3 == 1 ? -1.0 : 0.4))
        footfalls.append((strideStart, firstAmplitude))
        footfalls.append((strideStart + strideSeconds / 2 + wobble, secondAmplitude))
        strideStart += strideSeconds
        index += 1
    }

    return (0..<count).map { sampleIndex in
        let t = Double(sampleIndex) / rate
        var value = 0.0
        for footfall in footfalls where t >= footfall.time && t < footfall.time + pulseWidth {
            value += footfall.amplitude * pulse(phase: t - footfall.time, width: pulseWidth)
        }
        let sway = 0.25 * sin(2 * .pi * t / strideSeconds)
        return SensorSample(
            deviceTimestamp: t,
            anchor: anchor,
            acceleration: Vector3(x: sway, y: 0, z: -value),
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
        mode: .quickTest,
        audioConfig: .none,
        anchor: anchor,
        series: aligned,
        pedometerEvents: pedometer,
        startedAt: anchor.wallClock,
        endedAt: anchor.wallClock.addingTimeInterval(120),
        advertisedClockElapsed: .seconds(120),
        interruptionCount: 0,
        pedometerAvailable: !pedometer.isEmpty
    )

    return MetricAssembly.assemble(
        features: features,
        segmentation: segmentation,
        buffer: buffer,
        profile: profile,
        configuration: config
    )
}

private let unilateral = UserProfile.fixture(level: .transtibial, side: .left)
private let bilateral = UserProfile.fixture(level: .bilateral, side: .both)

// MARK: - The fabrication trap [PRD §7, OQ-1]

@Test func bilateralUsersGetAbsentAsymmetryNeverZero() {
    // Zero would claim perfect symmetry was measured. Absence says it was not
    // measured, which is the truth.
    let metrics = try! #require(
        pipeline(walkingSignal(seconds: 60, strideSeconds: 1.1, firstAmplitude: 1.0, secondAmplitude: 0.45),
                 profile: bilateral)
    )

    #expect(metrics.stepTimeAsymmetry == nil)
    #expect(metrics.asymmetryAffectedSide == nil)
    // Explicitly not zero — the distinction this whole rule exists for.
    #expect(metrics.stepTimeAsymmetry != 0)
    #expect(metrics.value(for: .stepTimeAsymmetry) == nil)
    #expect(metrics.availableMetrics.contains(.stepTimeAsymmetry) == false)
}

@Test func aSessionWithNoProfileAlsoGetsAbsenceRatherThanZero() {
    let metrics = try! #require(
        pipeline(walkingSignal(seconds: 60, strideSeconds: 1.1, firstAmplitude: 1.0, secondAmplitude: 0.45),
                 profile: nil)
    )

    #expect(metrics.stepTimeAsymmetry == nil)
    #expect(metrics.stepTimeAsymmetry != 0)
}

@Test func aWalkWithoutProminentPeaksGetsAbsenceRatherThanANumber() {
    // A unilateral user whose walk is not periodic enough for the two peaks to
    // contrast. Absence is honest; a number would not be.
    let windows = [
        WindowFeatures(
            intervalIndex: 0, startTimestamp: 0, duration: .seconds(10),
            stepTimes: [0.55, 0.55], ad1: 0.05, ad2: 0.04,
            stepLag: 0.55, strideLag: 1.1,
            trunkRMSMediolateral: 0.2, trunkRMSVertical: 0.5
        )
    ]
    let result = MetricAssembly.stepTimeAsymmetry(
        windows: windows, profile: unilateral, configuration: config
    )

    #expect(result.value == nil)
    #expect(result.side == nil)
}

// MARK: - Asymmetry for unilateral users

@Test func theAsymmetricFixtureYieldsANonzeroValueUnderAUnilateralProfile() {
    // The same signal that gave Ad2 > Ad1 in Task 5.2.4.
    let metrics = try! #require(
        pipeline(walkingSignal(seconds: 60, strideSeconds: 1.1, firstAmplitude: 1.0, secondAmplitude: 0.45),
                 profile: unilateral)
    )

    let asymmetry = try! #require(metrics.stepTimeAsymmetry)
    #expect(asymmetry != 0)
    #expect(abs(asymmetry) > 0.02)
    #expect(metrics.availableMetrics.contains(.stepTimeAsymmetry))
}

@Test func theSideLabelComesFromTheProfile() {
    // [PRD §7] the feature is labelled; a bare number says nothing about which
    // limb it refers to.
    let left = try! #require(
        pipeline(walkingSignal(seconds: 60, strideSeconds: 1.1, firstAmplitude: 1.0, secondAmplitude: 0.45),
                 profile: UserProfile.fixture(level: .transfemoral, side: .left))
    )
    let right = try! #require(
        pipeline(walkingSignal(seconds: 60, strideSeconds: 1.1, firstAmplitude: 1.0, secondAmplitude: 0.45),
                 profile: UserProfile.fixture(level: .transfemoral, side: .right))
    )

    #expect(left.asymmetryAffectedSide == .left)
    #expect(right.asymmetryAffectedSide == .right)
    // The measurement itself is identical; only the label differs.
    #expect(left.stepTimeAsymmetry == right.stepTimeAsymmetry)
}

@Test func aSymmetricWalkGivesAsymmetryNearZeroForAUnilateralUser() {
    // Near zero is a *measurement* here, not a fabrication: the peaks were
    // prominent and the contrast between them really was small.
    let metrics = try! #require(
        pipeline(walkingSignal(seconds: 60, strideSeconds: 1.1), profile: unilateral)
    )

    let asymmetry = try! #require(metrics.stepTimeAsymmetry)
    #expect(abs(asymmetry) < 0.12)
}

@Test func theProfileChangesOnlyAsymmetryAndItsLabel() {
    // Everything else is profile-blind, all the way through [PRD OQ-1].
    let samples = walkingSignal(seconds: 60, strideSeconds: 1.1, firstAmplitude: 1.0, secondAmplitude: 0.45)
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
    // A 1.1 s stride is two 0.55 s steps, about 109 steps per minute.
    let metrics = try! #require(
        pipeline(walkingSignal(seconds: 60, strideSeconds: 1.1), profile: unilateral)
    )

    #expect(abs(metrics.cadenceMean - 109) < 8)
    #expect(metrics.stepRegularity > 0.5)
    #expect(metrics.strideRegularity > 0.5)
    #expect(metrics.trunkMotionVT > metrics.trunkMotionML)
    #expect(metrics.validStrideCount >= config.quality.minimumValidStrides)
    #expect(metrics.windowCount > 1)
}

@Test func jitteredStepTimesRaiseTheVariabilityMetric() {
    let steady = try! #require(pipeline(walkingSignal(seconds: 60, strideSeconds: 1.1), profile: unilateral))
    let jittered = try! #require(
        pipeline(walkingSignal(seconds: 60, strideSeconds: 1.1, stepJitter: 0.1), profile: unilateral)
    )

    #expect(jittered.stepTimeCV > steady.stepTimeCV)
    #expect(steady.stepTimeCV >= 0)
}

@Test func pedometerDataIsCarriedAsContextOnly() {
    let samples = walkingSignal(seconds: 60, strideSeconds: 1.1)
    let events = [PedometerEvent(steps: 109, distance: 72, timestamp: anchor.wallClock.addingTimeInterval(60))]

    let withPedometer = try! #require(pipeline(samples, profile: unilateral, pedometer: events))
    let without = try! #require(pipeline(samples, profile: unilateral))

    #expect(withPedometer.steps == 109)
    #expect(withPedometer.distance == 72)
    #expect(without.steps == nil)
    #expect(without.distance == nil)
    // Context does not change the measurement.
    #expect(withPedometer.stepRegularity == without.stepRegularity)
    #expect(withPedometer.cadenceMean == without.cadenceMean)
}

// MARK: - Provenance carries the entry-11 tripwire

@Test func observedLagsReachTheMetricLevel() {
    let metrics = try! #require(
        pipeline(walkingSignal(seconds: 60, strideSeconds: 1.1), profile: unilateral)
    )

    let step = try! #require(metrics.observedStepPeriod)
    let stride = try! #require(metrics.observedStrideLag)

    #expect(abs(step - 0.55) < 0.12)
    #expect(abs(stride - 1.1) < 0.2)
    // The tripwire: a stride lag that is not about twice the step period means
    // Ad1 and Ad2 were anchored to each other's lag.
    #expect(stride / step > 1.7)
    #expect(stride / step < 2.3)
}

@Test func metricsRoundTripThroughCodingWithTheNewProvenance() throws {
    let metrics = try! #require(
        pipeline(walkingSignal(seconds: 60, strideSeconds: 1.1, firstAmplitude: 1.0, secondAmplitude: 0.45),
                 profile: unilateral)
    )

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
            deviceTimestamp: Double(index) / rate,
            anchor: anchor,
            acceleration: Vector3(x: 0, y: 0, z: -0.001),
            gravity: Vector3(x: 0, y: 0, z: -1)
        )
    }

    #expect(pipeline(still, profile: unilateral) == nil)
}

// MARK: - Aggregation statistics

@Test func medianAggregationResistsASingleOutlierWindow() {
    // A window that caught a turn is an outlier, not a correction.
    let steady = (0..<5).map { index in
        WindowFeatures(
            intervalIndex: 0, startTimestamp: Double(index) * 10, duration: .seconds(10),
            stepTimes: [0.55, 0.55, 0.55], ad1: 0.8, ad2: 0.8,
            stepLag: 0.55, strideLag: 1.1,
            trunkRMSMediolateral: 0.2, trunkRMSVertical: 0.5
        )
    }
    let outlier = WindowFeatures(
        intervalIndex: 0, startTimestamp: 50, duration: .seconds(10),
        stepTimes: [0.55, 0.55, 0.55], ad1: 0.05, ad2: 0.05,
        stepLag: 0.55, strideLag: 1.1,
        trunkRMSMediolateral: 4.0, trunkRMSVertical: 9.0
    )

    #expect(MetricAssembly.median((steady + [outlier]).map(\.ad1)) == 0.8)
    #expect(MetricAssembly.median((steady + [outlier]).map(\.trunkRMSVertical)) == 0.5)
}

@Test func aWindowWithTooFewStepsContributesNoVariability() {
    // One step time has no spread; reporting zero would say it was perfectly even.
    let single = WindowFeatures(
        intervalIndex: 0, startTimestamp: 0, duration: .seconds(10),
        stepTimes: [0.55], ad1: 0.8, ad2: 0.8,
        stepLag: 0.55, strideLag: 1.1,
        trunkRMSMediolateral: 0.2, trunkRMSVertical: 0.5
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

    // Neither scores, so neither has a decided sign.
    #expect(directions.direction(for: .cadenceMean) == nil)
    #expect(directions.direction(for: .stepTimeAsymmetry) == nil)
}
