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
