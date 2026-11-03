import Foundation

/// Everything the phone tells the watch [PRD §8 Sync, docs/04 §4.18].
///
/// The phone is the only source of truth; the watch displays what it is told
/// and runs its own clock from `t0`, so there is no per-second message.
///
/// Every session-scoped message carries the `sessionID` the phone minted for
/// that countdown, so a late message for an earlier session can be told apart
/// from the current one.
nonisolated enum PhoneToWatchMessage: Codable, Sendable, Equatable {
    /// Sent when the numerals begin, after sensor priming.
    ///
    /// `plannedGoAt` is when Go is expected. It is a plan, not the anchor: T-0
    /// is stamped at the final tick, so the watch re-syncs to `started.t0`.
    case countdownStarted(
        sessionID: UUID,
        mode: WireTestMode,
        durationSeconds: Int,
        plannedGoAt: Date,
        hapticOwner: WireHapticOwner,
        hapticsEnabled: Bool
    )

    /// Go. `t0` is the session's actual time anchor.
    case started(sessionID: UUID, t0: Date)

    /// The session ended, whichever device or the clock stopped it.
    case stopped(sessionID: UUID)

    /// The countdown was cancelled before Go.
    case cancelled(sessionID: UUID)

    /// The user changed Start & Stop Haptics. Governs both devices.
    case hapticsChanged(enabled: Bool)

    /// The session this message refers to, if it refers to one.
    var sessionID: UUID? {
        switch self {
        case .countdownStarted(let id, _, _, _, _, _), .started(let id, _),
             .stopped(let id), .cancelled(let id):
            id
        case .hapticsChanged:
            nil
        }
    }
}
