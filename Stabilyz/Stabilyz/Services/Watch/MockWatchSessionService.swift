import Foundation

/// A scriptable `WatchSessionService` for tests (docs/12 §12.2).
///
/// Records what it was asked to send, in order, and lets a test move
/// reachability and deliver stop requests as the watch would.
final class MockWatchSessionService: WatchSessionService, Sendable {
    private let reachabilityEvents: WatchEventBroadcast<WatchReachability>
    private let stopEvents = WatchEventBroadcast<WatchStopRequest>(replaysLatest: false)
    private let sent = Locked<[PhoneToWatchMessage]>([])
    private let lost = Locked<@Sendable (PhoneToWatchMessage) -> Bool>({ _ in false })

    init(reachability: WatchReachability = .reachable) {
        reachabilityEvents = WatchEventBroadcast(initial: reachability, replaysLatest: true)
    }

    var sentMessages: [PhoneToWatchMessage] {
        sent.withLock { $0 }
    }

    func setReachability(_ reachability: WatchReachability) {
        reachabilityEvents.publish(reachability)
    }

    /// Makes the matching messages go unconfirmed even while reachable, as a
    /// message lost on a live link would.
    func loseMessages(where isLost: @escaping @Sendable (PhoneToWatchMessage) -> Bool) {
        lost.withLock { $0 = isLost }
    }

    func deliverStopRequest(sessionID: UUID) {
        stopEvents.publish(WatchStopRequest(sessionID: sessionID))
    }

    func reachability() -> AsyncStream<WatchReachability> {
        reachabilityEvents.subscribe()
    }

    func currentReachability() async -> WatchReachability {
        reachabilityEvents.latest ?? .unavailable
    }

    /// Records the message. Delivered exactly when the mock is `.reachable`,
    /// as a live watch would confirm it, unless `loseMessages` matches it.
    @discardableResult
    func send(_ message: PhoneToWatchMessage) async -> WatchDelivery {
        sent.withLock { $0.append(message) }
        let isLost = lost.withLock { $0 }(message)
        return reachabilityEvents.latest == .reachable && !isLost ? .delivered : .notDelivered
    }

    func stopRequests() -> AsyncStream<WatchStopRequest> {
        stopEvents.subscribe()
    }
}

/// No watch: always `.unavailable`, sends nothing, never stops anything. The
/// default slot value and the UI-testing stand-in — the v1 experience.
struct SilentWatchSessionService: WatchSessionService {
    init() {}

    func reachability() -> AsyncStream<WatchReachability> {
        AsyncStream { continuation in
            continuation.yield(.unavailable)
            continuation.finish()
        }
    }

    func currentReachability() async -> WatchReachability { .unavailable }

    @discardableResult
    func send(_ message: PhoneToWatchMessage) async -> WatchDelivery { .notDelivered }

    func stopRequests() -> AsyncStream<WatchStopRequest> {
        AsyncStream { $0.finish() }
    }
}
