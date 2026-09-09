import Foundation
import SwiftData
@testable import Stabilyz

/// In-memory store backing for tests and previews (docs/12 §12.2, docs/19 §19.2).
///
/// Bundles one in-memory container with all three repositories sharing it, so
/// an integration test exercises the same objects the app wires up rather than
/// a parallel fake.
struct InMemoryStore {
    let container: ModelContainer
    let sessions: SwiftDataGaitSessionRepository
    let baselines: SwiftDataBaselineRepository
    let profiles: SwiftDataUserProfileRepository

    init() throws {
        container = try StoreContainer.make(inMemory: true)
        let reader = StoreReader(modelContainer: container)
        let writer = StoreWriter(modelContainer: container)

        sessions = SwiftDataGaitSessionRepository(reader: reader, writer: writer)
        baselines = SwiftDataBaselineRepository(reader: reader, writer: writer)
        profiles = SwiftDataUserProfileRepository(reader: reader, writer: writer)
    }

    /// The `BaselineState` the app would derive for a mode, straight from the
    /// store — the same derivation every screen uses (docs/09 §9.4).
    func baselineState(for mode: TestMode) async throws -> BaselineState {
        try BaselineStateMachine.state(
            for: mode,
            validSessionCount: try await sessions.validSessionCount(mode: mode),
            baseline: try await baselines.baseline(mode: mode)
        )
    }
}
