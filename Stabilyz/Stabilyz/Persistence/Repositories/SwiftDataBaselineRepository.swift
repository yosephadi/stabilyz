import Foundation
import SwiftData

/// SwiftData-backed `BaselineRepository` (docs/06 §6.3, docs/09 §9.3).
///
/// Every API requires an explicit `TestMode`. Together with the store's unique
/// constraint on `mode` and `StoreWriter.establish`'s create-only check, this is
/// the three-layer anti-mixing guarantee in docs/09 §9.7.
nonisolated struct SwiftDataBaselineRepository: BaselineRepository {
    private let reader: StoreReader
    private let writer: StoreWriter

    init(reader: StoreReader, writer: StoreWriter) {
        self.reader = reader
        self.writer = writer
    }

    init(container: ModelContainer) {
        self.init(reader: StoreReader(modelContainer: container), writer: StoreWriter(modelContainer: container))
    }

    func baseline(mode: TestMode) async throws -> Baseline? {
        try await reader.baseline(mode: mode)
    }

    /// Create-only. Throws if that mode already has a baseline — v1 baselines
    /// are frozen and never recalibrated [PRD §6].
    func save(_ baseline: Baseline) async throws {
        try await writer.establish(baseline)
    }

    func allBaselines() async throws -> [Baseline] {
        try await reader.allBaselines()
    }
}
