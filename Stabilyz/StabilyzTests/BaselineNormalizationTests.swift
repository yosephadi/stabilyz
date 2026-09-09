import Foundation
import Testing
@testable import Stabilyz

private let config = AlgorithmConfiguration.v1
private let base = Date(timeIntervalSince1970: 1_700_000_000)

private func metrics(
    ad1: Double = 0.80,
    ad2: Double = 0.78,
    cadence: Double = 109,
    cv: Double = 0.04,
    trunkML: Double = 1.0,
    trunkVT: Double = 2.0,
    asymmetry: Double? = 0.09
) -> GaitMetrics {
    GaitMetrics(
        stepRegularity: ad1, strideRegularity: ad2, cadenceMean: cadence,
        stepTimeCV: cv, trunkMotionML: trunkML, trunkMotionVT: trunkVT,
        stepTimeAsymmetry: asymmetry, steps: nil, distance: nil,
        validStrideCount: 100, windowCount: 10
    )
}

/// A baseline with stats chosen so the arithmetic is exact.
private func baseline(
    mode: TestMode = .quickTest,
    stats: [BaselineMetricStat],
    algorithmVersion: String = "1.0.0-provisional"
) -> Baseline {
    try! Baseline(
        id: UUID(), mode: mode, stats: stats, cadenceBPM: 109,
        algorithmVersion: algorithmVersion, establishedAt: base,
        sourceSessionIDs: (0..<5).map { _ in UUID() }
    )
}

private func stat(
    _ metric: MetricID, mean: Double, sd: Double, n: Int = 5, floored: Bool = false
) -> BaselineMetricStat {
    BaselineMetricStat(metricID: metric, mean: mean, sd: sd, n: n, sdFloorApplied: floored)
}

private func standardize(
    _ metrics: GaitMetrics,
    _ baseline: Baseline?,
    mode: TestMode = .quickTest
) throws -> SessionStandardization? {
    try BaselineNormalization.standardize(
        metrics: metrics, mode: mode, against: baseline, configuration: config
    )
}

// MARK: - Closed-form z

@Test func zIsTheDeviationDividedByTheStoredSD() throws {
    // (0.90 − 0.80) / 0.05 = 2.0 exactly.
    let result = try #require(try standardize(
        metrics(ad1: 0.90),
        baseline(stats: [stat(.stepRegularity, mean: 0.80, sd: 0.05)])
    ))
    let ad1 = try #require(result.standardization(for: .stepRegularity))

    #expect(abs(ad1.z - 2.0) < 1e-12)
    #expect(ad1.rawValue == 0.90)
    #expect(ad1.baselineMean == 0.80)
    #expect(ad1.baselineSD == 0.05)
}

@Test func aSessionMatchingItsBaselineScoresZero() throws {
    let result = try #require(try standardize(
        metrics(ad1: 0.80),
        baseline(stats: [stat(.stepRegularity, mean: 0.80, sd: 0.05)])
    ))

    #expect(try #require(result.standardization(for: .stepRegularity)).z == 0)
}

@Test func aWorseThanBaselineValueGivesANegativeZ() throws {
    // (0.70 − 0.80) / 0.05 = −2.0.
    let result = try #require(try standardize(
        metrics(ad1: 0.70),
        baseline(stats: [stat(.stepRegularity, mean: 0.80, sd: 0.05)])
    ))

    #expect(abs(try #require(result.standardization(for: .stepRegularity)).z + 2.0) < 1e-12)
}

// MARK: - Direction handling [entry 3]

@Test func higherIsBetterMetricsPassTheirZThrough() throws {
    let result = try #require(try standardize(
        metrics(ad1: 0.90, ad2: 0.88),
        baseline(stats: [
            stat(.stepRegularity, mean: 0.80, sd: 0.05),
            stat(.strideRegularity, mean: 0.78, sd: 0.05)
        ])
    ))

    let ad1 = try #require(result.standardization(for: .stepRegularity))
    #expect(ad1.direction == .higherIsBetter)
    #expect(ad1.directionAdjustedZ == ad1.z)
    #expect(try #require(ad1.directionAdjustedZ) > 0)
}

@Test func higherVariabilityInvertsToANegativeAdjustedZ() throws {
    // More step-time variability is worse, so a positive raw deviation must
    // read as a negative adjusted score.
    let result = try #require(try standardize(
        metrics(cv: 0.06),
        baseline(stats: [stat(.stepTimeCV, mean: 0.04, sd: 0.01)])
    ))
    let cv = try #require(result.standardization(for: .stepTimeCV))

    #expect(abs(cv.z - 2.0) < 1e-12)
    #expect(cv.direction == .lowerIsBetter)
    #expect(abs(try #require(cv.directionAdjustedZ) + 2.0) < 1e-12)
}

@Test func moreTrunkMotionInvertsOnBothAxes() throws {
    let result = try #require(try standardize(
        metrics(trunkML: 1.2, trunkVT: 2.4),
        baseline(stats: [
            stat(.trunkMotionML, mean: 1.0, sd: 0.1),
            stat(.trunkMotionVT, mean: 2.0, sd: 0.2)
        ])
    ))

    for metric in [MetricID.trunkMotionML, .trunkMotionVT] {
        let value = try #require(result.standardization(for: metric))
        #expect(value.direction == .lowerIsBetter)
        #expect(value.z > 0)
        #expect(try #require(value.directionAdjustedZ) < 0)
    }
}

@Test func cadenceAndAsymmetryGetNoBetterOrWorseReading() throws {
    // Entry 3: neither has a decided sign, so neither gets an adjusted score.
    // A plain deviation is still available for display.
    let result = try #require(try standardize(
        metrics(cadence: 115, asymmetry: 0.12),
        baseline(stats: [
            stat(.cadenceMean, mean: 109, sd: 3),
            stat(.stepTimeAsymmetry, mean: 0.09, sd: 0.015, n: 4)
        ])
    ))

    let cadence = try #require(result.standardization(for: .cadenceMean))
    #expect(abs(cadence.z - 2.0) < 1e-12)
    #expect(cadence.direction == nil)
    #expect(cadence.directionAdjustedZ == nil)

    let asymmetry = try #require(result.standardization(for: .stepTimeAsymmetry))
    #expect(asymmetry.z > 0)
    #expect(asymmetry.directionAdjustedZ == nil)
}

@Test func onlyTheCompositeTermsCarryAnAdjustedScore() throws {
    let result = try #require(try standardize(
        metrics(),
        baseline(stats: MetricID.allCases.map { stat($0, mean: 1.0, sd: 0.5) })
    ))

    let adjusted = Set(result.standardized.filter { $0.directionAdjustedZ != nil }.map(\.metricID))
    #expect(adjusted == [.stepRegularity, .strideRegularity, .stepTimeCV, .trunkMotionML, .trunkMotionVT])

    let plain = Set(result.standardized.filter { $0.directionAdjustedZ == nil }.map(\.metricID))
    #expect(plain == [.cadenceMean, .stepTimeAsymmetry])
}

// MARK: - The floor, made structural [PRD §7 AC]

@Test func aFlooredBaselineBoundsAnOrdinarySessionDeviation() throws {
    // The anti-exaggeration rule end to end. Five near-identical calibration
    // sessions give an observed SD of essentially zero; the floor raises it when
    // the baseline is built, so an ordinary later deviation produces a bounded
    // z instead of an astronomical one.
    let sessions = (0..<5).map { index -> GaitSession in
        let start = base.addingTimeInterval(Double(index) * 86_400)
        return GaitSession.valid(
            id: UUID(), mode: .quickTest, startedAt: start,
            endedAt: start.addingTimeInterval(120),
            advertisedClockElapsed: .seconds(120), validWalkingDuration: .seconds(110),
            metrics: metrics(ad1: 0.80), audioConfig: .none,
            algorithmVersion: "1.0.0-provisional", appVersion: "1.0", deviceModel: "iPhone17,1"
        )
    }
    let built = try BaselineCalculationService.calculate(
        from: sessions, mode: .quickTest, establishedAt: base, configuration: config
    )
    let stat = try #require(built.stat(for: .stepRegularity))
    #expect(stat.sdFloorApplied)

    let result = try #require(try standardize(metrics(ad1: 0.90), built))
    let ad1 = try #require(result.standardization(for: .stepRegularity))

    // 5% of the 0.80 mean is 0.04, so (0.90 − 0.80) / 0.04 = 2.5.
    #expect(abs(ad1.z - 2.5) < 1e-9)
    #expect(ad1.z < 10, "an unfloored SD would have produced a wildly exaggerated z")
    #expect(ad1.sdFloorApplied)
}

@Test func theFloorIsNotReAppliedDuringNormalization() throws {
    // Entry 16: the stored SD is already floored. Dividing by anything else
    // would mean the score depends on the current configuration rather than on
    // the frozen baseline.
    let stored = stat(.stepRegularity, mean: 0.80, sd: 0.02, floored: true)
    let result = try #require(try standardize(metrics(ad1: 0.90), baseline(stats: [stored])))
    let ad1 = try #require(result.standardization(for: .stepRegularity))

    // Divided by the stored 0.02, not by the 0.04 the current policy would
    // compute for this mean.
    #expect(ad1.baselineSD == 0.02)
    #expect(abs(ad1.z - 5.0) < 1e-12)
}

// MARK: - Absence propagates in both directions

@Test func aMetricTheSessionDidNotMeasureIsUnmeasuredNotZero() throws {
    // The asymmetry gate failed for this session, but the baseline has a stat.
    let result = try #require(try standardize(
        metrics(asymmetry: nil),
        baseline(stats: [
            stat(.stepRegularity, mean: 0.80, sd: 0.05),
            stat(.stepTimeAsymmetry, mean: 0.09, sd: 0.015, n: 4)
        ])
    ))

    #expect(result.unmeasured == [.stepTimeAsymmetry])
    #expect(result.standardization(for: .stepTimeAsymmetry) == nil)
    // No zero-valued standardization was invented.
    #expect(result.standardized.contains { $0.metricID == .stepTimeAsymmetry } == false)
}

@Test func aMetricTheBaselineLacksIsRawOnlyNotZero() throws {
    // The three-of-five rule left the baseline without an asymmetry stat, but
    // this session did measure one (entry 16).
    let result = try #require(try standardize(
        metrics(asymmetry: 0.11),
        baseline(stats: [stat(.stepRegularity, mean: 0.80, sd: 0.05)])
    ))

    #expect(result.rawOnly.contains(RawOnlyMetric(metricID: .stepTimeAsymmetry, rawValue: 0.11)))
    #expect(result.standardization(for: .stepTimeAsymmetry) == nil)
    #expect(result.unmeasured.contains(.stepTimeAsymmetry) == false)
}

@Test func aMetricAbsentOnBothSidesAppearsNowhere() throws {
    let result = try #require(try standardize(
        metrics(asymmetry: nil),
        baseline(stats: [stat(.stepRegularity, mean: 0.80, sd: 0.05)])
    ))

    #expect(result.standardization(for: .stepTimeAsymmetry) == nil)
    #expect(result.unmeasured.contains(.stepTimeAsymmetry) == false)
    #expect(result.rawOnly.contains { $0.metricID == .stepTimeAsymmetry } == false)
}

@Test func aZeroSpreadFallsBackToRawRatherThanDividingByIt() throws {
    // The floor should make this unreachable; showing the value raw beats
    // producing an infinity.
    let result = try #require(try standardize(
        metrics(ad1: 0.90),
        baseline(stats: [stat(.stepRegularity, mean: 0.80, sd: 0)])
    ))

    #expect(result.standardization(for: .stepRegularity) == nil)
    #expect(result.rawOnly.contains(RawOnlyMetric(metricID: .stepRegularity, rawValue: 0.90)))
}

// MARK: - Pre-baseline [PRD §5]

@Test func withoutABaselineThereIsNoStandardizationAtAll() throws {
    // "Reference only": raw metrics, no comparison invented.
    #expect(try standardize(metrics(), nil) == nil)
}

// MARK: - Mode safety [PRD OQ-5]

@Test func aBaselineFromAnotherModeIsRefused() {
    #expect(throws: StabilyzError.processing(.baselineModeMismatch)) {
        _ = try standardize(metrics(), baseline(mode: .fullTest, stats: []), mode: .quickTest)
    }
}

@Test func theResultCarriesTheModeAndTheBaselinesVersion() throws {
    // A comparison is only valid within one algorithm version (docs/09 §9.6).
    let result = try #require(try standardize(
        metrics(),
        baseline(mode: .fullTest, stats: [stat(.stepRegularity, mean: 0.80, sd: 0.05)], algorithmVersion: "0.9.0"),
        mode: .fullTest
    ))

    #expect(result.mode == .fullTest)
    #expect(result.algorithmVersion == "0.9.0")
}

// MARK: - Handoff shape for 6.2.2

@Test func everyStandardizationCarriesTheBreakdownIngredients() throws {
    let result = try #require(try standardize(
        metrics(),
        baseline(stats: MetricID.allCases.map { stat($0, mean: 1.0, sd: 0.5, floored: true) })
    ))

    for value in result.standardized {
        #expect(value.baselineSD > 0)
        #expect(value.sdFloorApplied)
        #expect(value.rawValue.isFinite)
        #expect(value.baselineMean.isFinite)
        #expect(value.z.isFinite)
    }
    // The four composite terms are all present and adjusted, ready for 6.2.2.
    #expect(result.standardized.filter { $0.directionAdjustedZ != nil }.count == 5)
}
