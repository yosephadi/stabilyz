import Foundation
import Testing
@testable import Stabilyz

/// The pre-baseline score (`ProvisionalStabilityScore`, `IntrinsicScorer`).
///
/// **The scale itself is a labelled `[OPEN]` placeholder** — docs/08 §8.2
/// leaves index scaling unspecified and there is no normative distribution for
/// this population anywhere in the documents. So nothing here asserts that a
/// particular walk scores a particular number: that would freeze anchors Phase
/// 12 is expected to replace. What is asserted is the set of properties the
/// score must keep whatever the anchors become.

private let config = AlgorithmConfiguration.v1

private func score(_ metrics: GaitMetrics) -> ProvisionalStabilityScore? {
    IntrinsicScorer.score(metrics, algorithmVersion: config.version, configuration: config)
}

/// A metrics value with every scoring input set, and nothing else varying.
private func walk(
    stepReg: Double,
    strideReg: Double,
    cv: Double,
    trunkML: Double,
    trunkVT: Double
) -> GaitMetrics {
    GaitMetrics(
        stepRegularity: stepReg,
        strideRegularity: strideReg,
        cadenceMean: 104,
        stepTimeCV: cv,
        trunkMotionML: trunkML,
        trunkMotionVT: trunkVT,
        validStrideCount: 96,
        windowCount: 12
    )
}

/// `.v1` with different reference anchors, for the refusal cases.
///
/// Spelled out rather than mutated: `AlgorithmConfiguration` is deliberately
/// all-`let`, and a `with`-style copy helper in the test bundle would be the
/// first crack in that.
private func configuration(
    references: [MetricID: MetricReferenceRange]
) -> AlgorithmConfiguration {
    let base = AlgorithmConfiguration.v1
    return AlgorithmConfiguration(
        version: base.version,
        motionAcquisition: base.motionAcquisition,
        gapDetection: base.gapDetection,
        preprocessing: base.preprocessing,
        walkingDetection: base.walkingDetection,
        featureExtraction: base.featureExtraction,
        baseline: base.baseline,
        summary: base.summary,
        orientation: base.orientation,
        noise: base.noise,
        trunkProxy: base.trunkProxy,
        asymmetry: base.asymmetry,
        normalization: base.normalization,
        composite: base.composite,
        intrinsic: IntrinsicScorePolicy(references: references, range: base.intrinsic.range),
        quality: base.quality,
        liveStepFeedback: base.liveStepFeedback,
        metricDirections: base.metricDirections
    )
}

// MARK: - What the score is built from [PRD §7, OQ-1]

@Test func theScoreRestsOnTheThreeIndependentSignals() {
    let result = try? #require(score(.fixture()))
    #expect(result?.contributions.map(\.signal) == [
        .gaitConsistency, .stepTimeVariability, .trunkMotion
    ])
}

@Test func gaitConsistencyIsNeverTheSoleBasisOfTheProvisionalScore() {
    // [PRD §7]: a highly regular gait can still be dynamically unstable, so
    // consistency may carry at most half.
    let result = try? #require(score(.fixture()))
    let consistency = result?.contributions.first { $0.signal == .gaitConsistency }
    #expect((consistency?.weight ?? 1) <= 0.5)
}

@Test func theWeightsAreAWholeScore() {
    let result = try? #require(score(.fixture()))
    let total = result?.contributions.reduce(0) { $0 + $1.weight } ?? 0
    #expect(abs(total - 1) < 1e-9)
}

@Test func stepTimeAsymmetryIsNotAScoringTerm() {
    // Secondary, unilateral only, and never merged into a composite as a
    // hidden term [PRD §7, OQ-1]. It is also what keeps the score meaning the
    // same thing for bilateral users, who have no asymmetry value at all.
    #expect(IntrinsicScorer.scoringSignals.contains { $0.signal == .stepTimeAsymmetry } == false)
}

@Test func aBilateralAndAUnilateralWalkWithTheSameSignalsScoreTheSame() {
    // The only difference between these two is the asymmetry value, which must
    // not reach the score.
    let bilateral = GaitMetrics.fixture(stepTimeAsymmetry: nil)
    let unilateral = GaitMetrics.fixture(stepTimeAsymmetry: 0.09)

    #expect(score(bilateral)?.value == score(unilateral)?.value)
}

@Test func cadenceIsNotAScoringTerm() {
    // No decided sign convention, so it cannot be scored as better or worse
    // (docs/decisions.md entry 3).
    #expect(IntrinsicScorer.scoringSignals.contains { $0.signal == .cadence } == false)
}

// MARK: - The scale's own properties

@Test func theScoreStaysInsideItsRange() {
    // Far past both anchors in both directions.
    let excellent = walk(stepReg: 5, strideReg: 5, cv: -1, trunkML: -10, trunkVT: -10)
    let dreadful = walk(stepReg: -5, strideReg: -5, cv: 9, trunkML: 99, trunkVT: 99)

    #expect(score(excellent)?.value == config.intrinsic.range.upperBound)
    #expect(score(dreadful)?.value == config.intrinsic.range.lowerBound)
}

@Test func aSteadierWalkNeverScoresLowerThanAShakierOne() {
    // The one monotonicity that has to survive any re-anchoring: better on
    // every input may not read as worse.
    let shakier = walk(stepReg: 0.55, strideReg: 0.50, cv: 0.09, trunkML: 2.0, trunkVT: 3.2)
    let steadier = walk(stepReg: 0.85, strideReg: 0.82, cv: 0.03, trunkML: 0.8, trunkVT: 1.4)

    let low = try? #require(score(shakier)?.value)
    let high = try? #require(score(steadier)?.value)
    #expect((high ?? 0) > (low ?? 0))
}

@Test func aLowerVariabilityReadsAsBetterOnItsOwn() {
    // stepTimeCV's anchors run downward; a metric read the wrong way round
    // would invert this and nothing else would notice.
    let noisy = GaitMetrics.fixture(stepTimeCV: 0.10)
    let steady = GaitMetrics.fixture(stepTimeCV: 0.025)

    #expect((score(steady)?.value ?? 0) > (score(noisy)?.value ?? 0))
}

@Test func theScoreIsStampedWithTheConfigurationThatProducedIt() {
    // These anchors are expected to move, so a stored score that did not say
    // which ones it used would become unreadable rather than merely stale.
    #expect(score(.fixture())?.algorithmVersion == config.version)
}

@Test func theScoreIsDeterministic() {
    #expect(score(.fixture()) == score(.fixture()))
}

// MARK: - Refusal rather than a partial score

@Test func aMissingAnchorRefusesTheWholeScore() {
    // No renormalisation over the surviving signals: spreading a missing
    // signal's weight would present a two-signal score on a three-signal
    // scale, which is the mistake `CompositeScorer` refuses for the same reason.
    let incomplete = configuration(
        references: AlgorithmConfiguration.v1.intrinsic.references.filter { $0.key != .trunkMotionVT }
    )

    #expect(IntrinsicScorer.score(
        .fixture(), algorithmVersion: config.version, configuration: incomplete
    ) == nil)
}

@Test func aDegenerateAnchorPairRefusesTheScore() {
    var references = AlgorithmConfiguration.v1.intrinsic.references
    references[.stepTimeCV] = MetricReferenceRange(poor: 0.05, good: 0.05)
    let broken = configuration(references: references)

    #expect(IntrinsicScorer.score(
        .fixture(), algorithmVersion: config.version, configuration: broken
    ) == nil)
}

// MARK: - The signals behind the summary

@Test func theStrongestAndWeakestSignalsAreTheOnesThatReadThatWay() {
    let result = ProvisionalStabilityScore.fixture(
        gaitConsistency: 0.9, stepTimeVariability: 0.4, trunkMotion: 0.6
    )
    #expect(result.strongest == .gaitConsistency)
    #expect(result.weakest == .stepTimeVariability)
}

@Test func anEvenWalkNamesNoStandoutSignal() {
    // A claim that one signal stood out has to rest on one actually standing
    // out.
    let result = ProvisionalStabilityScore.fixture(
        gaitConsistency: 0.7, stepTimeVariability: 0.7, trunkMotion: 0.7
    )
    #expect(result.strongest == nil)
    #expect(result.weakest == nil)
}

// MARK: - The pre-baseline summary line

@Test func theSummaryNamesBothEndsOfTheWalk() {
    let summary = ProvisionalSummaryGenerator.summary(
        mode: .quickTest,
        score: .fixture(gaitConsistency: 0.9, stepTimeVariability: 0.4, trunkMotion: 0.6)
    )

    #expect(summary.claim == .contrast)
    #expect(summary.strongest == .gaitConsistency)
    #expect(summary.weakest == .stepTimeVariability)
    #expect(summary.text.contains("gait consistency"))
    #expect(summary.text.contains("step rhythm"))
}

@Test func theSummaryFallsBackWhenNothingStandsOut() {
    let summary = ProvisionalSummaryGenerator.summary(
        mode: .fullTest,
        score: .fixture(gaitConsistency: 0.7, stepTimeVariability: 0.7, trunkMotion: 0.7)
    )
    #expect(summary.claim == .even)
    #expect(summary.text.contains("Full Test"))
}

@Test func theSummaryMakesNoPercentageClaim() {
    // The score is on an unvalidated placeholder scale; a percentage would be a
    // real-world claim twice over [PRD §5, §7].
    for quality in stride(from: 0.0, through: 1.0, by: 0.1) {
        let summary = ProvisionalSummaryGenerator.summary(
            mode: .quickTest,
            score: .fixture(gaitConsistency: quality, stepTimeVariability: 1 - quality, trunkMotion: 0.5)
        )
        #expect(summary.text.contains("%") == false)
    }
}

@Test func theSummaryNeverCallsAnythingSymmetry() {
    // [PRD OQ-1]: the reserved term belongs to the unilateral step-time
    // comparison, which is not a scoring signal at all.
    for quality in [0.1, 0.5, 0.9] {
        let summary = ProvisionalSummaryGenerator.summary(
            mode: .quickTest,
            score: .fixture(gaitConsistency: quality, stepTimeVariability: 1 - quality, trunkMotion: 0.5)
        )
        #expect(summary.text.localizedCaseInsensitiveContains("symmetr") == false)
    }
}

@Test func theSummaryNeverClaimsAnImprovement() {
    // There is no history to have improved from.
    for quality in [0.1, 0.5, 0.9] {
        let summary = ProvisionalSummaryGenerator.summary(
            mode: .quickTest,
            score: .fixture(gaitConsistency: quality, stepTimeVariability: 1 - quality, trunkMotion: 0.5)
        )
        for word in ["improve", "better than", "progress"] {
            #expect(summary.text.localizedCaseInsensitiveContains(word) == false, "\(word)")
        }
    }
}
