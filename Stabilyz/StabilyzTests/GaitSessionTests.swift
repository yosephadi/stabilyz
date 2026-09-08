import Foundation
import Testing
@testable import Stabilyz

private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

extension GaitMetrics {
    /// Arbitrary but well-formed metrics for tests that do not care about values.
    static func fixture(stepTimeAsymmetry: Double? = nil) -> GaitMetrics {
        GaitMetrics(
            stepRegularity: 0.82,
            strideRegularity: 0.78,
            cadenceMean: 104,
            stepTimeCV: 0.041,
            trunkMotionML: 1.12,
            trunkMotionVT: 2.30,
            stepTimeAsymmetry: stepTimeAsymmetry,
            steps: 210,
            distance: 180,
            validStrideCount: 96,
            windowCount: 12
        )
    }
}

private func makeValid(
    mode: TestMode = .quickTest,
    score: SessionScore? = nil,
    validWalking: Duration = .seconds(95)
) -> GaitSession {
    GaitSession.valid(
        id: UUID(),
        mode: mode,
        startedAt: anchor,
        endedAt: anchor.addingTimeInterval(120),
        advertisedClockElapsed: .seconds(120),
        validWalkingDuration: validWalking,
        metrics: .fixture(),
        score: score,
        audioConfig: .none,
        algorithmVersion: "1.0.0",
        appVersion: "1.0",
        deviceModel: "iPhone17,1"
    )
}

private func makeInvalid(reason: InvalidReason, mode: TestMode = .quickTest) -> GaitSession {
    GaitSession.invalid(
        id: UUID(),
        mode: mode,
        reason: reason,
        startedAt: anchor,
        endedAt: anchor.addingTimeInterval(120),
        advertisedClockElapsed: .seconds(120),
        validWalkingDuration: .seconds(30),
        audioConfig: .none,
        algorithmVersion: "1.0.0",
        appVersion: "1.0",
        deviceModel: "iPhone17,1"
    )
}

// MARK: - Outcome

@Test func outcomeIsEitherValidOrInvalidNeverBoth() {
    #expect(SessionOutcome.valid.isValid)
    #expect(SessionOutcome.valid.invalidReason == nil)

    let invalid = SessionOutcome.invalid(reason: .excessiveNoise)
    #expect(invalid.isValid == false)
    #expect(invalid.invalidReason == .excessiveNoise)
}

@Test func invalidReasonsCoverThePRDNoisyPaths() {
    #expect(Set(InvalidReason.allCases.map(\.rawValue)) == [
        "insufficientValidWalking", "excessiveNoise", "unrecoverableInterruption", "sensorFailure"
    ])
}

// MARK: - The hard rule: invalid sessions are never scored

@Test func invalidSessionsCarryNoMetricsAndNoScore() {
    for reason in InvalidReason.allCases {
        let session = makeInvalid(reason: reason)

        #expect(session.metrics == nil)
        #expect(session.score == nil)
        #expect(session.outcome == .invalid(reason: reason))
    }
}

@Test func invalidSessionsAreExcludedFromBaselineHistoryAndExport() {
    let session = makeInvalid(reason: .insufficientValidWalking)

    // [PRD §5, §6, §7] never scored, never baseline-counted, never shown, never exported.
    #expect(session.isValid == false)
    #expect(session.countsTowardBaseline == false)
    #expect(session.isUserVisible == false)
}

@Test func validSessionsCarryMetricsAndCountTowardBaseline() {
    let session = makeValid()

    #expect(session.metrics != nil)
    #expect(session.countsTowardBaseline)
    #expect(session.isUserVisible)
}

@Test func aValidSessionCanExistWithoutAScoreBeforeTheBaseline() {
    // Sessions 1-5 of a mode are valid but unscored [PRD §7].
    let building = makeValid(score: nil)
    #expect(building.isValid)
    #expect(building.score == nil)
    #expect(building.countsTowardBaseline)

    let scored = makeValid(score: SessionScore(relativeIndex: 112))
    #expect(scored.score?.relativeIndex == 112)
}

// MARK: - Clock length vs valid walking

@Test func advertisedElapsedAndValidWalkingAreSeparateQuantities() {
    // A session can run the full clock and still fail [PRD OQ-3].
    let session = makeInvalid(reason: .insufficientValidWalking)

    #expect(session.advertisedClockElapsed == .seconds(120))
    #expect(session.validWalkingDuration == .seconds(30))
    #expect(session.validWalkingDuration < SessionPolicy.v1.minimumValidWalkingDuration(for: .quickTest))
}

// MARK: - Audio config

@Test func audioConfigCannotCarryABPMWithoutTheMetronome() {
    // The invariant is structural: there is no representable state with a BPM
    // and no metronome, or a metronome and no BPM.
    #expect(SessionAudioConfig.metronome(bpm: 108) != .stepFeedback)
    #expect(SessionAudioConfig.none != .stepFeedback)

    if case .metronome(let bpm) = SessionAudioConfig.metronome(bpm: 108) {
        #expect(bpm == 108)
    } else {
        Issue.record("expected metronome case")
    }
}

@Test func audioConfigRoundTripsThroughCoding() throws {
    for config in [SessionAudioConfig.none, .stepFeedback, .metronome(bpm: 104.5)] {
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(SessionAudioConfig.self, from: data) == config)
    }
}

// MARK: - Gap info

@Test func gapInfoDefaultsToNoGaps() throws {
    #expect(SessionGapInfo.none.gapCount == 0)
    #expect(makeValid().gapInfo == .none)
    #expect(makeValid().interruptionCount == 0)

    let gaps = SessionGapInfo(gapCount: 2, totalGapDuration: .seconds(9), longestGapDuration: .seconds(6))
    let data = try JSONEncoder().encode(gaps)
    #expect(try JSONDecoder().decode(SessionGapInfo.self, from: data) == gaps)
}
