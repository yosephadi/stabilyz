import Foundation
@testable import Stabilyz

extension GaitSession {
    static func fixtureValid(
        id: UUID = UUID(),
        mode: TestMode = .quickTest,
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        validWalking: Duration = .seconds(95),
        metrics: GaitMetrics = .fixture(),
        score: SessionScore? = nil,
        provisionalScore: ProvisionalStabilityScore? = nil,
        audioConfig: SessionAudioConfig = .none,
        algorithmVersion: String = "1.0.0",
        interruptionCount: Int = 0,
        gapInfo: SessionGapInfo = .none
    ) -> GaitSession {
        GaitSession.valid(
            id: id,
            mode: mode,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(120),
            advertisedClockElapsed: mode.advertisedDuration,
            validWalkingDuration: validWalking,
            metrics: metrics,
            score: score,
            provisionalScore: provisionalScore,
            audioConfig: audioConfig,
            algorithmVersion: algorithmVersion,
            appVersion: "1.0",
            deviceModel: "iPhone17,1",
            interruptionCount: interruptionCount,
            gapInfo: gapInfo
        )
    }

    static func fixtureInvalid(
        id: UUID = UUID(),
        mode: TestMode = .quickTest,
        reason: InvalidReason = .insufficientValidWalking,
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> GaitSession {
        GaitSession.invalid(
            id: id,
            mode: mode,
            reason: reason,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(120),
            advertisedClockElapsed: mode.advertisedDuration,
            validWalkingDuration: .seconds(30),
            audioConfig: .none,
            algorithmVersion: "1.0.0",
            appVersion: "1.0",
            deviceModel: "iPhone17,1"
        )
    }
}

extension UserProfile {
    static func fixture(
        level: AmputationLevel = .transtibial,
        side: AmputationSide = .left,
        kLevel: KLevel? = .k3,
        prosthesisType: String? = "Ottobock C-Leg"
    ) -> UserProfile {
        try! UserProfile(
            id: UUID(),
            amputationLevel: level,
            side: side,
            timeSinceAmputationMonths: 24,
            prosthesisType: prosthesisType,
            kLevel: kLevel,
            disclaimerAcceptedAt: Date(timeIntervalSince1970: 1_700_000_000),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

extension PartialSessionScore {
    /// What the pipeline produces, for tests that do not run it.
    static func fixture(
        relativeIndex: Int = 112,
        compositeZ: Double = 0.12,
        algorithmVersion: String = AlgorithmConfiguration.v1.version,
        breakdown: [MetricBreakdown] = [],
        standardization: SessionStandardization? = nil
    ) -> PartialSessionScore {
        PartialSessionScore(
            relativeIndex: relativeIndex,
            compositeZ: compositeZ,
            algorithmVersion: algorithmVersion,
            breakdown: breakdown,
            standardization: standardization ?? SessionStandardization(
                mode: .quickTest, algorithmVersion: algorithmVersion,
                standardized: [], rawOnly: [], unmeasured: []
            )
        )
    }
}

extension ProvisionalStabilityScore {
    /// A pre-baseline score, for tests that do not run the scorer.
    ///
    /// The contributions are what the summary line rests on, so they are real
    /// rather than empty — a fixture with no contributions would exercise only
    /// the "nothing stood out" branch.
    static func fixture(
        value: Int = 76,
        gaitConsistency: Double = 0.82,
        stepTimeVariability: Double = 0.79,
        trunkMotion: Double = 0.63,
        algorithmVersion: String = "1.0.0"
    ) -> ProvisionalStabilityScore {
        ProvisionalStabilityScore(
            value: value,
            contributions: [
                Contribution(signal: .gaitConsistency, quality: gaitConsistency, weight: 0.5),
                Contribution(signal: .stepTimeVariability, quality: stepTimeVariability, weight: 0.25),
                Contribution(signal: .trunkMotion, quality: trunkMotion, weight: 0.25)
            ],
            algorithmVersion: algorithmVersion
        )
    }
}

extension SessionScore {
    /// A complete score. There is deliberately no way to build a partial one
    /// here — that is the point of the two types.
    static func fixture(
        relativeIndex: Int = 112,
        summaryLine: String = "This Quick Test was about usual for you."
    ) -> SessionScore {
        SessionScore(
            completing: .fixture(relativeIndex: relativeIndex),
            summaryLine: summaryLine
        )
    }
}
