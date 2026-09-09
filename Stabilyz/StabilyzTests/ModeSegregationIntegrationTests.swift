import Foundation
import Testing
@testable import Stabilyz

/// The anti-mixing guarantees from docs/09 §9.7, exercised end to end against a
/// real in-memory store rather than against doubles.

@Test func threeValidQuickAndTwoValidFullProduceNoBaselineAnywhere() async throws {
    // docs/09 §9.7 item 4 / [PRD §6 edge case] — the mandated integration test.
    let store = try InMemoryStore()

    for _ in 0..<3 { try await store.sessions.save(.fixtureValid(mode: .quickTest)) }
    for _ in 0..<2 { try await store.sessions.save(.fixtureValid(mode: .fullTest)) }

    #expect(try await store.baselineState(for: .quickTest) == .building(validCount: 3))
    #expect(try await store.baselineState(for: .fullTest) == .building(validCount: 2))
    #expect(try await store.baselines.allBaselines().isEmpty)
}

@Test func invalidSessionsDoNotAdvanceEitherModesCount() async throws {
    // [PRD §6, §7] a failed session never counts toward calibration.
    let store = try InMemoryStore()

    for _ in 0..<4 { try await store.sessions.save(.fixtureValid(mode: .quickTest)) }
    for reason in InvalidReason.allCases {
        try await store.sessions.save(.fixtureInvalid(mode: .quickTest, reason: reason))
    }

    #expect(try await store.baselineState(for: .quickTest) == .building(validCount: 4))
    #expect(BaselineStateMachine.isReadyToEstablish(
        validSessionCount: try await store.sessions.validSessionCount(mode: .quickTest),
        baseline: nil
    ) == false)
}

@Test func theFifthValidSessionMakesThatModeReadyToEstablish() async throws {
    let store = try InMemoryStore()
    for _ in 0..<5 { try await store.sessions.save(.fixtureValid(mode: .quickTest)) }

    let count = try await store.sessions.validSessionCount(mode: .quickTest)
    #expect(count == 5)
    #expect(BaselineStateMachine.isReadyToEstablish(validSessionCount: count, baseline: nil))

    try await store.baselines.save(.fixture(mode: .quickTest))
    #expect(try await store.baselineState(for: .quickTest).isEstablished)

    // The other mode is entirely unaffected [PRD OQ-5].
    #expect(try await store.baselineState(for: .fullTest) == .notStarted)
}

@Test func anEstablishedQuickBaselineLeavesFullStartingAtSessionOneOfFive() async throws {
    // [PRD §6] the new mode starts its own count, which must not read as a bug.
    let store = try InMemoryStore()
    for _ in 0..<6 { try await store.sessions.save(.fixtureValid(mode: .quickTest)) }
    try await store.baselines.save(.fixture(mode: .quickTest))

    try await store.sessions.save(.fixtureValid(mode: .fullTest))

    #expect(try await store.baselineState(for: .quickTest).isEstablished)
    #expect(try await store.baselineState(for: .fullTest) == .building(validCount: 1))
}

@Test func historyForAModeNeverContainsTheOtherModesSessions() async throws {
    let store = try InMemoryStore()
    for _ in 0..<3 { try await store.sessions.save(.fixtureValid(mode: .quickTest)) }
    for _ in 0..<2 { try await store.sessions.save(.fixtureValid(mode: .fullTest)) }
    try await store.sessions.save(.fixtureInvalid(mode: .fullTest))

    let quickHistory = try await store.sessions.sessions(mode: .quickTest, includeInvalid: false, limit: nil)
    let fullHistory = try await store.sessions.sessions(mode: .fullTest, includeInvalid: false, limit: nil)

    #expect(quickHistory.count == 3)
    #expect(quickHistory.allSatisfy { $0.mode == .quickTest })
    #expect(fullHistory.count == 2)
    #expect(fullHistory.allSatisfy { $0.mode == .fullTest && $0.isValid })
}

@Test func repositoriesSharingAContainerSeeEachOthersWrites() async throws {
    // Guards the wiring itself: three repositories, one store.
    let store = try InMemoryStore()

    try await store.profiles.save(.fixture())
    try await store.sessions.save(.fixtureValid(mode: .fullTest))
    try await store.baselines.save(.fixture(mode: .fullTest))

    #expect(try await store.profiles.fetchProfile() != nil)
    #expect(try await store.sessions.validSessionCount(mode: .fullTest) == 1)
    #expect(try await store.baselines.baseline(mode: .fullTest) != nil)
}
