import Foundation

/// Whether the watch companion can be talked to right now [PRD §8].
///
/// Three cases rather than a yes/no because two features need the middle one:
/// the setup screen's indicator shows only for `.reachable`, while the Live
/// Activity nudge runs only for `.installedNotReachable` (Task 12.5.1).
enum WatchReachability: Sendable, Equatable {
    /// No paired watch, the watch app is not installed, or WatchConnectivity is
    /// not supported. The v1, phone-only experience.
    case unavailable
    /// The app is on a paired watch but not open and reachable.
    case installedNotReachable
    /// The watch app is open and can receive live messages.
    case reachable
}

/// Whether the watch confirmed it received a message.
enum WatchDelivery: Equatable, Sendable {
    case delivered
    /// Not reachable, no reply in time, or an error. The application context
    /// still holds it for later.
    case notDelivered
}

/// A Stop tapped on the watch, for the session it names [PRD §8 decision 2].
struct WatchStopRequest: Sendable, Equatable {
    let sessionID: UUID
}

/// The phone's side of the watch companion (docs/04 §4.18, Task 12.1.1).
///
/// **A session never depends on this** [PRD §8 decision 4]. Nothing throws and
/// nothing reports failure: a message the watch cannot receive is simply not
/// received, exactly like a haptic on a device without a Taptic Engine. The
/// phone carries on as the v1 app would.
///
/// The live implementation is `WatchConnectivityService`; tests use
/// `MockWatchSessionService`, and a graph without a watch uses
/// `SilentWatchSessionService`.
protocol WatchSessionService: Sendable {
    /// The current reachability, then every change. Each call returns its own
    /// stream, so the setup indicator and the countdown can both listen.
    func reachability() -> AsyncStream<WatchReachability>

    /// The reachability right now: the latest value `reachability()` has
    /// reported.
    func currentReachability() async -> WatchReachability

    /// Sends a message to the watch, live if it is reachable, and keeps the
    /// latest session state for a watch that connects later.
    ///
    /// Returns whether the watch confirmed the live message, waiting at most
    /// `WatchConnectivityService.replyTimeout`. Callers that do not need the
    /// answer must not wait for it: send from a task.
    @discardableResult
    func send(_ message: PhoneToWatchMessage) async -> WatchDelivery

    /// Stop requests from the watch, in arrival order. Not filtered by
    /// session: matching the ID against the running session is the caller's
    /// job (Task 12.3.2).
    func stopRequests() -> AsyncStream<WatchStopRequest>
}
