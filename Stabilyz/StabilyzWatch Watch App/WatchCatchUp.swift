import Foundation

/// What the phone last stored for a watch that was not listening (Task 12.3.3):
/// read on launch and whenever the phone becomes reachable again.
///
/// Each field holds only a message of the right kind for its key, so a wrong,
/// unreadable or other-version entry is simply absent.
nonisolated struct WatchCatchUp: Equatable, Sendable {
    var setup: PhoneToWatchMessage?
    /// The session's `countdownStarted`: its mode, length, owner and planned Go.
    var countdown: PhoneToWatchMessage?
    /// The session's latest state: countdownStarted, started, stopped or
    /// cancelled.
    var sessionState: PhoneToWatchMessage?
    var haptics: PhoneToWatchMessage?

    init(
        setup: PhoneToWatchMessage? = nil,
        countdown: PhoneToWatchMessage? = nil,
        sessionState: PhoneToWatchMessage? = nil,
        haptics: PhoneToWatchMessage? = nil
    ) {
        self.setup = setup
        self.countdown = countdown
        self.sessionState = sessionState
        self.haptics = haptics
    }

    init(applicationContext: [String: Any]) {
        func message(_ key: String, _ isRightKind: (PhoneToWatchMessage) -> Bool) -> PhoneToWatchMessage? {
            guard let data = applicationContext[key] as? Data,
                  let message = WatchSyncCoder.decodePhoneToWatch(data),
                  isRightKind(message) else { return nil }
            return message
        }
        self.init(
            setup: message(WatchSyncKeys.setup) { if case .setupSelection = $0 { true } else { false } },
            countdown: message(WatchSyncKeys.countdown) { if case .countdownStarted = $0 { true } else { false } },
            sessionState: message(WatchSyncKeys.sessionState) {
                switch $0 {
                case .countdownStarted, .started, .stopped, .cancelled: true
                case .setupSelection, .hapticsChanged: false
                }
            },
            haptics: message(WatchSyncKeys.haptics) { if case .hapticsChanged = $0 { true } else { false } }
        )
    }
}
