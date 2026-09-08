import Foundation
import Testing
@testable import Stabilyz

// MARK: - Baseline invariants

@Test func baselineRequiresExactlyFiveSourceSessions() throws {
    // [PRD OQ-5] the five-session calibration requirement is locked in.
    #expect(Baseline.requiredValidSessionCount == 5)

    let tooFew = (0..<4).map { _ in UUID() }
    #expect(throws: Baseline.ValidationError.wrongSourceSessionCount(expected: 5, actual: 4)) {
        try Baseline(
            id: UUID(), mode: .quickTest, stats: [], cadenceBPM: 104,
            algorithmVersion: "1.0.0", establishedAt: Date(), sourceSessionIDs: tooFew
        )
    }

    let tooMany = (0..<6).map { _ in UUID() }
    #expect(throws: Baseline.ValidationError.wrongSourceSessionCount(expected: 5, actual: 6)) {
        try Baseline(
            id: UUID(), mode: .quickTest, stats: [], cadenceBPM: 104,
            algorithmVersion: "1.0.0", establishedAt: Date(), sourceSessionIDs: tooMany
        )
    }
}

@Test func baselineRejectsDuplicateSourceSessions() {
    // The same session counted twice would inflate the calibration count.
    let repeated = UUID()
    let ids = [repeated, repeated, UUID(), UUID(), UUID()]

    #expect(throws: Baseline.ValidationError.duplicateSourceSessions) {
        try Baseline(
            id: UUID(), mode: .quickTest, stats: [], cadenceBPM: 104,
            algorithmVersion: "1.0.0", establishedAt: Date(), sourceSessionIDs: ids
        )
    }
}

@Test func baselineCarriesItsModeAndAlgorithmVersion() {
    let baseline = Baseline.fixture(mode: .fullTest, algorithmVersion: "1.2.0")

    // [PRD OQ-5] mode belongs on Baseline, not just on GaitSession.
    #expect(baseline.mode == .fullTest)
    // docs/09 §9.6: a baseline is only comparable under its algorithm version.
    #expect(baseline.algorithmVersion == "1.2.0")
    #expect(baseline.sourceSessionIDs.count == 5)
}

@Test func baselineLooksUpStatsByMetric() {
    let baseline = Baseline.fixture()

    #expect(baseline.stat(for: .stepRegularity)?.mean == 0.80)
    #expect(baseline.stat(for: .cadenceMean) == nil)
    #expect(baseline.standardizedMetrics == [.stepRegularity, .stepTimeCV])
}

// MARK: - Metric stats

@Test func statRecordsWhetherTheSDFloorWasApplied() throws {
    // The floor is PRD-required [PRD §7 AC]; the value is [OPEN] and lives in
    // AlgorithmConfiguration, so the stat only records that it was used.
    let floored = BaselineMetricStat(metricID: .stepTimeCV, mean: 0.04, sd: 0.01, n: 5, sdFloorApplied: true)
    #expect(floored.sdFloorApplied)

    let data = try JSONEncoder().encode(floored)
    #expect(try JSONDecoder().decode(BaselineMetricStat.self, from: data) == floored)
}

// MARK: - BaselineState

@Test func stateReportsProgressTowardTheFiveSessionRequirement() {
    #expect(BaselineState.notStarted.validCount == 0)
    #expect(BaselineState.building(validCount: 3).validCount == 3)
    #expect(BaselineState.established(.fixture()).validCount == 5)

    #expect(BaselineState.notStarted.isEstablished == false)
    #expect(BaselineState.building(validCount: 4).isEstablished == false)
    #expect(BaselineState.established(.fixture()).isEstablished)
}

@Test func stateExposesTheBaselineOnlyWhenEstablished() {
    let baseline = Baseline.fixture()

    #expect(BaselineState.established(baseline).baseline == baseline)
    #expect(BaselineState.notStarted.baseline == nil)
    #expect(BaselineState.building(validCount: 4).baseline == nil)
}

@Test func audioOptionsFollowBaselineAvailability() {
    // [PRD §5] Step Feedback is pre-baseline only; the Metronome requires that
    // mode's baseline to exist (docs/10 §10.3).
    let building = BaselineState.building(validCount: 2)
    #expect(building.allowsStepFeedback)
    #expect(building.allowsMetronome == false)

    let established = BaselineState.established(.fixture())
    #expect(established.allowsMetronome)
    #expect(established.allowsStepFeedback == false)

    #expect(BaselineState.notStarted.allowsStepFeedback)
    #expect(BaselineState.notStarted.allowsMetronome == false)
}
