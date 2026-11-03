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
struct WatchSyncContext: Equatable {
    private(set) var sessionState: Data?
    private(set) var haptics: Data?

    init() {}

    mutating func record(_ message: PhoneToWatchMessage, encoded: Data) {
        switch message {
        case .countdownStarted:
            sessionState = encoded
            haptics = nil
        case .started, .stopped, .cancelled:
            sessionState = encoded
        case .hapticsChanged:
            haptics = encoded
        }
    }

    /// The application-context dictionary. Property-list values only.
    var dictionary: [String: Any] {
        var dictionary: [String: Any] = [:]
        dictionary[WatchSyncKeys.sessionState] = sessionState
        dictionary[WatchSyncKeys.haptics] = haptics
        return dictionary
    }
}
