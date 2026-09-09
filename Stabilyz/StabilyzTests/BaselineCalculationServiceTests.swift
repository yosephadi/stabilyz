import Foundation
import Testing
@testable import Stabilyz

private let config = AlgorithmConfiguration.v1
private let base = Date(timeIntervalSince1970: 1_700_000_000)

/// Metrics with every value controllable, so a test can state the arithmetic it
/// expects rather than eyeballing a pipeline output.
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
        stepTimeAsymmetry: asymmetry,
        steps: nil, distance: nil,
        validStrideCount: 100, windowCount: 10
    )
}

private func session(
    _ index: Int,
    mode: TestMode = .quickTest,
    metrics: GaitMetrics = metrics(),
    valid: Bool = true,
    algorithmVersion: String = "1.0.0-provisional",
    startedAt: Date? = nil
) -> GaitSession {
    let start = startedAt ?? base.addingTimeInterval(Double(index) * 86_400)
    if valid {
        return GaitSession.valid(
            id: UUID(), mode: mode, startedAt: start,
            endedAt: start.addingTimeInterval(120),
            advertisedClockElapsed: mode.advertisedDuration,
            validWalkingDuration: .seconds(110), metrics: metrics,
            audioConfig: .none, algorithmVersion: algorithmVersion,
            appVersion: "1.0", deviceModel: "iPhone17,1"
        )
    }
    return GaitSession.invalid(
        id: UUID(), mode: mode, reason: .excessiveNoise, startedAt: start,
        endedAt: start.addingTimeInterval(120),
        advertisedClockElapsed: mode.advertisedDuration,
        validWalkingDuration: .seconds(30), audioConfig: .none,
        algorithmVersion: algorithmVersion, appVersion: "1.0", deviceModel: "iPhone17,1"
    )
}

private func calculate(_ sessions: [GaitSession], mode: TestMode = .quickTest) throws -> Baseline {
    try BaselineCalculationService.calculate(
        from: sessions, mode: mode, establishedAt: base.addingTimeInterval(500_000),
        configuration: config
    )
}

// MARK: - Closed-form arithmetic

@Test func meanAndSampleStandardDeviationAreExact() throws {
    // Ad1 across the five sessions: 1, 2, 3, 4, 5.
    // Mean = 3. Sample SD = sqrt(10 / 4) = sqrt(2.5).
    let sessions = (0..<5).map { session($0, metrics: metrics(ad1: Double($0 + 1))) }
    let baseline = try calculate(sessions)
    let stat = try #require(baseline.stat(for: .stepRegularity))

    #expect(stat.mean == 3)
    #expect(abs(stat.sd - 2.5.squareRoot()) < 1e-12)
    #expect(stat.n == 5)
}

@Test func theSampleEstimatorIsUsedNotThePopulationOne() throws {
    // With n = 5 the two differ by about 12%, which changes every later
    // z-score. Population SD of 1..5 is sqrt(2); sample SD is sqrt(2.5).
    let sessions = (0..<5).map { session($0, metrics: metrics(ad1: Double($0 + 1))) }
    let stat = try #require(try calculate(sessions).stat(for: .stepRegularity))

    #expect(abs(stat.sd - 2.5.squareRoot()) < 1e-12)
    #expect(abs(stat.sd - 2.0.squareRoot()) > 0.15)
}

@Test func identicalSessionsGiveZeroObservedSpreadAndTheFlooredSD() throws {
    // The case the PRD-required floor exists for [PRD §7 AC]: five near-identical
    // calibration sessions would otherwise divide by ~0 forever after.
    let sessions = (0..<5).map { session($0, metrics: metrics(ad1: 0.80)) }
    let stat = try #require(try calculate(sessions).stat(for: .stepRegularity))

    #expect(stat.mean == 0.80)
    #expect(stat.sdFloorApplied)
    // 5% of the 0.80 mean beats the 0.02 absolute floor.
    #expect(abs(stat.sd - 0.04) < 1e-9)
}

@Test func aHealthySpreadIsLeftAloneAndTheFlagIsFalse() throws {
    // Ad1 spread wide enough that no floor applies: 0.1 ... 0.9.
    let values = [0.1, 0.3, 0.5, 0.7, 0.9]
    let sessions = values.enumerated().map { session($0.offset, metrics: metrics(ad1: $0.element)) }
    let stat = try #require(try calculate(sessions).stat(for: .stepRegularity))

    #expect(abs(stat.mean - 0.5) < 1e-12)
    // Sample SD of that set is sqrt(0.4 / 4) * ... = sqrt(0.1) rounded: exactly
    // sqrt(sum((x-0.5)^2)/4) = sqrt(0.4/4) = sqrt(0.1).
    #expect(abs(stat.sd - 0.1.squareRoot()) < 1e-12)
    #expect(stat.sdFloorApplied == false)
}

@Test func cadenceBPMIsTheMeanOfTheFiveSessionCadences() throws {
    // docs/09 §9.2 [REC]. 100, 105, 110, 115, 120 → 110.
    let cadences = [100.0, 105, 110, 115, 120]
    let sessions = cadences.enumerated().map { session($0.offset, metrics: metrics(cadence: $0.element)) }

    #expect(try calculate(sessions).cadenceBPM == 110)
}

@Test func everyRegistryMetricGetsAStat() throws {
    let sessions = (0..<5).map { session($0) }
    let baseline = try calculate(sessions)

    for metric in MetricID.allCases {
        #expect(baseline.stat(for: metric) != nil, "\(metric.rawValue) has no stat")
    }
    #expect(baseline.standardizedMetrics.count == MetricID.allCases.count)
}

// MARK: - Asymmetry: present, thin, or absent

@Test func asymmetryIsComputedFromOnlyTheSessionsThatCarryIt() throws {
    // Three of five report a value: 0.06, 0.09, 0.12 → mean 0.09.
    let present: [Double?] = [0.06, nil, 0.09, nil, 0.12]
    let sessions = present.enumerated().map { session($0.offset, metrics: metrics(asymmetry: $0.element)) }
    let stat = try #require(try calculate(sessions).stat(for: .stepTimeAsymmetry))

    #expect(abs(stat.mean - 0.09) < 1e-12)
    // n records how many actually contributed, so the thinness is visible.
    #expect(stat.n == 3)
}

@Test func belowTheMinimumTheAsymmetryStatIsAbsentNotZero() throws {
    // Two of five is too thin a sample to describe a user's normal asymmetry.
    let present: [Double?] = [0.06, nil, nil, nil, 0.12]
    let sessions = present.enumerated().map { session($0.offset, metrics: metrics(asymmetry: $0.element)) }
    let baseline = try calculate(sessions)

    #expect(baseline.stat(for: .stepTimeAsymmetry) == nil)
    #expect(baseline.standardizedMetrics.contains(.stepTimeAsymmetry) == false)
}

@Test func aBilateralUsersSessionsProduceNoAsymmetryStatAtAll() throws {
    // None of the five carries a value [PRD §7, OQ-1].
    let sessions = (0..<5).map { session($0, metrics: metrics(asymmetry: nil)) }
    let baseline = try calculate(sessions)

    #expect(baseline.stat(for: .stepTimeAsymmetry) == nil)
    // Every other metric is unaffected.
    #expect(baseline.stat(for: .stepRegularity) != nil)
    #expect(baseline.standardizedMetrics.count == MetricID.allCases.count - 1)
}

@Test func exactlyTheMinimumIsEnough() throws {
    let present: [Double?] = [nil, 0.08, 0.09, 0.10, nil]
    let sessions = present.enumerated().map { session($0.offset, metrics: metrics(asymmetry: $0.element)) }
    let stat = try #require(try calculate(sessions).stat(for: .stepTimeAsymmetry))

    #expect(stat.n == config.baseline.minimumAsymmetrySessions)
    #expect(abs(stat.mean - 0.09) < 1e-12)
}

// MARK: - Refusals [PRD OQ-5, §6, §7]

@Test func fewerOrMoreThanFiveSessionsAreRefused() {
    #expect(throws: BaselineCalculationService.CalculationError.wrongSessionCount(expected: 5, actual: 4)) {
        try calculate((0..<4).map { session($0) })
    }
    #expect(throws: BaselineCalculationService.CalculationError.wrongSessionCount(expected: 5, actual: 6)) {
        try calculate((0..<6).map { session($0) })
    }
}

@Test func aSessionFromAnotherModeIsRefused() {
    // The one thing [PRD OQ-5] forbids outright.
    var sessions = (0..<5).map { session($0) }
    sessions[2] = session(2, mode: .fullTest)

    #expect(throws: BaselineCalculationService.CalculationError.mixedModes(expected: .quickTest, found: .fullTest)) {
        try calculate(sessions)
    }
}

@Test func anInvalidSessionIsRefused() {
    // Invalid sessions never count toward a baseline [PRD §6, §7].
    var sessions = (0..<5).map { session($0) }
    let bad = session(2, valid: false)
    sessions[2] = bad

    #expect(throws: BaselineCalculationService.CalculationError.invalidSessionIncluded(id: bad.id)) {
        try calculate(sessions)
    }
}

@Test func sessionsOutOfChronologicalOrderAreRefused() {
    // The baseline records the *first* five, so order carries meaning.
    var sessions = (0..<5).map { session($0) }
    sessions.swapAt(1, 3)

    #expect(throws: BaselineCalculationService.CalculationError.sessionsOutOfOrder) {
        try calculate(sessions)
    }
}

@Test func simultaneousSessionsAreRefusedAsOutOfOrder() {
    let sessions = (0..<5).map { session($0, startedAt: base) }

    #expect(throws: BaselineCalculationService.CalculationError.sessionsOutOfOrder) {
        try calculate(sessions)
    }
}

@Test func theSameSessionTwiceIsRefused() {
    let repeated = session(0)
    let sessions = [repeated, repeated] + (2..<5).map { session($0) }

    #expect(throws: BaselineCalculationService.CalculationError.duplicateSessions) {
        try calculate(sessions)
    }
}

@Test func sessionsFromDifferentAlgorithmVersionsAreRefused() {
    // docs/09 §9.6: a baseline is only comparable under the version that
    // produced its inputs.
    var sessions = (0..<5).map { session($0) }
    sessions[3] = session(3, algorithmVersion: "2.0.0")

    #expect(throws: BaselineCalculationService.CalculationError.mixedAlgorithmVersions) {
        try calculate(sessions)
    }
}

// MARK: - Stamping

@Test func theBaselineStampsTheSessionsAlgorithmVersionNotTheCurrentOne() throws {
    let sessions = (0..<5).map { session($0, algorithmVersion: "0.9.0-earlier") }
    let baseline = try calculate(sessions)

    #expect(baseline.algorithmVersion == "0.9.0-earlier")
    #expect(baseline.algorithmVersion != config.version)
}

@Test func sourceSessionIDsAreTheFiveInputsInOrder() throws {
    let sessions = (0..<5).map { session($0) }
    let baseline = try calculate(sessions)

    #expect(baseline.sourceSessionIDs == sessions.map(\.id))
    #expect(baseline.sourceSessionIDs.count == 5)
}

@Test func modeAndEstablishedAtAreRecorded() throws {
    let established = base.addingTimeInterval(500_000)
    let sessions = (0..<5).map { session($0, mode: .fullTest) }
    let baseline = try BaselineCalculationService.calculate(
        from: sessions, mode: .fullTest, establishedAt: established, configuration: config
    )

    #expect(baseline.mode == .fullTest)
    #expect(baseline.establishedAt == established)
}

// MARK: - Freezing is structural [PRD §6]

@Test func theServiceOffersNoWayToUpdateABaseline() throws {
    // There is no update, merge or recalculate entry point, and every Baseline
    // property is a `let`. A second calculation makes a *new* baseline; it
    // cannot alter an existing one. The repository refuses to store it
    // (Task 3.2.2), so freezing holds at both layers.
    let sessions = (0..<5).map { session($0) }
    let first = try calculate(sessions)
    let second = try calculate(sessions)

    #expect(first.id != second.id)
    #expect(first.stats == second.stats)
    #expect(first.cadenceBPM == second.cadenceBPM)
}

@Test func calculationIsDeterministicForTheSameInput() throws {
    let sessions = (0..<5).map { session($0, metrics: metrics(ad1: Double($0) * 0.1)) }
    let a = try calculate(sessions)
    let b = try calculate(sessions)

    #expect(a.stats == b.stats)
    #expect(a.cadenceBPM == b.cadenceBPM)
    #expect(a.sourceSessionIDs == b.sourceSessionIDs)
}
