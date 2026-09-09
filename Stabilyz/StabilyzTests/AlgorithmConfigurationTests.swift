import Foundation
import Testing
@testable import Stabilyz

private let config = AlgorithmConfiguration.v1

// MARK: - Composite weights

@Test func compositeWeightsSumToOne() {
    // Anything else silently rescales every score.
    let total = CompositeTerm.allCases.reduce(0.0) { $0 + config.composite.weight(for: $1) }
    #expect(abs(total - 1.0) < 1e-9)
}

@Test func everyCompositeTermCarriesAWeight() {
    // A term with no weight would be computed and then silently discarded.
    for term in CompositeTerm.allCases {
        #expect(config.composite.weight(for: term) > 0, "\(term.rawValue) has no weight")
    }
}

@Test func gaitConsistencyIsNeverTheSoleBasisOfTheScore() {
    // [PRD §7] hard rule. Ad1 and Ad2 together must be less than the whole.
    let consistency = config.composite.weight(for: .stepRegularity)
        + config.composite.weight(for: .strideRegularity)
    #expect(consistency < 1.0)

    let independent = config.composite.weight(for: .stepTimeCV)
        + config.composite.weight(for: .trunkProxy)
    #expect(independent > 0)
}

@Test func asymmetryIsNotACompositeTerm() {
    // [PRD §7] "distinct... not merged into a single number". Computed, stored
    // and displayed separately — see docs/decisions.md for the chosen reading.
    #expect(CompositeTerm.allCases.map(\.rawValue).contains("stepTimeAsymmetry") == false)
    #expect(CompositeTerm.allCases.count == 4)
}

@Test func invertedTermsAreTheOnesWhereLowerIsBetter() {
    #expect(config.composite.isInverted(.stepTimeCV))
    #expect(config.composite.isInverted(.trunkProxy))
    #expect(config.composite.isInverted(.stepRegularity) == false)
    #expect(config.composite.isInverted(.strideRegularity) == false)
}

// MARK: - Relative index

@Test func baselinePerformanceMapsToOneHundred() {
    // [PRD §7] baseline = 100, and it is an index, not a percentage.
    #expect(config.composite.relativeIndex(forCompositeZ: 0) == 100)
}

@Test func aBetterThanBaselineSessionScoresAbove() {
    #expect(config.composite.relativeIndex(forCompositeZ: 0.12) == 112)
    #expect(config.composite.relativeIndex(forCompositeZ: -0.2) == 80)
}

@Test func theIndexIsClampedSoOneWildSessionCannotBreakTheTrend() {
    #expect(config.composite.relativeIndex(forCompositeZ: 50) == 200)
    #expect(config.composite.relativeIndex(forCompositeZ: -50) == 0)
    #expect(config.composite.indexRange == 0...200)
}

// MARK: - SD floor [PRD §7 AC]

@Test func everyStandardisableMetricHasAPositiveAbsoluteFloor() {
    for metric in MetricID.allCases {
        let floor = config.normalization.absoluteFloors[metric]
        #expect(floor != nil, "\(metric.rawValue) has no absolute floor")
        #expect((floor ?? 0) > 0, "\(metric.rawValue) floor must be positive")
    }
}

@Test func theFloorRaisesAnImplausiblySmallSD() {
    // Without the floor, five near-identical calibration sessions produce a
    // tiny SD and then wildly exaggerated z-scores.
    let floored = config.normalization.flooredSD(for: .stepRegularity, observedSD: 0.0001, baselineMean: 0.8)

    // 5% of 0.8 is 0.04, which beats both the observed SD and the 0.02 absolute.
    #expect(abs(floored - 0.04) < 1e-9)
    #expect(config.normalization.floorApplied(for: .stepRegularity, observedSD: 0.0001, baselineMean: 0.8))
}

@Test func aHealthySDIsLeftAlone() {
    let observed = 0.5
    let floored = config.normalization.flooredSD(for: .stepRegularity, observedSD: observed, baselineMean: 0.8)

    #expect(floored == observed)
    #expect(config.normalization.floorApplied(for: .stepRegularity, observedSD: observed, baselineMean: 0.8) == false)
}

@Test func theAbsoluteFloorCatchesABaselineMeanNearZero() {
    // The relative floor vanishes as the mean approaches zero; the absolute
    // floor is what stops the division blowing up.
    let floored = config.normalization.flooredSD(for: .stepTimeCV, observedSD: 0.0001, baselineMean: 0.0)

    #expect(abs(floored - 0.01) < 1e-9)
}

@Test func theFloorIsNeverBelowTheObservedSD() {
    for metric in MetricID.allCases {
        let floored = config.normalization.flooredSD(for: metric, observedSD: 100, baselineMean: 1)
        #expect(floored >= 100)
    }
}

// MARK: - Thresholds in range

@Test func thresholdsSitInTheirValidRanges() {
    #expect(config.noise.maximumHighFrequencyPowerRatio > 0)
    #expect(config.noise.maximumHighFrequencyPowerRatio < 1)
    #expect(config.noise.highFrequencyCutoffHz > 0)

    #expect(config.liveStepFeedback.confidenceThreshold >= 0)
    #expect(config.liveStepFeedback.confidenceThreshold <= 1)
    #expect(config.liveStepFeedback.refractory > .zero)

    #expect(config.normalization.relativeFloorFraction > 0)
    #expect(config.normalization.relativeFloorFraction < 1)

    #expect(config.gapDetection.toleranceMultiplier > 1)
    #expect(config.motionAcquisition.sampleRateHz > 0)
    #expect(config.quality.minimumValidStrides > 0)
}

@Test func theNoiseCutoffSitsAboveWalkingFrequencies() {
    // Cadence tops out near 2 steps/sec, so an 8 Hz cutoff leaves gait energy
    // below it and measures what is left.
    #expect(config.noise.highFrequencyCutoffHz > 4)
    // And below Nyquist for the configured rate, or the ratio is meaningless.
    #expect(config.noise.highFrequencyCutoffHz < config.motionAcquisition.sampleRateHz / 2)
}

@Test func theRefractoryWindowIsShorterThanAStepInterval() {
    // docs/10 §10.3: a typical step interval is 0.5-0.7 s. A refractory window
    // at or above that would swallow real steps.
    #expect(config.liveStepFeedback.refractory < .milliseconds(500))
}

// MARK: - Quality gate

@Test func tooLittleWalkingIsInsufficientRatherThanNoisy() {
    // [PRD OQ-3] and the plainer explanation is reported first.
    let reason = config.quality.invalidReason(
        mode: .quickTest,
        validWalkingDuration: .seconds(60),
        validStrideCount: 100,
        highFrequencyPowerRatio: 0.9
    )
    #expect(reason == .insufficientValidWalking)
}

@Test func tooFewStridesFailsEvenWithEnoughWalkingTime() {
    let reason = config.quality.invalidReason(
        mode: .quickTest,
        validWalkingDuration: .seconds(120),
        validStrideCount: 5,
        highFrequencyPowerRatio: 0.1
    )
    #expect(reason == .insufficientValidWalking)
}

@Test func excessiveNoiseFailsAnOtherwiseSoundSession() {
    let reason = config.quality.invalidReason(
        mode: .quickTest,
        validWalkingDuration: .seconds(120),
        validStrideCount: 100,
        highFrequencyPowerRatio: 0.5
    )
    #expect(reason == .excessiveNoise)
}

@Test func aSoundSessionPassesTheGate() {
    let reason = config.quality.invalidReason(
        mode: .fullTest,
        validWalkingDuration: .seconds(260),
        validStrideCount: 200,
        highFrequencyPowerRatio: 0.2
    )
    #expect(reason == nil)
}

@Test func theQualityGateUsesTheModesOwnMinimum() {
    // 100 s passes Quick Test and fails Full Test [PRD OQ-3].
    #expect(config.quality.minimumValidWalkingDuration(for: .quickTest) == .seconds(90))
    #expect(config.quality.minimumValidWalkingDuration(for: .fullTest) == .seconds(240))

    let quick = config.quality.invalidReason(
        mode: .quickTest, validWalkingDuration: .seconds(100),
        validStrideCount: 100, highFrequencyPowerRatio: 0.1
    )
    let full = config.quality.invalidReason(
        mode: .fullTest, validWalkingDuration: .seconds(100),
        validStrideCount: 100, highFrequencyPowerRatio: 0.1
    )
    #expect(quick == nil)
    #expect(full == .insufficientValidWalking)
}

// MARK: - Directions

@Test func decidedMetricDirectionsMatchTheCompositeTerms() {
    #expect(config.metricDirections.direction(for: .stepRegularity) == .higherIsBetter)
    #expect(config.metricDirections.direction(for: .strideRegularity) == .higherIsBetter)
    #expect(config.metricDirections.direction(for: .stepTimeCV) == .lowerIsBetter)
    #expect(config.metricDirections.direction(for: .trunkMotionML) == .lowerIsBetter)
    #expect(config.metricDirections.direction(for: .trunkMotionVT) == .lowerIsBetter)
}

@Test func metricsThatDoNotScoreCarryNoDirection() {
    // Neither contributes to the composite, so neither has a decided sign
    // convention — see docs/decisions.md. Inventing one would let the UI label
    // a faster cadence "better" without that having been decided.
    #expect(config.metricDirections.direction(for: .cadenceMean) == nil)
    #expect(config.metricDirections.direction(for: .stepTimeAsymmetry) == nil)
}

// MARK: - Versioning

@Test func theConfigurationIsVersionedAndMarkedProvisional() {
    // docs/09 §9.6: a baseline is only comparable under its algorithm version.
    #expect(config.version.isEmpty == false)
    #expect(config.version.contains("provisional"))
}
