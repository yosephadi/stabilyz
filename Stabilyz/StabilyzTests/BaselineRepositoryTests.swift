import Foundation
import SwiftData
import Testing
@testable import Stabilyz

private func makeRepository() throws -> SwiftDataBaselineRepository {
    SwiftDataBaselineRepository(container: try StoreContainer.make(inMemory: true))
}

@Test func baselineIsStoredAndFetchedByMode() async throws {
    let repository = try makeRepository()
    let quick = Baseline.fixture(mode: .quickTest, cadenceBPM: 104)
    try await repository.save(quick)

    #expect(try await repository.baseline(mode: .quickTest) == quick)
    // The other mode is untouched [PRD OQ-5].
    #expect(try await repository.baseline(mode: .fullTest) == nil)
}

@Test func onlyOneBaselinePerModeCanExist() async throws {
    let repository = try makeRepository()
    try await repository.save(.fixture(mode: .fullTest))

    await #expect(throws: StoreWriter.WriteError.baselineAlreadyExists(mode: .fullTest)) {
        try await repository.save(.fixture(mode: .fullTest))
    }
}

@Test func aRejectedSaveLeavesTheOriginalBaselineIntact() async throws {
    // [PRD §6] frozen in v1: a second attempt must not overwrite.
    let repository = try makeRepository()
    let original = Baseline.fixture(mode: .quickTest, cadenceBPM: 104)
    try await repository.save(original)

    try? await repository.save(.fixture(mode: .quickTest, cadenceBPM: 130))

    #expect(try await repository.baseline(mode: .quickTest) == original)
}

@Test func modesHoldIndependentBaselines() async throws {
    let repository = try makeRepository()
    let quick = Baseline.fixture(mode: .quickTest, cadenceBPM: 104)
    let full = Baseline.fixture(mode: .fullTest, cadenceBPM: 98)

    try await repository.save(quick)
    try await repository.save(full)

    #expect(try await repository.baseline(mode: .quickTest)?.cadenceBPM == 104)
    #expect(try await repository.baseline(mode: .fullTest)?.cadenceBPM == 98)
    #expect(try await repository.allBaselines().count == 2)
}

@Test func establishingOneModeDoesNotCreateTheOther() async throws {
    // [PRD §6] a Quick baseline must not give the user a Full baseline.
    let repository = try makeRepository()
    try await repository.save(.fixture(mode: .quickTest))

    #expect(try await repository.baseline(mode: .fullTest) == nil)
    #expect(try await repository.allBaselines().map(\.mode) == [.quickTest])
}

@Test func anEmptyStoreHasNoBaselines() async throws {
    let repository = try makeRepository()

    #expect(try await repository.baseline(mode: .quickTest) == nil)
    #expect(try await repository.allBaselines().isEmpty)
}
