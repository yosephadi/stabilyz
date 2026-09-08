import Foundation
import Testing
@testable import Stabilyz

private let acceptedAt = Date(timeIntervalSince1970: 1_700_000_000)

private func makeProfile(
    level: AmputationLevel,
    side: AmputationSide,
    months: Int = 24,
    prosthesisType: String? = nil,
    kLevel: KLevel? = nil
) throws -> UserProfile {
    try UserProfile(
        id: UUID(),
        amputationLevel: level,
        side: side,
        timeSinceAmputationMonths: months,
        prosthesisType: prosthesisType,
        kLevel: kLevel,
        disclaimerAcceptedAt: acceptedAt,
        createdAt: acceptedAt
    )
}

// MARK: - Level / side consistency

@Test func bilateralRequiresBothSides() throws {
    #expect(try makeProfile(level: .bilateral, side: .both).side == .both)

    for side in [AmputationSide.left, .right] {
        #expect(throws: UserProfile.ValidationError.bilateralRequiresBothSides(actual: side)) {
            try makeProfile(level: .bilateral, side: side)
        }
    }
}

@Test func unilateralRequiresASingleSide() throws {
    for level in [AmputationLevel.transtibial, .transfemoral] {
        #expect(try makeProfile(level: level, side: .left).side == .left)
        #expect(try makeProfile(level: level, side: .right).side == .right)

        #expect(throws: UserProfile.ValidationError.unilateralRequiresASingleSide(level: level)) {
            try makeProfile(level: level, side: .both)
        }
    }
}

@Test func timeSinceAmputationCannotBeNegative() {
    #expect(throws: UserProfile.ValidationError.negativeTimeSinceAmputation(months: -1)) {
        try makeProfile(level: .transtibial, side: .left, months: -1)
    }
}

// MARK: - Optional fields

@Test func prosthesisTypeAndKLevelAreOptional() throws {
    let sparse = try makeProfile(level: .transtibial, side: .left)
    #expect(sparse.prosthesisType == nil)
    #expect(sparse.kLevel == nil)

    let full = try makeProfile(level: .transtibial, side: .left, prosthesisType: "Ottobock C-Leg", kLevel: .k3)
    #expect(full.prosthesisType == "Ottobock C-Leg")
    #expect(full.kLevel == .k3)
}

// MARK: - Asymmetry eligibility

@Test func onlyUnilateralUsersAreEligibleForStepTimeAsymmetry() throws {
    // [PRD §7, OQ-1] never fabricated for bilateral users.
    #expect(try makeProfile(level: .transtibial, side: .left).supportsStepTimeAsymmetry)
    #expect(try makeProfile(level: .transfemoral, side: .right).supportsStepTimeAsymmetry)
    #expect(try makeProfile(level: .bilateral, side: .both).supportsStepTimeAsymmetry == false)
}

// MARK: - Disclaimer gate

@Test func aProfileCannotExistWithoutDisclaimerAcceptance() throws {
    // The gate is structural: disclaimerAcceptedAt is non-optional, so there is
    // no representable profile that skipped it [PRD §7].
    let profile = try makeProfile(level: .transtibial, side: .left)
    #expect(profile.disclaimerAcceptedAt == acceptedAt)
}
