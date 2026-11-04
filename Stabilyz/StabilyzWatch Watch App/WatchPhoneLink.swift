import Foundation
import WatchConnectivity

/// The watch's WatchConnectivity link to the phone (Task 12.2.1).
///
/// Receives the contract's phone-to-watch messages, reports reachability, and
/// sends the stop request. Every live message is answered with an empty reply,
/// so the phone can tell a delivered message from a lost one.
///
/// Catch-up (Task 12.3.3): on activation and whenever the phone becomes
/// reachable again, it hands over what the phone stored. Not on every stored
/// update: while connected, the stored copy can arrive just before the live
/// message, and catching up on it would treat a live Go as one already past.
/// A stored update while connected passes on only the setup selection.
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
        deliver(.catchUp(WatchCatchUp(applicationContext: session.receivedApplicationContext)))
        deliver(.reachability(session.isReachable))
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        if session.isReachable {
            deliver(.catchUp(WatchCatchUp(applicationContext: session.receivedApplicationContext)))
        }
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
        if let setup = WatchCatchUp(applicationContext: applicationContext).setup {
            deliver(.message(setup))
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
