import Foundation

/// Everything the store holds, as domain values (Task 10.3.4).
///
/// The pre-restore snapshot and the restore target share this shape, so "the
/// store is exactly as it was" is one equality. Rows are normalized on the way
/// in — baselines by mode, sessions by id — because the store promises no
/// order, and two reads of the same data must compare equal.
struct StoreContents: Sendable, Equatable {
    let profile: UserProfile?
    let baselines: [Baseline]
    /// Every session, invalid ones included: a snapshot that dropped them
    /// could not put the store back exactly.
    let sessions: [GaitSession]

    init(profile: UserProfile?, baselines: [Baseline], sessions: [GaitSession]) {
        self.profile = profile
        self.baselines = baselines.sorted { $0.mode.rawValue < $1.mode.rawValue }
        self.sessions = sessions.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

/// Reads and wholesale-replaces the store, for restore only (docs/13 §13.5).
protocol StoreReplacing: Sendable {
    func contents() async throws -> StoreContents

    /// One transaction: everything deleted, `contents` inserted, one save. A
    /// throw leaves the store as it was.
    func replaceAll(with contents: StoreContents) async throws
}

/// Production `StoreReplacing` over the store's single read and write paths.
struct SwiftDataStoreReplacer: StoreReplacing {
    private let reader: StoreReader
    private let writer: StoreWriter

    init(reader: StoreReader, writer: StoreWriter) {
        self.reader = reader
        self.writer = writer
    }

    /// Sessions are read one mode at a time, with invalid ones included — the
    /// reader filters by mode at the store, and a restore snapshot is no reason
    /// to add a query that does not (docs/09 §9.7).
    func contents() async throws -> StoreContents {
        let profile = try await reader.profile()
        let baselines = try await reader.allBaselines()
        var sessions: [GaitSession] = []
        for mode in TestMode.allCases {
            sessions += try await reader.sessions(mode: mode, includeInvalid: true, limit: nil)
        }
        return StoreContents(profile: profile, baselines: baselines, sessions: sessions)
    }

    func replaceAll(with contents: StoreContents) async throws {
        try await writer.replaceAll(profile: contents.profile, sessions: contents.sessions, baselines: contents.baselines)
    }
}
