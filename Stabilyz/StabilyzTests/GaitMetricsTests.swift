import Foundation
import Testing
@testable import Stabilyz

// MARK: - Registry

@Test func metricRegistryRawValuesAreStableForPersistence() {
    // Persisted inside BaselineMetricStat and MetricBreakdown blobs (docs/05 §5.2).
    #expect(Set(MetricID.allCases.map(\.rawValue)) == [
        "stepRegularity", "strideRegularity", "cadenceMean", "stepTimeCV",
        "trunkMotionML", "trunkMotionVT", "stepTimeAsymmetry"
    ])
    #expect(MetricID(rawValue: "stepRegularity") == .stepRegularity)
}

@Test func compositeInputsIncludeSignalsBeyondGaitConsistency() {
    // [PRD §7] gait consistency is never the sole basis of the score, so the
    // registry must carry independent signals alongside Ad1/Ad2.
    let consistency: Set<MetricID> = [.stepRegularity, .strideRegularity]
    let independent = Set(MetricID.allCases).subtracting(consistency)

    #expect(independent.contains(.stepTimeCV))
    #expect(independent.contains(.trunkMotionML))
    #expect(independent.contains(.trunkMotionVT))
}

// MARK: - Direction metadata

@Test func directionsAreSuppliedByConfigurationNotBakedIntoTheModel() {
    // [OPEN] docs/05 §5.1 / docs/08 §8.2: the sign convention is unresolved, so
    // the model carries direction without asserting any particular mapping.
    let directions = MetricDirections([
        .stepRegularity: .higherIsBetter,
        .stepTimeCV: .lowerIsBetter
    ])

    #expect(directions.direction(for: .stepRegularity) == .higherIsBetter)
    #expect(directions.direction(for: .stepTimeCV) == .lowerIsBetter)
    // A metric this configuration does not standardize has no direction.
    #expect(directions.direction(for: .cadenceMean) == nil)
    #expect(directions.standardizedMetrics == [.stepRegularity, .stepTimeCV])
}

@Test func directionMetadataRoundTripsThroughCoding() throws {
    for direction in MetricID.Direction.allCases {
        let data = try JSONEncoder().encode(direction)
        #expect(try JSONDecoder().decode(MetricID.Direction.self, from: data) == direction)
    }
}

// MARK: - Metrics

@Test func metricsExposeValuesByRegistryID() {
    let metrics = GaitMetrics.fixture()

    #expect(metrics.value(for: .stepRegularity) == 0.82)
    #expect(metrics.value(for: .strideRegularity) == 0.78)
    #expect(metrics.value(for: .cadenceMean) == 104)
    #expect(metrics.value(for: .stepTimeCV) == 0.041)
    #expect(metrics.value(for: .trunkMotionML) == 1.12)
    #expect(metrics.value(for: .trunkMotionVT) == 2.30)
}

@Test func asymmetryIsAbsentRatherThanZeroWhenSideIsNotIdentifiable() {
    // [PRD §7, OQ-1] never fabricated for bilateral users. Zero would be a
    // fabricated measurement; nil says "not measured".
    let bilateral = GaitMetrics.fixture(stepTimeAsymmetry: nil)
    #expect(bilateral.value(for: .stepTimeAsymmetry) == nil)
    #expect(bilateral.availableMetrics.contains(.stepTimeAsymmetry) == false)

    let unilateral = GaitMetrics.fixture(stepTimeAsymmetry: 0.06)
    #expect(unilateral.value(for: .stepTimeAsymmetry) == 0.06)
    #expect(unilateral.availableMetrics.contains(.stepTimeAsymmetry))
}

@Test func trunkProxyKeepsBothAxesSoTheOpenFormulationStaysAvailable() {
    // [OPEN] per-axis vs combined is unresolved (docs/08 §8.2); storing both
    // means resolving it later is a config change, not a schema migration.
    let metrics = GaitMetrics.fixture()
    #expect(metrics.trunkMotionML != metrics.trunkMotionVT)
    #expect(metrics.availableMetrics.contains(.trunkMotionML))
    #expect(metrics.availableMetrics.contains(.trunkMotionVT))
}

@Test func metricsRoundTripThroughCodingForBlobStorage() throws {
    let metrics = GaitMetrics.fixture(stepTimeAsymmetry: 0.06)
    let data = try JSONEncoder().encode(metrics)
    #expect(try JSONDecoder().decode(GaitMetrics.self, from: data) == metrics)

    let bilateral = GaitMetrics.fixture()
    let bilateralData = try JSONEncoder().encode(bilateral)
    let decoded = try JSONDecoder().decode(GaitMetrics.self, from: bilateralData)
    #expect(decoded.stepTimeAsymmetry == nil)
}
