import Foundation

/// A scriptable `WatchSessionService` for tests (docs/12 §12.2).
///
/// Records what it was asked to send, in order, and lets a test move
/// reachability and deliver stop requests as the watch would.
final class MockWatchSessionService: WatchSessionService, Sendable {
    private let reachabilityEvents: WatchEventBroadcast<WatchReachability>
    private let stopEvents = WatchEventBroadcast<WatchStopRequest>(replaysLatest: false)
    private let sent = Locked<[PhoneToWatchMessage]>([])

    init(reachability: WatchReachability = .reachable) {
        reachabilityEvents = WatchEventBroadcast(initial: reachability, replaysLatest: true)
    }

    var sentMessages: [PhoneToWatchMessage] {
        sent.withLock { $0 }
    }

    func setReachability(_ reachability: WatchReachability) {
        reachabilityEvents.publish(reachability)
    }

    func deliverStopRequest(sessionID: UUID) {
        stopEvents.publish(WatchStopRequest(sessionID: sessionID))
    }

    func reachability() -> AsyncStream<WatchReachability> {
        reachabilityEvents.subscribe()
    }

    func send(_ message: PhoneToWatchMessage) async {
        sent.withLock { $0.append(message) }
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

    func send(_ message: PhoneToWatchMessage) async {}

    func stopRequests() -> AsyncStream<WatchStopRequest> {
        AsyncStream { $0.finish() }
    }
}
