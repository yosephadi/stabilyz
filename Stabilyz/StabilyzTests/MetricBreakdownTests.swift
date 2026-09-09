import Foundation
import Testing
@testable import Stabilyz

private let config = AlgorithmConfiguration.v1
private let base = Date(timeIntervalSince1970: 1_700_000_000)

private func metrics(
    ad1: Double = 0.80, ad2: Double = 0.78, cadence: Double = 109,
    cv: Double = 0.04, trunkML: Double = 1.0, trunkVT: Double = 2.0,
    asymmetry: Double? = 0.09, side: AmputationSide? = .left
) -> GaitMetrics {
    GaitMetrics(
        stepRegularity: ad1, strideRegularity: ad2, cadenceMean: cadence,
        stepTimeCV: cv, trunkMotionML: trunkML, trunkMotionVT: trunkVT,
        stepTimeAsymmetry: asymmetry, steps: nil, distance: nil,
        validStrideCount: 100, windowCount: 10, asymmetryAffectedSide: side
    )
}

private func stat(_ metric: MetricID, mean: Double, sd: Double) -> BaselineMetricStat {
    BaselineMetricStat(metricID: metric, mean: mean, sd: sd, n: 5, sdFloorApplied: false)
}

private func baseline(stats: [BaselineMetricStat]) -> Baseline {
    try! Baseline(
        id: UUID(), mode: .quickTest, stats: stats, cadenceBPM: 109,
        algorithmVersion: config.version, establishedAt: base,
        sourceSessionIDs: (0..<5).map { _ in UUID() }
    )
}

private let fullStats = [
    stat(.stepRegularity, mean: 0.80, sd: 0.05),
    stat(.strideRegularity, mean: 0.78, sd: 0.05),
    stat(.cadenceMean, mean: 109, sd: 3),
    stat(.stepTimeCV, mean: 0.04, sd: 0.01),
    stat(.trunkMotionML, mean: 1.0, sd: 0.1),
    stat(.trunkMotionVT, mean: 2.0, sd: 0.2),
    stat(.stepTimeAsymmetry, mean: 0.09, sd: 0.015)
]

private func breakdown(
    _ sample: GaitMetrics = metrics(),
    stats: [BaselineMetricStat] = fullStats
) throws -> [MetricBreakdown] {
    let standardization = try #require(
        try BaselineNormalization.standardize(
            metrics: sample, mode: .quickTest, against: baseline(stats: stats), configuration: config
        )
    )
    return MetricBreakdownBuilder.breakdown(from: standardization, metrics: sample)
}

private func entry(_ signal: SignalID, in breakdown: [MetricBreakdown]) throws -> MetricBreakdown {
    try #require(breakdown.first { $0.signal == signal })
}

// MARK: - One entry per user-facing signal

@Test func everySignalGetsAnEntryWhenEverythingIsMeasured() throws {
    let result = try breakdown()
    #expect(Set(result.map(\.signal)) == Set(SignalID.allCases))
}

@Test func gaitConsistencyCarriesBothAutocorrelationOutputs() throws {
    // How they present as one signal is EPIC 8's call, so both values travel.
    let consistency = try entry(.gaitConsistency, in: try breakdown())

    #expect(consistency.components.map(\.metricID) == [.stepRegularity, .strideRegularity])
    #expect(consistency.components.allSatisfy { $0.directionAdjustedZ != nil })
}

@Test func theTrunkProxyCarriesBothAxes() throws {
    let trunk = try entry(.trunkMotion, in: try breakdown())
    #expect(trunk.components.map(\.metricID) == [.trunkMotionML, .trunkMotionVT])
}

@Test func eachComponentCarriesTheComparisonItWasMadeAgainst() throws {
    let consistency = try entry(.gaitConsistency, in: try breakdown(metrics(ad1: 0.90)))
    let ad1 = try #require(consistency.components.first)

    #expect(ad1.rawValue == 0.90)
    #expect(ad1.baselineMean == 0.80)
    #expect(ad1.baselineSD == 0.05)
    #expect(abs(try #require(ad1.directionAdjustedZ) - 2.0) < 1e-12)
    #expect(ad1.availability == .standardized)
}

// MARK: - No better/worse where none was decided [entry 3]

@Test func cadenceAndAsymmetryCarryValuesWithNoDirection() throws {
    let result = try breakdown()

    for signal in [SignalID.cadence, .stepTimeAsymmetry] {
        let value = try entry(signal, in: result)
        #expect(value.carriesDirection == false, "\(signal.rawValue) must not read as better or worse")
        #expect(value.components.allSatisfy { $0.directionAdjustedZ == nil })
        // The value itself is still there to show.
        #expect(value.components.allSatisfy { $0.rawValue != nil })
    }
}

@Test func theDirectionalSignalsDoCarryDirection() throws {
    let result = try breakdown()

    for signal in [SignalID.gaitConsistency, .stepTimeVariability, .trunkMotion] {
        #expect(try entry(signal, in: result).carriesDirection)
    }
}

@Test func theAsymmetryEntryCarriesProfileSideAsContext() throws {
    // Context for EPIC 8's signed, side-labelled rendering — not attribution
    // (docs/decisions.md entry 13).
    let result = try breakdown(metrics(asymmetry: 0.11, side: .right))
    let asymmetry = try entry(.stepTimeAsymmetry, in: result)

    #expect(asymmetry.asymmetrySide == .right)
    // No other entry claims a side.
    #expect(result.filter { $0.signal != .stepTimeAsymmetry }.allSatisfy { $0.asymmetrySide == nil })
}

// MARK: - The 6.2.1 absence vocabulary, carried forward

@Test func aMetricTheBaselineLacksIsMarkedRawOnly() throws {
    let result = try breakdown(
        metrics(asymmetry: 0.11),
        stats: fullStats.filter { $0.metricID != .stepTimeAsymmetry }
    )
    let asymmetry = try entry(.stepTimeAsymmetry, in: result)
    let component = try #require(asymmetry.components.first)

    #expect(component.availability == .rawOnly)
    #expect(component.rawValue == 0.11)
    #expect(component.baselineMean == nil)
    #expect(component.directionAdjustedZ == nil)
}

@Test func aMetricTheSessionDidNotMeasureIsMarkedUnmeasured() throws {
    let result = try breakdown(metrics(asymmetry: nil))
    let asymmetry = try entry(.stepTimeAsymmetry, in: result)
    let component = try #require(asymmetry.components.first)

    #expect(component.availability == .unmeasured)
    // Absence, never zero.
    #expect(component.rawValue == nil)
    #expect(component.rawValue != 0)
}

@Test func aSignalWithNothingToShowIsOmittedRatherThanShownEmpty() throws {
    // Neither measured nor baselined.
    let result = try breakdown(
        metrics(asymmetry: nil),
        stats: fullStats.filter { $0.metricID != .stepTimeAsymmetry }
    )

    #expect(result.contains { $0.signal == .stepTimeAsymmetry } == false)
    #expect(result.isEmpty == false)
}

// MARK: - Terminology [PRD OQ-1]

@Test func theConsistencySignalIsNeverCalledSymmetry() throws {
    // Calling the autocorrelation output "symmetry" would overclaim what it
    // measures; that term belongs to the unilateral step-time comparison only.
    #expect(SignalID.gaitConsistency.provisionalLabel == "Gait consistency")
    #expect(SignalID.gaitConsistency.provisionalLabel.localizedCaseInsensitiveContains("symmetr") == false)

    for signal in SignalID.allCases where signal != .stepTimeAsymmetry {
        #expect(
            signal.provisionalLabel.localizedCaseInsensitiveContains("symmetr") == false,
            "\(signal.rawValue) label must not use the reserved term"
        )
    }
}

@Test func signalKeysAreStableForPersistenceAndEpicEight() throws {
    #expect(Set(SignalID.allCases.map(\.rawValue)) == [
        "gaitConsistency", "stepTimeVariability", "trunkMotion", "cadence", "stepTimeAsymmetry"
    ])
}

@Test func theBreakdownRoundTripsThroughCoding() throws {
    let result = try breakdown()
    let data = try JSONEncoder().encode(result)
    #expect(try JSONDecoder().decode([MetricBreakdown].self, from: data) == result)
}
