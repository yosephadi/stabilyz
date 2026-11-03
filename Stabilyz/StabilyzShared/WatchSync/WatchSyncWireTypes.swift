import Foundation

/// The contract's own copy of the session mode (docs/04 §4.18).
///
/// Deliberately not `TestMode`: the domain type lives in the iOS app's
/// `Domain/`, which the watch target does not compile, and its raw values are
/// persisted, so the two must be free to change independently. The phone maps
/// between them in `Services/Watch/WatchSyncMapping.swift`.
///
/// **The raw values are the wire format and must not change.** A rename here
/// needs a new `WatchSyncVersion`.
nonisolated enum WireTestMode: String, Codable, Sendable, CaseIterable {
    case quick
    case full
}

/// Which device plays the session haptics, fixed when the countdown starts
/// counting [PRD §8 decision 3].
///
/// **The raw values are the wire format and must not change.**
nonisolated enum WireHapticOwner: String, Codable, Sendable, CaseIterable {
    case phone
    case watch
}
