import ActivityKit
import Foundation

// The Live Activity nudge's shared types (Task 12.5.1, PRD §8).
//
// Compiled into two targets: the app, which starts and ends the nudge, and
// StabilyzLiveActivityExtension, which draws it. ActivityKit matches the two
// by type, so there is one copy, here.

/// The nudge on iOS 17: phone only — Lock Screen and Dynamic Island.
nonisolated struct WatchNudgeAttributes: ActivityAttributes {
    /// Nothing changes while the nudge shows.
    struct ContentState: Codable, Hashable {}
}

/// The nudge on iOS 18 and later, which also reaches the watch's Smart Stack
/// on watchOS 11 [PRD OQ-7b]. A separate type because a widget bundle can't
/// choose between two configurations of one type by OS version.
nonisolated struct WatchNudgeSmartStackAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {}
}

/// The nudge's words.
nonisolated enum WatchNudgeCopy {
    /// Lock Screen.
    static let title = "Open Stabilyz on your watch"
    static let detail = "See your timer and feel the countdown on your wrist."
    /// Dynamic Island, compact.
    static let dynamicIsland = "Open on watch"
    /// The watch's Smart Stack.
    static let smartStack = "Open Stabilyz"
}
