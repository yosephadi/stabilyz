import Foundation

/// Which device plays the session haptics [PRD §8 decision 3].
enum HapticOwner: Equatable, Sendable {
    case phone
    case watch

    /// Decided once, when the countdown starts counting: the watch if it is
    /// reachable at that moment, the phone otherwise. Never changes for the
    /// session.
    init(for reachability: WatchReachability) {
        self = reachability == .reachable ? .watch : .phone
    }

    var wire: WireHapticOwner {
        switch self {
        case .phone: .phone
        case .watch: .watch
        }
    }
}

/// When the phone plays a haptic the watch owns (Task 12.3.1).
///
/// Ownership is fixed, with fallbacks so a cue the user is waiting on is
/// never silent to touch:
/// - **Stop:** the owning watch is not reachable when the walk stops, or it
///   was but did not confirm `stopped` (a pocketed phone's user learns the
///   walk ended from this buzz). A possible double buzz is accepted
///   [PRD §8].
/// - **Go:** `started` could not be delivered to the owning watch.
///
/// Start & Stop Haptics off means no haptic on either device, fallbacks
/// included.
enum HapticOwnership {
    static func phonePlaysStopPulse(
        owner: HapticOwner,
        reachabilityAtStop: WatchReachability,
        hapticsOn: Bool
    ) -> Bool {
        hapticsOn && (owner == .phone || reachabilityAtStop != .reachable)
    }

    /// The second Stop fallback: the owning watch was reachable at Stop, so
    /// the phone played nothing then, but `stopped` went unconfirmed.
    static func phonePlaysStopFallback(
        owner: HapticOwner,
        reachabilityAtStop: WatchReachability,
        stoppedDelivery: WatchDelivery,
        hapticsOn: Bool
    ) -> Bool {
        hapticsOn && owner == .watch && reachabilityAtStop == .reachable && stoppedDelivery == .notDelivered
    }

    static func phonePlaysGoFallback(
        owner: HapticOwner,
        startedDelivery: WatchDelivery,
        hapticsOn: Bool
    ) -> Bool {
        hapticsOn && owner == .watch && startedDelivery == .notDelivered
    }
}
