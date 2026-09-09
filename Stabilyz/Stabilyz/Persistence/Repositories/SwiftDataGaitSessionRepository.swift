import Foundation
import SwiftData

/// SwiftData-backed `GaitSessionRepository` (docs/06 §6.3).
///
/// Reads go through `StoreReader`, writes through the background
/// `StoreWriter` — the split docs/14 §14.2 asks for.
nonisolated struct SwiftDataGaitSessionRepository: GaitSessionRepository {
    private let reader: StoreReader
    private let writer: StoreWriter

    init(reader: StoreReader, writer: StoreWriter) {
        self.reader = reader
        self.writer = writer
    }

    init(container: ModelContainer) {
        self.init(reader: StoreReader(modelContainer: container), writer: StoreWriter(modelContainer: container))
    }

    func save(_ session: GaitSession) async throws {
        try await writer.save(session)
    }

    func session(id: UUID) async throws -> GaitSession? {
        try await reader.session(id: id)
    }

    func sessions(mode: TestMode, includeInvalid: Bool, limit: Int?) async throws -> [GaitSession] {
        try await reader.sessions(mode: mode, includeInvalid: includeInvalid, limit: limit)
    }

    func validSessionCount(mode: TestMode) async throws -> Int {
        try await reader.validSessionCount(mode: mode)
    }
}
