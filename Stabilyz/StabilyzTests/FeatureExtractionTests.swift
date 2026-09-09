import Foundation
import Testing
@testable import Stabilyz

private let config = AlgorithmConfiguration.v1
private let rate = config.preprocessing.targetSampleRateHz
private let anchor = TimeAnchor(wallClock: Date(timeIntervalSince1970: 1_700_000_000), uptime: 0)

/// A footfall: a narrow positive pulse.
private func pulse(phase: Double, width: Double) -> Double {
    phase < width ? sin(.pi * phase / width) : 0
}

/// Builds a walking signal from a stride pattern.
///
/// Each stride contains two footfalls. `firstAmplitude` and `secondAmplitude`
/// let a test make the two half-cycles deliberately unequal, which is what
/// separates step regularity from stride regularity.
private func walkingSignal(
    seconds: Double,
    strideSeconds: Double,
    firstAmplitude: Double = 1.0,
    secondAmplitude: Double = 1.0,
    stepJitter: Double = 0,
    pulseWidth: Double = 0.12
) -> [SensorSample] {
    let count = Int(seconds * rate)
    // Footfall times, alternating heel strikes half a stride apart.
    var footfalls: [(time: Double, amplitude: Double)] = []
    var strideStart = 0.0
    var index = 0
    while strideStart < seconds + strideSeconds {
        // Deterministic jitter so the test is repeatable.
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
        // Vertical carries the footfalls; a smaller mediolateral sway rides at
        // the stride rate.
        let sway = 0.25 * sin(2 * .pi * t / strideSeconds)
        return SensorSample(
            deviceTimestamp: t,
            anchor: anchor,
            acceleration: Vector3(x: sway, y: 0, z: -value),
            gravity: Vector3(x: 0, y: 0, z: -1)
        )
    }
}

private func extract(_ samples: [SensorSample]) -> ExtractedFeatures {
    let series = Preprocessing.process(
        SampleIngestion.align(samples, sampleRateHz: rate, policy: config.gapDetection),
        configuration: config
    )
    let segmentation = WalkingSegmentDetector.detect(in: series, configuration: config)
    return FeatureExtraction.extract(series: series, segmentation: segmentation, configuration: config)
}

private func mean(_ values: [Double]) -> Double {
    values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
}

// MARK: - The swap test

@Test func unequalHalfCyclesGiveStrideRegularityAboveStepRegularity() {
    // Deliberately asymmetric: one footfall lands harder than the other, so the
    // pattern repeats better over a full stride than over a single step.
    let features = extract(
        walkingSignal(seconds: 60, strideSeconds: 1.1, firstAmplitude: 1.0, secondAmplitude: 0.45)
    )

    #expect(features.windows.isEmpty == false)
    let ad1 = mean(features.windows.map(\.ad1))
    let ad2 = mean(features.windows.map(\.ad2))

    // If the two lags were swapped, this would come out the other way round.
    #expect(ad2 > ad1)
    #expect(ad2 - ad1 > 0.1)
}

@Test func eachAdIsReadAtItsOwnLagAndTheStrideLagIsTwiceTheStepLag() {
    let features = extract(
        walkingSignal(seconds: 60, strideSeconds: 1.1, firstAmplitude: 1.0, secondAmplitude: 0.45)
    )
    let window = try! #require(features.windows.first)

    // Step lag is about half a stride; stride lag is a full stride.
    #expect(abs(window.stepLag - 0.55) < 0.12)
    #expect(abs(window.strideLag - 1.1) < 0.2)
    #expect(window.strideLag > window.stepLag * 1.7)
}

@Test func aSymmetricWalkGivesStepAndStrideRegularityCloseTogether() {
    // Both footfalls identical: the pattern repeats equally well over a step
    // and over a stride.
    let features = extract(walkingSignal(seconds: 60, strideSeconds: 1.1))

    let ad1 = mean(features.windows.map(\.ad1))
    let ad2 = mean(features.windows.map(\.ad2))

    #expect(abs(ad1 - ad2) < 0.15)
    #expect(ad1 > 0.5)
}

// MARK: - Ad bounds and behaviour

@Test func adValuesAreBoundedToTheUnitRange() {
    let features = extract(
        walkingSignal(seconds: 60, strideSeconds: 1.1, firstAmplitude: 1.0, secondAmplitude: 0.3)
    )

    for window in features.windows {
        #expect(window.ad1 >= 0 && window.ad1 <= 1)
        #expect(window.ad2 >= 0 && window.ad2 <= 1)
    }
}

@Test func aPerfectlyPeriodicWalkScoresHighRegularity() {
    let features = extract(walkingSignal(seconds: 60, strideSeconds: 1.1))
    let ad2 = mean(features.windows.map(\.ad2))

    #expect(ad2 > 0.6)
}

@Test func jitteredStepTimesLowerRegularityMeasurably() {
    let steady = extract(walkingSignal(seconds: 60, strideSeconds: 1.1))
    let jittered = extract(walkingSignal(seconds: 60, strideSeconds: 1.1, stepJitter: 0.12))

    let steadyAd1 = mean(steady.windows.map(\.ad1))
    let jitteredAd1 = mean(jittered.windows.map(\.ad1))

    #expect(jitteredAd1 < steadyAd1)
    #expect(steadyAd1 - jitteredAd1 > 0.05)
}

// MARK: - Profile blindness [PRD OQ-1]

@Test func featuresAreIdenticalRegardlessOfUserProfile() {
    // Gait consistency is computed identically for every user, unilateral and
    // bilateral alike, because it reads the signal's own repeating structure
    // and never needs to know which leg is which.
    //
    // This holds structurally: FeatureExtraction.extract takes no UserProfile,
    // so there is nothing for it to branch on. These profiles exist to make the
    // invariant explicit and to fail loudly if a profile parameter is ever added.
    let unilateral = UserProfile.fixture(level: .transtibial, side: .left)
    let bilateral = UserProfile.fixture(level: .bilateral, side: .both)
    #expect(unilateral.supportsStepTimeAsymmetry)
    #expect(bilateral.supportsStepTimeAsymmetry == false)

    let samples = walkingSignal(seconds: 40, strideSeconds: 1.1, firstAmplitude: 1.0, secondAmplitude: 0.5)
    let first = extract(samples)
    let second = extract(samples)

    #expect(first == second)
    #expect(first.windows.map(\.ad1) == second.windows.map(\.ad1))
    #expect(first.windows.map(\.ad2) == second.windows.map(\.ad2))
}

// MARK: - Step peaks and step times

@Test func stepPeaksAreDetectedAtRoughlyTheExpectedCadence() {
    // A 1.1 s stride is two steps of 0.55 s, about 109 steps per minute.
    let features = extract(walkingSignal(seconds: 60, strideSeconds: 1.1))
    let window = try! #require(features.windows.first)

    let medianStep = try! #require(FeatureExtraction.median(window.stepTimes))
    #expect(abs(medianStep - 0.55) < 0.1)
    #expect(window.stepCount > 10)
}

@Test func stepTimesAreLeftPerWindowForStageSixToAggregate() {
    // Stage 5 produces per-window facts; assembling session metrics is 5.2.5.
    let features = extract(walkingSignal(seconds: 60, strideSeconds: 1.1))

    #expect(features.windows.count > 1)
    for window in features.windows {
        #expect(window.stepTimes.isEmpty == false)
        #expect(window.duration > .zero)
    }
}

@Test func closelySpacedPeaksAreNotCountedTwice() {
    // The refractory comes from the fastest plausible cadence, so ripple within
    // one footfall cannot register as two steps.
    let signal = (0..<600).map { index -> Double in
        let t = Double(index) / rate
        // Two bumps 40 ms apart every 0.6 s: one footfall, not two.
        let phase = t.truncatingRemainder(dividingBy: 0.6)
        return (phase < 0.05 || (phase > 0.04 && phase < 0.09)) ? 1.0 : 0.0
    }
    let peaks = FeatureExtraction.stepPeaks(signal, rate: rate, configuration: config)

    // Roughly one per 0.6 s over 6 s.
    #expect(peaks.count <= 12)
}

// MARK: - Trunk proxy (TrunkProxyPolicy)

@Test func trunkProxyIsPerAxisRMSOnMediolateralAndVertical() {
    let features = extract(walkingSignal(seconds: 60, strideSeconds: 1.1))
    let window = try! #require(features.windows.first)

    // Both axes are measured separately and kept separately.
    #expect(window.trunkRMSVertical > 0)
    #expect(window.trunkRMSMediolateral > 0)
    // The footfalls are on vertical; the sway is smaller.
    #expect(window.trunkRMSVertical > window.trunkRMSMediolateral)
    #expect(config.trunkProxy.perAxisRMS)
}

@Test func aLargerSwayRaisesOnlyTheMediolateralProxy() {
    let quiet = extract(walkingSignal(seconds: 40, strideSeconds: 1.1))
    let swaying = extract(walkingSignal(seconds: 40, strideSeconds: 1.1).map { sample in
        SensorSample(
            deviceTimestamp: sample.deviceTimestamp,
            anchor: sample.anchor,
            acceleration: Vector3(x: sample.acceleration.x * 4, y: 0, z: sample.acceleration.z),
            gravity: sample.gravity
        )
    })

    let quietML = mean(quiet.windows.map(\.trunkRMSMediolateral))
    let swayML = mean(swaying.windows.map(\.trunkRMSMediolateral))
    let quietVT = mean(quiet.windows.map(\.trunkRMSVertical))
    let swayVT = mean(swaying.windows.map(\.trunkRMSVertical))

    #expect(swayML > quietML * 2)
    // Vertical is essentially unchanged.
    #expect(abs(swayVT - quietVT) < quietVT * 0.5)
}

// MARK: - Too little data routes to the quality path

@Test func tooFewStridesIsReportedRatherThanMeasured() {
    // docs/08 stage 5: never produce metrics from too little data.
    let features = extract(walkingSignal(seconds: 12, strideSeconds: 1.1))

    #expect(features.strideCount < config.quality.minimumValidStrides)
    #expect(FeatureExtraction.strideShortfallReason(features, configuration: config) == .insufficientValidWalking)
}

@Test func aLongEnoughWalkClearsTheStrideMinimum() {
    let features = extract(walkingSignal(seconds: 60, strideSeconds: 1.1))

    #expect(features.strideCount >= config.quality.minimumValidStrides)
    #expect(FeatureExtraction.strideShortfallReason(features, configuration: config) == nil)
}

@Test func aStandingSessionYieldsNoWindowsAtAll() {
    let still = (0..<Int(60 * rate)).map { index in
        SensorSample(
            deviceTimestamp: Double(index) / rate,
            anchor: anchor,
            acceleration: Vector3(x: 0, y: 0, z: -0.001),
            gravity: Vector3(x: 0, y: 0, z: -1)
        )
    }
    let features = extract(still)

    #expect(features.isEmpty)
    #expect(features.strideCount == 0)
    #expect(FeatureExtraction.strideShortfallReason(features, configuration: config) == .insufficientValidWalking)
}

// MARK: - Windowing

@Test func windowsAreNonOverlappingSoStridesAreNotDoubleCounted() {
    let interval = WalkingInterval(
        segmentIndex: 0,
        startIndex: 0,
        endIndex: Int(35 * rate),
        startTimestamp: 0,
        sampleRateHz: rate
    )
    let ranges = FeatureExtraction.windowRanges(
        for: interval,
        policy: config.featureExtraction,
        rate: rate
    )

    #expect(ranges.count >= 3)
    for (current, next) in zip(ranges, ranges.dropFirst()) {
        #expect(current.upperBound == next.lowerBound)
    }
}

@Test func aTrailingWindowBelowTheMinimumIsDropped() {
    // 10 s window, 5 s minimum: a 22 s interval gives two full windows and a
    // 2 s tail that is discarded.
    let interval = WalkingInterval(
        segmentIndex: 0,
        startIndex: 0,
        endIndex: Int(22 * rate),
        startTimestamp: 0,
        sampleRateHz: rate
    )
    let ranges = FeatureExtraction.windowRanges(
        for: interval,
        policy: config.featureExtraction,
        rate: rate
    )

    #expect(ranges.count == 2)
}

@Test func aTrailingWindowAboveTheMinimumIsKept() {
    let interval = WalkingInterval(
        segmentIndex: 0,
        startIndex: 0,
        endIndex: Int(27 * rate),
        startTimestamp: 0,
        sampleRateHz: rate
    )
    let ranges = FeatureExtraction.windowRanges(
        for: interval,
        policy: config.featureExtraction,
        rate: rate
    )

    #expect(ranges.count == 3)
}

// MARK: - Anchoring

@Test func theLagSearchIsAnchoredNotFree() {
    // A free search would find the largest correlation anywhere; the anchored
    // search only looks within a tolerance of the expected lag.
    let correlation = (0...400).map { lag -> Double in
        // A deliberately huge peak far away from the expected lag.
        lag == 300 ? 100.0 : (lag == 55 ? 5.0 : 0.0)
    }
    let found = FeatureExtraction.peakValue(in: correlation, around: 55, tolerance: 0.15)

    #expect(found.lag == 55)
    #expect(found.value == 5.0)
}
