import Foundation
import SwiftData
import Testing
@testable import Stabilyz

/// Reads back through a separate context, so the assertions see what actually
/// landed in the store rather than the writer's own pending changes.
private func readContext(_ container: ModelContainer) -> ModelContext {
    ModelContext(container)
}

private func makeStore() throws -> (ModelContainer, StoreWriter) {
    let container = try StoreContainer.make(inMemory: true)
    return (container, StoreWriter(modelContainer: container))
}

// MARK: - Sessions

@Test func sessionsAreWrittenAndReadBackIntact() async throws {
    let (container, writer) = try makeStore()
    let session = GaitSession.fixtureValid(mode: .fullTest, score: SessionScore.fixture(relativeIndex: 112))

    try await writer.save(session)

    let rows = try readContext(container).fetch(FetchDescriptor<GaitSessionEntity>())
    #expect(rows.count == 1)
    #expect(try EntityMapping.session(from: rows[0]) == session)
}

@Test func savingTheSameSessionTwiceReplacesRatherThanDuplicates() async throws {
    let (container, writer) = try makeStore()
    let id = UUID()

    try await writer.save(.fixtureValid(id: id, mode: .quickTest))
    try await writer.save(.fixtureValid(id: id, mode: .quickTest, score: SessionScore.fixture(relativeIndex: 108)))

    let rows = try readContext(container).fetch(FetchDescriptor<GaitSessionEntity>())
    #expect(rows.count == 1)
    #expect(rows[0].relativeIndex == 108)
}

@Test func invalidSessionsArePersistedForDiagnostics() async throws {
    // [REC] retained locally, but excluded from history, baseline counting and
    // export — exclusion is the repositories' job, not a reason to drop the row.
    let (container, writer) = try makeStore()
    try await writer.save(.fixtureInvalid(reason: .excessiveNoise))

    let rows = try readContext(container).fetch(FetchDescriptor<GaitSessionEntity>())
    #expect(rows.count == 1)
    #expect(rows[0].validity == "excessiveNoise")
    #expect(rows[0].relativeIndex == nil)
}

// MARK: - Baselines

@Test func baselineIsCreateOnlyPerMode() async throws {
    let (container, writer) = try makeStore()
    try await writer.establish(.fixture(mode: .quickTest))

    // [PRD §6] frozen in v1 — a second establish for the same mode is refused.
    await #expect(throws: StoreWriter.WriteError.baselineAlreadyExists(mode: .quickTest)) {
        try await writer.establish(.fixture(mode: .quickTest))
    }

    let rows = try readContext(container).fetch(FetchDescriptor<BaselineEntity>())
    #expect(rows.count == 1)
}

@Test func bothModesCanHoldTheirOwnBaseline() async throws {
    let (container, writer) = try makeStore()

    try await writer.establish(.fixture(mode: .quickTest))
    try await writer.establish(.fixture(mode: .fullTest))

    let rows = try readContext(container).fetch(FetchDescriptor<BaselineEntity>())
    #expect(Set(rows.map(\.mode)) == ["quickTest", "fullTest"])
}

@Test func aRefusedBaselineLeavesTheStoreUnchanged() async throws {
    let (container, writer) = try makeStore()
    let first = Baseline.fixture(mode: .quickTest)
    try await writer.establish(first)

    try? await writer.establish(.fixture(mode: .quickTest, cadenceBPM: 999))

    let rows = try readContext(container).fetch(FetchDescriptor<BaselineEntity>())
    #expect(rows.count == 1)
    #expect(rows[0].cadenceBPM == first.cadenceBPM)
}

// MARK: - Profile

@Test func profileIsASingleRowThatGetsReplaced() async throws {
    let (container, writer) = try makeStore()

    try await writer.save(UserProfile.fixture(level: .transtibial, side: .left))
    try await writer.save(UserProfile.fixture(level: .bilateral, side: .both))

    let rows = try readContext(container).fetch(FetchDescriptor<UserProfileEntity>())
    #expect(rows.count == 1)
    #expect(rows[0].amputationLevel == "bilateral")
}

// MARK: - Restore

@Test func replaceAllSwapsTheEntireStoreInOneTransaction() async throws {
    let (container, writer) = try makeStore()

    try await writer.save(.fixtureValid(mode: .quickTest))
    try await writer.save(UserProfile.fixture())
    try await writer.establish(.fixture(mode: .quickTest))

    let restoredSessions = [
        GaitSession.fixtureValid(mode: .fullTest),
        GaitSession.fixtureValid(mode: .fullTest)
    ]
    try await writer.replaceAll(
        profile: UserProfile.fixture(level: .transfemoral, side: .right),
        sessions: restoredSessions,
        baselines: [.fixture(mode: .fullTest)]
    )

    let context = readContext(container)
    let sessions = try context.fetch(FetchDescriptor<GaitSessionEntity>())
    let baselines = try context.fetch(FetchDescriptor<BaselineEntity>())
    let profiles = try context.fetch(FetchDescriptor<UserProfileEntity>())

    // A restore replaces, never merges [PRD OQ-2].
    #expect(sessions.count == 2)
    #expect(sessions.allSatisfy { $0.mode == "fullTest" })
    #expect(baselines.count == 1)
    #expect(baselines[0].mode == "fullTest")
    #expect(profiles.count == 1)
    #expect(profiles[0].amputationLevel == "transfemoral")
}

@Test func replaceAllRemovesDataTheArchiveDoesNotContain() async throws {
    // A restore is a replace, not a merge [PRD OQ-2]: a baseline the archive
    // lacks must be gone afterwards, not left behind to be scored against.
    let (container, writer) = try makeStore()
    try await writer.save(.fixtureValid(mode: .quickTest))
    try await writer.establish(.fixture(mode: .quickTest))

    try await writer.replaceAll(profile: nil, sessions: [], baselines: [])

    let context = readContext(container)
    #expect(try context.fetch(FetchDescriptor<GaitSessionEntity>()).isEmpty)
    #expect(try context.fetch(FetchDescriptor<BaselineEntity>()).isEmpty)
    #expect(try context.fetch(FetchDescriptor<UserProfileEntity>()).isEmpty)
}

// Kill-point failure injection during a restore (fail at decrypt, at validate,
// mid-transaction) is mandated by docs/19 §19.2 and belongs to Task 10.3.5,
// which owns the snapshot/rollback machinery those tests exercise.

// MARK: - Restore rollback (Task 10.3.4)

@Test func aFailedReplaceAllRollsBackEveryDeleteAndInsert() async throws {
    struct SimulatedFailure: Error {}
    let (container, writer) = try makeStore()
    let session = GaitSession.fixtureValid(mode: .quickTest)
    let invalid = GaitSession.fixtureInvalid(mode: .fullTest)
    try await writer.save(session)
    try await writer.save(invalid)
    try await writer.save(UserProfile.fixture(prosthesisType: "Local"))
    try await writer.establish(.fixture(mode: .quickTest))

    await #expect(throws: SimulatedFailure.self) {
        try await writer.replaceAll(
            profile: UserProfile.fixture(prosthesisType: "Backup"),
            sessions: [.fixtureValid(mode: .fullTest)],
            baselines: [.fixture(mode: .fullTest)],
            beforeSave: { throw SimulatedFailure() }
        )
    }

    // The bulk deletes and every insert were staged; none of them survived.
    let context = readContext(container)
    #expect(Set(try context.fetch(FetchDescriptor<GaitSessionEntity>()).map(\.id)) == [session.id, invalid.id])
    #expect(try context.fetch(FetchDescriptor<BaselineEntity>()).map(\.mode) == ["quickTest"])
    #expect(try context.fetch(FetchDescriptor<UserProfileEntity>()).map(\.prosthesisType) == ["Local"])

    // And the writer is still usable afterwards.
    try await writer.save(GaitSession.fixtureValid(mode: .fullTest))
    #expect(try readContext(container).fetch(FetchDescriptor<GaitSessionEntity>()).count == 3)
}

@Test func replaceAllKeepsRowsWhoseIdsItReinserts() async throws {
    // Restoring an export of the store's own data: the same unique ids are
    // deleted and inserted in one save.
    let (container, writer) = try makeStore()
    let session = GaitSession.fixtureValid(mode: .quickTest)
    let profile = UserProfile.fixture()
    let baseline = Baseline.fixture(mode: .quickTest)
    try await writer.replaceAll(profile: profile, sessions: [session], baselines: [baseline])

    try await writer.replaceAll(profile: profile, sessions: [session], baselines: [baseline])

    let context = readContext(container)
    #expect(try context.fetch(FetchDescriptor<GaitSessionEntity>()).map(\.id) == [session.id])
    #expect(try context.fetch(FetchDescriptor<BaselineEntity>()).map(\.id) == [baseline.id])
    #expect(try context.fetch(FetchDescriptor<UserProfileEntity>()).map(\.id) == [profile.id])
}
