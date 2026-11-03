import Foundation
import WatchConnectivity

/// Production `WatchSessionService` over `WCSession` (docs/04 §4.18,
/// Task 12.1.1).
///
/// **Transport.** Every message goes two ways at once:
/// - `sendMessage`, when the watch is reachable, for immediate delivery.
/// - The application context (`WatchSyncContext`), always, so a watch that
///   opens or reconnects mid-session receives the current state.
///
/// Stop requests come back only through `sendMessage`: the watch hides Stop
/// while the phone is unreachable [PRD §8 decision 2], so there is nothing to
/// queue.
///
/// **No unit tests drive this type.** `WCSession` cannot be faked or paired on a
/// simulator. The decisions it makes are pulled out as static functions —
/// reachability and inbound decoding — and tested directly; the rest is
/// verified on a real watch (Task 12.6.1).
///
/// `@unchecked Sendable`: `WCSession` is not `Sendable`, but it is documented
/// as safe to call from any thread, and everything this type mutates is behind
/// `Locked`.
final class WatchConnectivityService: NSObject, WatchSessionService, WCSessionDelegate, @unchecked Sendable {
    private let session: WCSession?
    private let logService: LogService
    private let reachabilityEvents = WatchEventBroadcast<WatchReachability>(initial: .unavailable, replaysLatest: true)
    private let stopEvents = WatchEventBroadcast<WatchStopRequest>(replaysLatest: false)
    private let context = Locked(WatchSyncContext())

    /// Activates the default session when the device supports one. On a device
    /// without WatchConnectivity this behaves like `SilentWatchSessionService`.
    init(logService: LogService) {
        self.logService = logService
        self.session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
        guard let session else {
            logService.log(.info, .session, "watch: WatchConnectivity not supported")
            return
        }
        session.delegate = self
        session.activate()
    }

    // MARK: WatchSessionService

    func reachability() -> AsyncStream<WatchReachability> {
        reachabilityEvents.subscribe()
    }

    func stopRequests() -> AsyncStream<WatchStopRequest> {
        stopEvents.subscribe()
    }

    func send(_ message: PhoneToWatchMessage) async {
        guard let session, session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return }

        let encoded: Data
        do {
            encoded = try WatchSyncCoder.encode(message)
        } catch {
            logService.log(.error, .session, "watch: could not encode a message: \(LogRedaction.describe(error))")
            return
        }

        let applicationContext = context.withLock { context -> [String: Any] in
            context.record(message, encoded: encoded)
            return context.dictionary
        }
        do {
            try session.updateApplicationContext(applicationContext)
        } catch {
            logService.log(.warning, .session, "watch: application context not updated: \(LogRedaction.describe(error))")
        }

        guard session.isReachable else { return }
        let logService = self.logService
        session.sendMessage([WatchSyncKeys.message: encoded], replyHandler: nil) { error in
            logService.log(.warning, .session, "watch: live message not delivered: \(LogRedaction.describe(error))")
        }
    }

    // MARK: Pure decisions (tested)

    static func reachability(
        isActivated: Bool,
        isPaired: Bool,
        isWatchAppInstalled: Bool,
        isReachable: Bool
    ) -> WatchReachability {
        guard isActivated, isPaired, isWatchAppInstalled else { return .unavailable }
        return isReachable ? .reachable : .installedNotReachable
    }

    /// A stop request from a live message, or nil for anything else: a missing
    /// key, a non-data value, an unknown version, a phone-direction message.
    static func stopRequest(from payload: [String: Any]) -> WatchStopRequest? {
        guard let data = payload[WatchSyncKeys.message] as? Data,
              case .stopRequest(let sessionID) = WatchSyncCoder.decodeWatchToPhone(data) else {
            return nil
        }
        return WatchStopRequest(sessionID: sessionID)
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            logService.log(.warning, .session, "watch: activation failed: \(LogRedaction.describe(error))")
        }
        publishReachability(of: session)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        publishReachability(of: session)
    }

    /// The user switched to another watch. Apple's documented response is to
    /// activate again for the new one.
    func sessionDidDeactivate(_ session: WCSession) {
        context.withLock { $0 = WatchSyncContext() }
        publishReachability(of: session)
        session.activate()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        publishReachability(of: session)
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        publishReachability(of: session)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receive(message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        receive(message)
        replyHandler([:])
    }

    // MARK: Private

    private func receive(_ payload: [String: Any]) {
        guard let request = Self.stopRequest(from: payload) else {
            logService.log(.info, .session, "watch: dropped an unreadable message")
            return
        }
        stopEvents.publish(request)
    }

    private func publishReachability(of session: WCSession) {
        reachabilityEvents.publish(Self.reachability(
            isActivated: session.activationState == .activated,
            isPaired: session.isPaired,
            isWatchAppInstalled: session.isWatchAppInstalled,
            isReachable: session.isReachable
        ))
    }
}
