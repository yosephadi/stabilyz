import Foundation
import SwiftData

/// SwiftData-backed `UserProfileRepository` (docs/06 §6.3).
///
/// A nil profile is the signal that onboarding has not completed — the router
/// reads it that way at launch (docs/11 §11.1).
nonisolated struct SwiftDataUserProfileRepository: UserProfileRepository {
    private let reader: StoreReader
    private let writer: StoreWriter

    init(reader: StoreReader, writer: StoreWriter) {
        self.reader = reader
        self.writer = writer
    }

    init(container: ModelContainer) {
        self.init(reader: StoreReader(modelContainer: container), writer: StoreWriter(modelContainer: container))
    }

    func fetchProfile() async throws -> UserProfile? {
        try await reader.profile()
    }

    /// Replaces the single row, preserving the one-profile invariant.
    func save(_ profile: UserProfile) async throws {
        try await writer.save(profile)
    }
}
