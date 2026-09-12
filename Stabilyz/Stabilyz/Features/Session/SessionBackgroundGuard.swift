import SwiftUI

/// Whether leaving the foreground should end the countdown ([PRD OQ-6],
/// docs/07 §7.7).
///
/// A pure decision in its own type so the rule can be asserted without a scene
/// to drive — `scenePhase` is not something a unit test can transition.
///
/// **The rule is narrow on purpose.** Backgrounding during the *countdown*
/// cancels it: the five seconds exist so the user can get situated, and a
/// countdown that ran out while the app was away would start a walk nobody was
/// ready for. Backgrounding during the *walk* does not cancel — that is an
/// interruption, and the recorder already handles it as a gap the pipeline
/// decides the validity of (docs/07 §7.7). Ending a real walk because the user
/// answered a call would throw away data the PRD says to flag, not discard.
enum SessionBackgroundGuard {
    static func shouldCancelCountdown(
        scenePhase: ScenePhase,
        countdown: CountdownCoordinator.State
    ) -> Bool {
        guard isCountingIn(countdown) else { return false }

        switch scenePhase {
        case .background:
            return true
        case .inactive, .active:
            // `.inactive` is the app switcher opening, a notification banner,
            // and — critically — the screen going off. [PRD OQ-6] is explicit
            // that a user deliberately locking the phone as they pocket it is
            // the countdown working as intended, so this is not a cancellation.
            return false
        @unknown default:
            return false
        }
    }

    /// Priming and counting both: the sensors are up in each, and neither has
    /// a session behind it yet.
    private static func isCountingIn(_ state: CountdownCoordinator.State) -> Bool {
        switch state {
        case .priming, .counting: true
        case .idle, .running, .cancelled, .failed: false
        }
    }
}
