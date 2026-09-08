import Foundation

/// The single-row profile store (docs/06 §6.3, docs/05 §5.1).
///
/// Uniqueness invariant: exactly one profile exists.
nonisolated protocol UserProfileRepository: Sendable {
    func fetchProfile() async throws -> UserProfile?
    func save(_ profile: UserProfile) async throws
}
