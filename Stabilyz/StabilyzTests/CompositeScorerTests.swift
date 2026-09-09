import Foundation
import Testing
@testable import Stabilyz

private let config = AlgorithmConfiguration.v1
private let base = Date(timeIntervalSince1970: 1_700_000_000)
private let version = config.version

private func metrics(
    ad1: Double = 0.80, ad2: Double = 0.78, cadence: Double = 109,
    cv: Double = 0.04, trunkML: Double = 1.0, trunkVT: Double = 2.0,
    asymmetry: Double? = 0.09
) -> GaitMetrics {
    GaitMetrics(
        stepRegularity: ad1, strideRegularity: ad2, cadenceMean: cadence,
        stepTimeCV: cv, trunkMotionML: trunkML, trunkMotionVT: trunkVT,
        stepTimeAsymmetry: asymmetry, steps: nil, distance: nil,
        validStrideCount: 100, windowCount: 10
    )
}

private func session(_ index: Int, metrics: GaitMetrics, algorithmVersion: String = version) -> GaitSession {
    let start = base.addingTimeInterval(Double(index) * 86_400)
    return GaitSession.valid(
        id: UUID(), mode: .quickTest, startedAt: start,
        endedAt: start.addingTimeInterval(120),
        advertisedClockElapsed: .seconds(120), validWalkingDuration: .seconds(110),
        metrics: metrics, audioConfig: .none, algorithmVersion: algorithmVersion,
        appVersion: "1.0", deviceModel: "iPhone17,1"
    )
}

/// Five calibration sessions whose values vary, so the baseline has a real
/// spread rather than a floored one.
private let calibrationValues: [(ad1: Double, ad2: Double, cv: Double, ml: Double, vt: Double)] = [
    (0.70, 0.68, 0.030, 0.80, 1.60),
    (0.75, 0.73, 0.035, 0.90, 1.80),
    (0.80, 0.78, 0.040, 1.00, 2.00),
    (0.85, 0.83, 0.045, 1.10, 2.20),
    (0.90, 0.88, 0.050, 1.20, 2.40)
]

private func calibrationSessions() -> [GaitSession] {
    calibrationValues.enumerated().map { index, value in
        session(index, metrics: metrics(
            ad1: value.ad1, ad2: value.ad2, cv: value.cv,
            trunkML: value.ml, trunkVT: value.vt
        ))
    }
}

private func buildBaseline(from sessions: [GaitSession]) throws -> Baseline {
    try BaselineCalculationService.calculate(
        from: sessions, mode: .quickTest, establishedAt: base, configuration: config
    )
}

private func scoreOf(_ metrics: GaitMetrics, against baseline: Baseline, sessionVersion: String = version) throws -> CompositeScorer.ScoringResult {
    let standardization = try #require(
        try BaselineNormalization.standardize(
            metrics: metrics, mode: .quickTest, against: baseline, configuration: config
        )
    )
    return CompositeScorer.score(
        standardization, sessionAlgorithmVersion: sessionVersion, configuration: config
    )
}

// MARK: - Baseline performance is 100 by construction

@Test func fiveIdenticalCalibrationSessionsEachScoreExactlyOneHundred() throws {
    // Every metric equals its own mean, so every z is zero and the composite is
    // zero — the index is exactly the centre, not approximately.
    let identical = (0..<5).map { session($0, metrics: metrics()) }
    let baseline = try buildBaseline(from: identical)

    let result = try scoreOf(metrics(), against: baseline)
    let score = try #require(result.score)

    #expect(score.relativeIndex == 100)
    #expect(score.compositeZ == 0)
}

@Test func acrossTheFiveCalibrationSessionsTheCompositesSumToZero() throws {
    // Each metric's z-scores sum to zero by definition of the mean, so the five
    // composites do too — the baseline sits at the centre of its own inputs.
    let sessions = calibrationSessions()
    let baseline = try buildBaseline(from: sessions)

    var total = 0.0
    for session in sessions {
        let result = try scoreOf(try #require(session.metrics), against: baseline)
        total += try #require(result.score?.compositeZ)
    }

    #expect(abs(total) < 1e-9)
}

// MARK: - The PRD's worked example [PRD §7]

@Test func aSessionTwelveHundredthsOfAnSDBetterScoresOneHundredAndTwelve() throws {
    // Constructed at exactly +0.12 direction-adjusted SD on all four terms, so
    // composite = 0.12 and index = round(100 + 100 × 0.12) = 112.
    let baseline = try buildBaseline(from: calibrationSessions())

    func stat(_ metric: MetricID) throws -> BaselineMetricStat {
        try #require(baseline.stat(for: metric))
    }
    let offset = 0.12

    let ad1 = try stat(.stepRegularity)
    let ad2 = try stat(.strideRegularity)
    let cv = try stat(.stepTimeCV)
    let ml = try stat(.trunkMotionML)
    let vt = try stat(.trunkMotionVT)

    let sixth = metrics(
        // Higher is better: move up.
        ad1: ad1.mean + offset * ad1.sd,
        ad2: ad2.mean + offset * ad2.sd,
        // Lower is better: move down, so the adjusted z is also +0.12.
        cv: cv.mean - offset * cv.sd,
        trunkML: ml.mean - offset * ml.sd,
        trunkVT: vt.mean - offset * vt.sd
    )

    let result = try scoreOf(sixth, against: baseline)
    let score = try #require(result.score)

    #expect(abs(try #require(score.compositeZ) - 0.12) < 1e-9)
    #expect(score.relativeIndex == 112)
}

@Test func betterOnEveryTermScoresAboveOneHundredAndWorseBelow() throws {
    let baseline = try buildBaseline(from: calibrationSessions())
    func stat(_ metric: MetricID) throws -> BaselineMetricStat { try #require(baseline.stat(for: metric)) }

    let ad1 = try stat(.stepRegularity), ad2 = try stat(.strideRegularity)
    let cv = try stat(.stepTimeCV), ml = try stat(.trunkMotionML), vt = try stat(.trunkMotionVT)

    let better = metrics(
        ad1: ad1.mean + ad1.sd, ad2: ad2.mean + ad2.sd,
        cv: cv.mean - cv.sd, trunkML: ml.mean - ml.sd, trunkVT: vt.mean - vt.sd
    )
    let worse = metrics(
        ad1: ad1.mean - ad1.sd, ad2: ad2.mean - ad2.sd,
        cv: cv.mean + cv.sd, trunkML: ml.mean + ml.sd, trunkVT: vt.mean + vt.sd
    )

    let betterIndex = try #require(try scoreOf(better, against: baseline).score?.relativeIndex)
    let worseIndex = try #require(try scoreOf(worse, against: baseline).score?.relativeIndex)

    // One SD better on every term is exactly +100 points.
    #expect(betterIndex == 200)
    #expect(worseIndex == 0)
    #expect(betterIndex > 100)
    #expect(worseIndex < 100)
}

@Test func theIndexIsClampedRatherThanRunningAway() throws {
    let baseline = try buildBaseline(from: calibrationSessions())
    let ad1 = try #require(baseline.stat(for: .stepRegularity))

    let extreme = metrics(ad1: ad1.mean + 50 * ad1.sd)
    let score = try #require(try scoreOf(extreme, against: baseline).score)

    #expect(score.relativeIndex <= 200)
    #expect(config.composite.indexRange.contains(score.relativeIndex))
}

// MARK: - Exactly four terms, asymmetry never among them

@Test func theCompositeAlwaysHasExactlyFourTerms() throws {
    let baseline = try buildBaseline(from: calibrationSessions())
    let result = try scoreOf(metrics(), against: baseline)

    #expect(result.terms.count == 4)
    #expect(Set(result.terms.map(\.term)) == Set(CompositeTerm.allCases))
}

@Test func asymmetryIsStandardizedButNeverEntersTheComposite() throws {
    // [PRD §7, docs/decisions.md entries 2 and 13] the feature is distinct, not
    // merged into a single number.
    let baseline = try buildBaseline(from: calibrationSessions())
    let standardization = try #require(
        try BaselineNormalization.standardize(
            metrics: metrics(asymmetry: 0.20), mode: .quickTest,
            against: baseline, configuration: config
        )
    )
    // It is standardized and available for display.
    #expect(standardization.standardization(for: .stepTimeAsymmetry) != nil)

    let result = CompositeScorer.score(
        standardization, sessionAlgorithmVersion: version, configuration: config
    )
    #expect(result.terms.contains { $0.term.rawValue.contains("symmetry") } == false)
    #expect(result.terms.count == 4)
}

@Test func aWildlyDifferentAsymmetryDoesNotMoveTheIndex() throws {
    // The strongest form of the claim: change only asymmetry and the score is
    // byte-identical.
    let baseline = try buildBaseline(from: calibrationSessions())

    let low = try scoreOf(metrics(asymmetry: 0.01), against: baseline)
    let high = try scoreOf(metrics(asymmetry: 0.40), against: baseline)
    let absent = try scoreOf(metrics(asymmetry: nil), against: baseline)

    #expect(low.score == high.score)
    #expect(low.score == absent.score)
}

@Test func theTrunkTermAveragesItsTwoAxes() throws {
    let baseline = try buildBaseline(from: calibrationSessions())
    let ml = try #require(baseline.stat(for: .trunkMotionML))
    let vt = try #require(baseline.stat(for: .trunkMotionVT))

    // ML one SD better, VT at baseline: the term is the mean of +1 and 0.
    let sample = metrics(trunkML: ml.mean - ml.sd, trunkVT: vt.mean)
    let result = try scoreOf(sample, against: baseline)
    let trunk = try #require(result.terms.first { $0.term == .trunkProxy })

    #expect(abs(trunk.adjustedZ - 0.5) < 1e-9)
}

// MARK: - Missing terms: no score, no renormalisation

@Test func aMissingCompositeTermMeansNoScoreAtAll() throws {
    // Renormalising the surviving weights would present a three-term score on
    // the same 100-centred scale as a four-term one.
    let baseline = try buildBaseline(from: calibrationSessions())
    let partial = try #require(
        try BaselineNormalization.standardize(
            metrics: metrics(), mode: .quickTest,
            // A baseline missing the step-time-CV stat.
            against: try Baseline(
                id: UUID(), mode: .quickTest,
                stats: baseline.stats.filter { $0.metricID != .stepTimeCV },
                cadenceBPM: baseline.cadenceBPM, algorithmVersion: baseline.algorithmVersion,
                establishedAt: baseline.establishedAt, sourceSessionIDs: baseline.sourceSessionIDs
            ),
            configuration: config
        )
    )

    let result = CompositeScorer.score(
        partial, sessionAlgorithmVersion: version, configuration: config
    )

    #expect(result.score == nil)
    #expect(result.unavailability == .missingCompositeTerm)
    #expect(result.terms.isEmpty)
}

@Test func halfATrunkProxyIsNotATrunkProxy() throws {
    let baseline = try buildBaseline(from: calibrationSessions())
    let partial = try #require(
        try BaselineNormalization.standardize(
            metrics: metrics(), mode: .quickTest,
            against: try Baseline(
                id: UUID(), mode: .quickTest,
                stats: baseline.stats.filter { $0.metricID != .trunkMotionVT },
                cadenceBPM: baseline.cadenceBPM, algorithmVersion: baseline.algorithmVersion,
                establishedAt: baseline.establishedAt, sourceSessionIDs: baseline.sourceSessionIDs
            ),
            configuration: config
        )
    )

    let result = CompositeScorer.score(partial, sessionAlgorithmVersion: version, configuration: config)
    #expect(result.score == nil)
    #expect(result.unavailability == .missingCompositeTerm)
}

// MARK: - Version validity (docs/09 §9.6)

@Test func aVersionMismatchProducesNoScore() throws {
    let baseline = try buildBaseline(from: calibrationSessions())
    let result = try scoreOf(metrics(), against: baseline, sessionVersion: "2.0.0-different")

    #expect(result.score == nil)
    #expect(result.unavailability == .algorithmVersionMismatch)
}

@Test func theScoreRecordsTheBaselinesVersion() throws {
    let sessions = calibrationValues.enumerated().map { index, value in
        session(index, metrics: metrics(
            ad1: value.ad1, ad2: value.ad2, cv: value.cv, trunkML: value.ml, trunkVT: value.vt
        ), algorithmVersion: "1.5.0-pinned")
    }
    let baseline = try buildBaseline(from: sessions)
    let result = try scoreOf(metrics(), against: baseline, sessionVersion: "1.5.0-pinned")

    #expect(try #require(result.score).algorithmVersion == "1.5.0-pinned")
    #expect(baseline.algorithmVersion == "1.5.0-pinned")
}

// MARK: - Direction orientation

@Test func higherCompositeAlwaysMeansMoreStable() throws {
    // Every term is direction-adjusted, so improving a lower-is-better metric
    // raises the index just as improving a higher-is-better one does.
    let baseline = try buildBaseline(from: calibrationSessions())
    let cv = try #require(baseline.stat(for: .stepTimeCV))

    let steadier = try scoreOf(metrics(cv: cv.mean - cv.sd), against: baseline)
    let baselineScore = try scoreOf(metrics(cv: cv.mean), against: baseline)

    let steadierIndex = try #require(steadier.score).relativeIndex
    let flatIndex = try #require(baselineScore.score).relativeIndex
    #expect(steadierIndex > flatIndex)
}
