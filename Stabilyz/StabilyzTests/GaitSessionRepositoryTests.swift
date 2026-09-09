import Foundation
import SwiftData
import Testing
@testable import Stabilyz

private func makeRepository() throws -> SwiftDataGaitSessionRepository {
    SwiftDataGaitSessionRepository(container: try StoreContainer.make(inMemory: true))
}

private let base = Date(timeIntervalSince1970: 1_700_000_000)

@Test func sessionsAreFilteredByModeAtTheStore() async throws {
    let repository = try makeRepository()
    try await repository.save(.fixtureValid(mode: .quickTest, startedAt: base))
    try await repository.save(.fixtureValid(mode: .quickTest, startedAt: base.addingTimeInterval(600)))
    try await repository.save(.fixtureValid(mode: .fullTest, startedAt: base.addingTimeInterval(1200)))

    let quick = try await repository.sessions(mode: .quickTest, includeInvalid: false, limit: nil)
    let full = try await repository.sessions(mode: .fullTest, includeInvalid: false, limit: nil)

    #expect(quick.count == 2)
    #expect(quick.allSatisfy { $0.mode == .quickTest })
    #expect(full.count == 1)
}

@Test func invalidSessionsAreExcludedUnlessExplicitlyRequested() async throws {
    // [PRD §5, §6] never shown in history, never exported.
    let repository = try makeRepository()
    try await repository.save(.fixtureValid(mode: .quickTest))
    try await repository.save(.fixtureInvalid(mode: .quickTest, reason: .excessiveNoise))

    let visible = try await repository.sessions(mode: .quickTest, includeInvalid: false, limit: nil)
    #expect(visible.count == 1)
    #expect(visible.allSatisfy { $0.isValid })

    let everything = try await repository.sessions(mode: .quickTest, includeInvalid: true, limit: nil)
    #expect(everything.count == 2)
}

@Test func sessionsAreReturnedNewestFirst() async throws {
    let repository = try makeRepository()
    let oldest = GaitSession.fixtureValid(mode: .quickTest, startedAt: base)
    let newest = GaitSession.fixtureValid(mode: .quickTest, startedAt: base.addingTimeInterval(3600))
    try await repository.save(oldest)
    try await repository.save(newest)

    let sessions = try await repository.sessions(mode: .quickTest, includeInvalid: false, limit: nil)
    #expect(sessions.map(\.id) == [newest.id, oldest.id])
}

@Test func limitAppliesAfterOrdering() async throws {
    let repository = try makeRepository()
    for offset in 0..<5 {
        try await repository.save(.fixtureValid(mode: .quickTest, startedAt: base.addingTimeInterval(Double(offset) * 600)))
    }

    let latest = try await repository.sessions(mode: .quickTest, includeInvalid: false, limit: 2)
    #expect(latest.count == 2)
    #expect(latest[0].startedAt > latest[1].startedAt)
}

@Test func validSessionCountIgnoresInvalidSessionsAndOtherModes() async throws {
    // The count that drives "Session X of 5" [PRD §6, §7].
    let repository = try makeRepository()
    for _ in 0..<3 { try await repository.save(.fixtureValid(mode: .quickTest)) }
    for _ in 0..<2 { try await repository.save(.fixtureInvalid(mode: .quickTest)) }
    for _ in 0..<4 { try await repository.save(.fixtureValid(mode: .fullTest)) }

    #expect(try await repository.validSessionCount(mode: .quickTest) == 3)
    #expect(try await repository.validSessionCount(mode: .fullTest) == 4)
}

@Test func sessionLookupByIDRoundTrips() async throws {
    let repository = try makeRepository()
    let session = GaitSession.fixtureValid(mode: .fullTest, score: SessionScore(relativeIndex: 112))
    try await repository.save(session)

    #expect(try await repository.session(id: session.id) == session)
    #expect(try await repository.session(id: UUID()) == nil)
}

@Test func anEmptyStoreReportsNoSessionsRatherThanFailing() async throws {
    let repository = try makeRepository()

    #expect(try await repository.sessions(mode: .quickTest, includeInvalid: false, limit: nil).isEmpty)
    #expect(try await repository.validSessionCount(mode: .fullTest) == 0)
}
