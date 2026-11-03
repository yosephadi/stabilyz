import Foundation

/// The one message the watch sends back [PRD §8 Sync].
nonisolated enum WatchToPhoneMessage: Codable, Sendable, Equatable {
    /// The user tapped Stop on the watch. Carries the session it refers to,
    /// so the phone can drop a late request for a session that already ended.
    case stopRequest(sessionID: UUID)
}
