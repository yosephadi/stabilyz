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
    let reader: StoreReader
    let writer: StoreWriter
    let stateStore: BaselineStateStore
    let commits: SessionCommitService

    init(clock: Clock = FixedStoreClock()) throws {
        container = try StoreContainer.make(inMemory: true)
        let reader = StoreReader(modelContainer: container)
        let writer = StoreWriter(modelContainer: container)
        self.reader = reader
        self.writer = writer

        sessions = SwiftDataGaitSessionRepository(reader: reader, writer: writer)
        baselines = SwiftDataBaselineRepository(reader: reader, writer: writer)
        profiles = SwiftDataUserProfileRepository(reader: reader, writer: writer)

        let stateStore = BaselineStateStore(sessions: sessions, baselines: baselines)
        self.stateStore = stateStore
        commits = SessionCommitService(
            sessions: sessions,
            baselines: baselines,
            writer: writer,
            reader: reader,
            stateStore: stateStore,
            logService: SilentStoreLog(),
            clock: clock
        )
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

/// Fixed so `establishedAt` is deterministic.
struct FixedStoreClock: Clock {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let uptime: TimeInterval = 1_000
}

final class SilentStoreLog: LogService, @unchecked Sendable {
    let entries = Locked<[String]>([])
    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        entries.withLock { $0.append(message) }
    }
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}
