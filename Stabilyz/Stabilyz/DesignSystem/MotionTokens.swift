import CoreGraphics
import Foundation

/// Durations and easings (design-system.md §10).
///
/// Motion in this app is short and gets out of the way. §1's "no decoration
/// without function" applies to time as much as to pixels: the only movement
/// here either confirms a touch or covers a hand-off, and a user in their 70s
/// waiting on an animation to finish before they can act is the failure this
/// scale exists to keep small.
///
/// Every duration is in seconds, which is what SwiftUI's `Animation` takes, so
/// no call site converts anything.
enum Motion {

    // MARK: - Splash

    /// The brand reveal: the mark fading and settling into place.
    static let splashReveal: TimeInterval = 0.6
    /// How long the mark holds at rest before the app takes over. Long enough
    /// to read as deliberate, short enough that it is never a wait.
    static let splashHold: TimeInterval = 0.3
    /// Launch to hand-off.
    ///
    /// **Unchanged by Reduce Motion.** That setting governs how things move,
    /// not when they happen — a launch that finished in a third of the time
    /// because the user turned animation off would be a different app, not an
    /// accessible one. With it on, the mark is simply already there.
    static var splashTotal: TimeInterval { splashReveal + splashHold }
    /// Where the mark starts. Close enough to 1 that it reads as settling
    /// rather than growing.
    static let splashInitialScale: CGFloat = 0.92

    // MARK: - Root

    /// The cross-fade from the splash to the app's first real screen. Faster
    /// than the reveal: this one is covering a change, not performing one.
    static let rootCrossFade: TimeInterval = 0.35

    // MARK: - Controls

    /// A button acknowledging a touch. Barely perceptible on purpose.
    static let buttonPress: TimeInterval = 0.15
}
