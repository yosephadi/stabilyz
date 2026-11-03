import Foundation
import WatchConnectivity

/// The watch's WatchConnectivity link to the phone (Task 12.2.1).
///
/// Receives the contract's phone-to-watch messages, reports reachability, and
/// sends the stop request. Every live message is answered with an empty reply,
/// so the phone can tell a delivered message from a lost one.
///
/// On activation it reads only the setup selection from the application
/// context. Catching up on a session already in progress is Task 12.3.3.
///
/// `@unchecked Sendable`: `WCSession` is documented as thread-safe, and the one
/// stored callback is written once, before activation.
nonisolated final class WatchPhoneLink: NSObject, WatchPhoneLinking, WCSessionDelegate, @unchecked Sendable {
    private let session: WCSession? = WCSession.isSupported() ? .default : nil
    private var onEvent: (@MainActor @Sendable (WatchLinkEvent) -> Void)?

    func activate(onEvent: @escaping @MainActor @Sendable (WatchLinkEvent) -> Void) {
        self.onEvent = onEvent
        session?.delegate = self
        session?.activate()
    }

    func send(_ message: WatchToPhoneMessage) {
        guard let session, session.isReachable,
              let data = try? WatchSyncCoder.encode(message) else { return }
        session.sendMessage([WatchSyncKeys.message: data], replyHandler: nil, errorHandler: nil)
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let data = session.receivedApplicationContext[WatchSyncKeys.setup] as? Data,
           let message = WatchSyncCoder.decodePhoneToWatch(data) {
            deliver(.message(message))
        }
        deliver(.reachability(session.isReachable))
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        deliver(.reachability(session.isReachable))
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receive(message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        receive(message)
        replyHandler([:])
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let data = applicationContext[WatchSyncKeys.setup] as? Data,
           let message = WatchSyncCoder.decodePhoneToWatch(data) {
            deliver(.message(message))
        }
    }

    // MARK: Private

    private func receive(_ payload: [String: Any]) {
        guard let data = payload[WatchSyncKeys.message] as? Data,
              let message = WatchSyncCoder.decodePhoneToWatch(data) else { return }
        deliver(.message(message))
    }

    private func deliver(_ event: WatchLinkEvent) {
        guard let onEvent else { return }
        Task { @MainActor in onEvent(event) }
    }
}
