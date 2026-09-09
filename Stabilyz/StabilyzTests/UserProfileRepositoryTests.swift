import Foundation
import SwiftData
import Testing
@testable import Stabilyz

private func makeRepository() throws -> SwiftDataUserProfileRepository {
    SwiftDataUserProfileRepository(container: try StoreContainer.make(inMemory: true))
}

@Test func noProfileExistsBeforeOnboardingCompletes() async throws {
    // nil is what the router reads as "not onboarded" (docs/11 §11.1).
    let repository = try makeRepository()
    #expect(try await repository.fetchProfile() == nil)
}

@Test func profileRoundTripsWithAllFields() async throws {
    let repository = try makeRepository()
    let profile = UserProfile.fixture(level: .transfemoral, side: .right, kLevel: .k4, prosthesisType: "Genium X3")

    try await repository.save(profile)

    #expect(try await repository.fetchProfile() == profile)
}

@Test func optionalFieldsSurviveAsNil() async throws {
    let repository = try makeRepository()
    try await repository.save(.fixture(kLevel: nil, prosthesisType: nil))

    let stored = try await repository.fetchProfile()
    #expect(stored?.kLevel == nil)
    #expect(stored?.prosthesisType == nil)
}

@Test func savingAgainReplacesRatherThanAddingASecondProfile() async throws {
    // docs/06 §6.3 uniqueness invariant: exactly one profile.
    let repository = try makeRepository()
    try await repository.save(.fixture(level: .transtibial, side: .left))
    try await repository.save(.fixture(level: .bilateral, side: .both))

    let stored = try await repository.fetchProfile()
    #expect(stored?.amputationLevel == .bilateral)
    #expect(stored?.side == .both)
}

@Test func disclaimerAcceptanceSurvivesTheRoundTrip() async throws {
    // The PRD §7 hard gate has to persist, or a relaunch would re-gate the user.
    let repository = try makeRepository()
    let profile = UserProfile.fixture()
    try await repository.save(profile)

    #expect(try await repository.fetchProfile()?.disclaimerAcceptedAt == profile.disclaimerAcceptedAt)
}
