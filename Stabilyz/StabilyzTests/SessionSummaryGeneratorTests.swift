import Foundation
import Testing
@testable import Stabilyz

private let config = AlgorithmConfiguration.v1
private let base = Date(timeIntervalSince1970: 1_700_000_000)

private func metrics(
    ad1: Double = 0.80, ad2: Double = 0.78, cadence: Double = 109,
    cv: Double = 0.04, trunkML: Double = 1.0, trunkVT: Double = 2.0,
    asymmetry: Double? = 0.09
) -> GaitMetrics {
    GaitMetrics(
        stepRegularity: ad1, strideRegularity: ad2, cadenceMean: cadence,
        stepTimeCV: cv, trunkMotionML: trunkML, trunkMotionVT: trunkVT,
        stepTimeAsymmetry: asymmetry, steps: nil, distance: nil,
        validStrideCount: 100, windowCount: 10, asymmetryAffectedSide: .left
    )
}

private func stat(_ metric: MetricID, mean: Double, sd: Double) -> BaselineMetricStat {
    BaselineMetricStat(metricID: metric, mean: mean, sd: sd, n: 5, sdFloorApplied: false)
}

private let stats = [
    stat(.stepRegularity, mean: 0.80, sd: 0.05),
    stat(.strideRegularity, mean: 0.78, sd: 0.05),
    stat(.cadenceMean, mean: 109, sd: 3),
    stat(.stepTimeCV, mean: 0.04, sd: 0.01),
    stat(.trunkMotionML, mean: 1.0, sd: 0.1),
    stat(.trunkMotionVT, mean: 2.0, sd: 0.2),
    stat(.stepTimeAsymmetry, mean: 0.09, sd: 0.015)
]

private func baseline() -> Baseline {
    try! Baseline(
        id: UUID(), mode: .quickTest, stats: stats, cadenceBPM: 109,
        algorithmVersion: config.version, establishedAt: base,
        sourceSessionIDs: (0..<5).map { _ in UUID() }
    )
}

private func session(_ index: Int, mode: TestMode = .quickTest, metrics m: GaitMetrics, valid: Bool = true) -> GaitSession {
    let start = base.addingTimeInterval(Double(index) * 86_400)
    if valid {
        return GaitSession.valid(
            id: UUID(), mode: mode, startedAt: start, endedAt: start.addingTimeInterval(120),
            advertisedClockElapsed: mode.advertisedDuration, validWalkingDuration: .seconds(110),
            metrics: m, audioConfig: .none, algorithmVersion: config.version,
            appVersion: "1.0", deviceModel: "iPhone17,1"
        )
    }
    return GaitSession.invalid(
        id: UUID(), mode: mode, reason: .excessiveNoise, startedAt: start,
        endedAt: start.addingTimeInterval(120), advertisedClockElapsed: mode.advertisedDuration,
        validWalkingDuration: .seconds(30), audioConfig: .none,
        algorithmVersion: config.version, appVersion: "1.0", deviceModel: "iPhone17,1"
    )
}

private func summarize(
    _ current: GaitMetrics,
    index: Int,
    recent: [GaitSession] = [],
    mode: TestMode = .quickTest
) throws -> SessionSummaryGenerator.Summary? {
    let standardization = try BaselineNormalization.standardize(
        metrics: current, mode: mode, against: baseline(), configuration: config
    )
    return SessionSummaryGenerator.summary(
        mode: mode, metrics: current, standardization: standardization,
        score: SessionScore(relativeIndex: index, compositeZ: 0, algorithmVersion: config.version),
        recentSessions: recent, configuration: config
    )
}

/// Three recent same-mode sessions with an average step regularity of 0.70 —
/// well below the 0.80 baseline mean, so a current 0.80 is a clear improvement
/// against them.
private func recentWeakConsistency() -> [GaitSession] {
    (0..<3).map { session($0, metrics: metrics(ad1: 0.70, ad2: 0.68)) }
}

/// Three recent same-mode sessions matching the current one exactly.
private func recentIdentical() -> [GaitSession] {
    (0..<3).map { session($0, metrics: metrics()) }
}

// MARK: - The percentage guard [PRD §5, §7]

@Test func theSummaryNeverContainsAPercentageSign() throws {
    // The composite is not calibrated to support "12% more stable", so the
    // summary must never quantify in percent — checked across every branch.
    let cases: [(GaitMetrics, Int, [GaitSession])] = [
        (metrics(), 112, recentWeakConsistency()),
        (metrics(), 100, recentWeakConsistency()),
        (metrics(), 112, []),
        (metrics(), 100, recentIdentical()),
        (metrics(), 80, recentIdentical()),
        (metrics(), 100, [])
    ]

    for (sample, index, recent) in cases {
        let summary = try #require(try summarize(sample, index: index, recent: recent))
        #expect(summary.text.contains("%") == false, "percentage in: \(summary.text)")
        #expect(summary.text.localizedCaseInsensitiveContains("percent") == false)
    }
}

@Test func everyBranchIsExercisedByThePercentageGuard() throws {
    // The guard above is only meaningful if it reaches every claim.
    var seen: Set<SessionSummaryGenerator.Claim> = []
    let cases: [(GaitMetrics, Int, [GaitSession])] = [
        (metrics(), 112, recentWeakConsistency()),
        (metrics(), 100, recentWeakConsistency()),
        (metrics(), 112, []),
        (metrics(), 100, recentIdentical()),
        (metrics(), 80, recentIdentical()),
        (metrics(), 100, [])
    ]
    for (sample, index, recent) in cases {
        seen.insert(try #require(try summarize(sample, index: index, recent: recent)).claim)
    }

    #expect(seen == [
        .aboveBaselineWithImprovement, .improvementOnly, .aboveBaseline,
        .aroundUsual, .belowBaseline, .neutral
    ])
}

// MARK: - Every predicate, both ways

@Test func anImprovementClaimAppearsOnlyWhenAMetricActuallyImproved() throws {
    // Present: recent sessions were weaker, so consistency really did improve.
    let improved = try #require(try summarize(metrics(), index: 100, recent: recentWeakConsistency()))
    #expect(improved.claim == .improvementOnly)
    #expect(improved.signal == .gaitConsistency)

    // Absent: recent sessions match the current one exactly.
    let flat = try #require(try summarize(metrics(), index: 100, recent: recentIdentical()))
    #expect(flat.claim == .aroundUsual)
    #expect(flat.signal == nil)
    #expect(flat.text.localizedCaseInsensitiveContains("steadier") == false)
}

@Test func aRegressionNeverProducesAnImprovementClaim() throws {
    // Recent sessions were *better* than this one.
    let recent = (0..<3).map { session($0, metrics: metrics(ad1: 0.95, ad2: 0.93)) }
    let summary = try #require(try summarize(metrics(ad1: 0.70, ad2: 0.68), index: 90, recent: recent))

    #expect(summary.signal == nil)
    #expect(summary.claim == .belowBaseline)
    #expect(summary.text.localizedCaseInsensitiveContains("steadier") == false)
    #expect(summary.text.localizedCaseInsensitiveContains("better") == false)
}

@Test func aChangeSmallerThanTheThresholdIsNotCalledAChange() throws {
    // Within an ordinary session-to-session wobble: 0.05 SD of movement, below
    // the 0.25 SD threshold.
    let recent = (0..<3).map { session($0, metrics: metrics(ad1: 0.7975, ad2: 0.7775)) }
    let summary = try #require(try summarize(metrics(), index: 100, recent: recent))

    #expect(summary.signal == nil)
    #expect(summary.claim == .aroundUsual)
}

@Test func aboveBaselineAppearsOnlyAboveTheMargin() throws {
    // Present.
    #expect(try #require(try summarize(metrics(), index: 112, recent: [])).claim == .aboveBaseline)
    // Absent: inside the margin is "about usual", not better.
    let inside = try #require(try summarize(metrics(), index: 102, recent: recentIdentical()))
    #expect(inside.claim == .aroundUsual)
}

@Test func belowBaselineAppearsOnlyBelowTheMargin() throws {
    #expect(try #require(try summarize(metrics(), index: 80, recent: recentIdentical())).claim == .belowBaseline)
    let inside = try #require(try summarize(metrics(), index: 98, recent: recentIdentical()))
    #expect(inside.claim == .aroundUsual)
}

@Test func theCombinedClaimNeedsBothItsConditions() throws {
    // Both present.
    let both = try #require(try summarize(metrics(), index: 112, recent: recentWeakConsistency()))
    #expect(both.claim == .aboveBaselineWithImprovement)

    // Index high, no improvement → the weaker claim only.
    #expect(try #require(try summarize(metrics(), index: 112, recent: recentIdentical())).claim == .aboveBaseline)
    // Improvement, index flat → the other weaker claim only.
    #expect(try #require(try summarize(metrics(), index: 100, recent: recentWeakConsistency())).claim == .improvementOnly)
}

@Test func aSignalOnlyCountsIfEveryMetricBehindItImproved() throws {
    // ML improves, VT worsens. Half a trunk proxy improving is not the trunk
    // proxy improving.
    let recent = (0..<3).map { session($0, metrics: metrics(trunkML: 1.3, trunkVT: 1.7)) }
    let summary = try #require(try summarize(metrics(trunkML: 1.0, trunkVT: 2.0), index: 100, recent: recent))

    #expect(summary.signal != .trunkMotion)
}

// MARK: - No verdict where none was decided [entry 3]

@Test func cadenceAndAsymmetryCanNeverProduceAnImprovementClaim() throws {
    // Neither has a decided direction, so a large move in either must not be
    // reported as better.
    let recent = (0..<3).map { session($0, metrics: metrics(cadence: 90, asymmetry: 0.30)) }
    let summary = try #require(try summarize(metrics(cadence: 125, asymmetry: 0.02), index: 100, recent: recent))

    #expect(summary.signal != .cadence)
    #expect(summary.signal != .stepTimeAsymmetry)
    #expect(summary.claim == .aroundUsual)
}

// MARK: - Same mode only [PRD OQ-5]

@Test func otherModeHistoryIsIgnored() throws {
    // Full Test sessions that would look like a large improvement, mixed in
    // with Quick Test history that shows none.
    let mixed = (0..<3).map { session($0, mode: .fullTest, metrics: metrics(ad1: 0.40, ad2: 0.38)) }
        + recentIdentical()

    let summary = try #require(try summarize(metrics(), index: 100, recent: mixed))

    #expect(summary.signal == nil)
    #expect(summary.claim == .aroundUsual)
    #expect(summary.text.localizedCaseInsensitiveContains("Quick Test"))
}

@Test func onlyOtherModeHistoryLeavesNothingToCompareAgainst() throws {
    let otherModeOnly = (0..<3).map { session($0, mode: .fullTest, metrics: metrics(ad1: 0.40)) }
    let summary = try #require(try summarize(metrics(), index: 100, recent: otherModeOnly))

    #expect(summary.claim == .neutral)
}

@Test func invalidSessionsAreNotComparedAgainst() throws {
    // [PRD] invalid sessions are excluded everywhere they could mislead.
    let invalid = (0..<3).map { session($0, metrics: metrics(ad1: 0.40, ad2: 0.38), valid: false) }
    let summary = try #require(try summarize(metrics(), index: 100, recent: invalid))

    #expect(summary.signal == nil)
    #expect(summary.claim == .neutral)
}

@Test func onlyTheConfiguredNumberOfRecentSessionsIsUsed() throws {
    // Ten weak sessions, but the three most recent match the current one, so
    // there is no improvement to report.
    let old = (0..<7).map { session($0, metrics: metrics(ad1: 0.40, ad2: 0.38)) }
    let recent = (7..<10).map { session($0, metrics: metrics()) }
    let summary = try #require(try summarize(metrics(), index: 100, recent: old + recent))

    #expect(config.summary.recentSessionCount == 3)
    #expect(summary.signal == nil)
}

// MARK: - Pre-baseline and fallback

@Test func thereIsNoSummaryBeforeABaselineExists() throws {
    // The pre-baseline Score screen shows "Session X of 5" and no score; a
    // summary with nothing to compare against would be the static string
    // [PRD] rules out.
    let summary = SessionSummaryGenerator.summary(
        mode: .quickTest, metrics: metrics(), standardization: nil, score: nil,
        recentSessions: recentIdentical(), configuration: config
    )
    #expect(summary == nil)
}

@Test func theFallbackIsHonestWhenThereIsNothingNotableToSay() throws {
    let summary = try #require(try summarize(metrics(), index: 100, recent: []))

    #expect(summary.claim == .neutral)
    #expect(summary.signal == nil)
    #expect(summary.text.isEmpty == false)
    // No claim of improvement it cannot support.
    #expect(summary.text.localizedCaseInsensitiveContains("steadier") == false)
    #expect(summary.text.localizedCaseInsensitiveContains("improv") == false)
}

// MARK: - Tone and copy rules

@Test func theCopyUsesNoMedicalLanguage() throws {
    let forbidden = [
        "diagnos", "symptom", "treatment", "therapy", "clinical", "normal gait",
        "abnormal", "impair", "pathol", "prognos", "recovery"
    ]
    for (index, recent) in [(112, recentWeakConsistency()), (100, recentIdentical()), (80, recentIdentical()), (100, [])] {
        let summary = try #require(try summarize(metrics(), index: index, recent: recent))
        for term in forbidden {
            #expect(
                summary.text.localizedCaseInsensitiveContains(term) == false,
                "medical language '\(term)' in: \(summary.text)"
            )
        }
    }
}

@Test func theCopyNeverImpliesTheBaselineIsPermanent() throws {
    // [PRD §6] the baseline is a snapshot of five early sessions, not a verdict.
    let forbidden = ["permanent", "always", "never improve", "fixed", "final", "your normal is"]
    for (index, recent) in [(112, recentWeakConsistency()), (80, recentIdentical()), (100, [])] {
        let summary = try #require(try summarize(metrics(), index: index, recent: recent))
        for term in forbidden {
            #expect(summary.text.localizedCaseInsensitiveContains(term) == false, "in: \(summary.text)")
        }
    }
}

@Test func aBelowBaselineSessionIsStatedPlainlyAndNotAsAFailure() throws {
    let summary = try #require(try summarize(metrics(), index: 80, recent: recentIdentical()))

    #expect(summary.claim == .belowBaseline)
    // It says walking varies, rather than implying something is wrong.
    #expect(summary.text.localizedCaseInsensitiveContains("varies"))
    #expect(summary.text.localizedCaseInsensitiveContains("worse") == false)
    #expect(summary.text.localizedCaseInsensitiveContains("poor") == false)
}

@Test func theConsistencySignalIsNeverCalledSymmetryInCopy() throws {
    let summary = try #require(try summarize(metrics(), index: 112, recent: recentWeakConsistency()))

    #expect(summary.signal == .gaitConsistency)
    #expect(summary.text.localizedCaseInsensitiveContains("gait consistency"))
    #expect(summary.text.localizedCaseInsensitiveContains("symmetr") == false)
}

@Test func theSummaryNamesTheModeItComparedWithin() throws {
    let quick = try #require(try summarize(metrics(), index: 112, recent: []))
    #expect(quick.text.localizedCaseInsensitiveContains("Quick Test"))
}

@Test func theSummaryIsOneOrTwoSentences() throws {
    for (index, recent) in [(112, recentWeakConsistency()), (100, recentWeakConsistency()), (112, []), (80, recentIdentical()), (100, [])] {
        let summary = try #require(try summarize(metrics(), index: index, recent: recent))
        let sentences = summary.text.split(whereSeparator: { $0 == "." }).count
        #expect(sentences >= 1 && sentences <= 2, "\(sentences) sentences in: \(summary.text)")
    }
}

// MARK: - Determinism

@Test func theSameInputsAlwaysProduceTheSameSentence() throws {
    let recent = recentWeakConsistency()
    let first = try #require(try summarize(metrics(), index: 112, recent: recent))
    let second = try #require(try summarize(metrics(), index: 112, recent: recent))
    let third = try #require(try summarize(metrics(), index: 112, recent: recent))

    #expect(first == second)
    #expect(second == third)
}
