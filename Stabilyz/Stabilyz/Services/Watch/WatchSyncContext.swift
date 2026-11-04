import Foundation

/// What a watch that connects mid-session needs to catch up (docs/04 §4.18:
/// "a reconnect re-syncs to the phone's current state").
///
/// WatchConnectivity's application context is one dictionary, replaced
/// wholesale on every update, so it cannot just hold "the last message": a
/// haptics change during a walk would overwrite the `started` message and a
/// reconnecting watch would no longer know a session was running. This keeps
/// the two kinds apart:
/// - **Session state** — the latest of countdown started, started, stopped,
///   cancelled.
/// - **Haptics** — the latest Start & Stop Haptics change since the countdown
///   started. A new countdown clears it, because `countdownStarted` already
///   carries the setting.
/// - **Setup** — the latest mode selected on the setup screen, for Waiting.
///   Independent of the other two: a session never erases it.
/// - **Countdown** — the latest `countdownStarted`, which `started` and the
///   rest replace in session state. Without it a watch reconnecting mid-walk
///   would know T-0 but not the mode, the length or who owns the haptics
///   (Task 12.3.3).
struct WatchSyncContext: Equatable {
    private(set) var sessionState: Data?
    private(set) var haptics: Data?
    private(set) var setup: Data?
    private(set) var countdown: Data?

    init() {}

    mutating func record(_ message: PhoneToWatchMessage, encoded: Data) {
        switch message {
        case .countdownStarted:
            sessionState = encoded
            countdown = encoded
            haptics = nil
        case .started, .stopped, .cancelled:
            sessionState = encoded
        case .hapticsChanged:
            haptics = encoded
        case .setupSelection:
            setup = encoded
        }
    }

    /// The application-context dictionary. Property-list values only.
    var dictionary: [String: Any] {
        var dictionary: [String: Any] = [:]
        dictionary[WatchSyncKeys.sessionState] = sessionState
        dictionary[WatchSyncKeys.haptics] = haptics
        dictionary[WatchSyncKeys.setup] = setup
        dictionary[WatchSyncKeys.countdown] = countdown
        return dictionary
    }
}
