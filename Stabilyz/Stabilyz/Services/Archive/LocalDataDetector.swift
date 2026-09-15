import Foundation

/// Whether restoring would overwrite anything (docs/04 §4.16, docs/11 §11.1,
/// Task 10.3.3).
protocol LocalDataDetecting: Sendable {
    func hasLocalData() async throws -> Bool
}

/// `LocalDataDetecting` over the three repositories.
///
/// Anything the person could lose counts: a profile (with or without its
/// disclaimer acceptance), a baseline in either mode, or a session in either
/// mode — **invalid sessions included**, because a restore deletes those too
/// [PRD OQ-2: a restore, not a merge].
///
/// Each query stops at the first row it needs.
struct RepositoryLocalDataDetector: LocalDataDetecting {
    private let profiles: UserProfileRepository
    private let sessions: GaitSessionRepository
    private let baselines: BaselineRepository

    init(profiles: UserProfileRepository, sessions: GaitSessionRepository, baselines: BaselineRepository) {
        self.profiles = profiles
        self.sessions = sessions
        self.baselines = baselines
    }

    func hasLocalData() async throws -> Bool {
        if try await profiles.fetchProfile() != nil { return true }
        if try await !baselines.allBaselines().isEmpty { return true }
        for mode in TestMode.allCases {
            if try await !sessions.sessions(mode: mode, includeInvalid: true, limit: 1).isEmpty { return true }
        }
        return false
    }
}
