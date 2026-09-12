import SwiftUI
import Testing
@testable import Stabilyz

/// Backgrounding during the countdown ([PRD OQ-6], docs/07 §7.7).

// MARK: - Backgrounding cancels a countdown

@Test func backgroundingWhileCountingCancelsTheCountdown() {
    // The five seconds exist so the user can get situated. A countdown that ran
    // out while the app was away would start a walk nobody was ready for.
    for remaining in 1...5 {
        #expect(SessionBackgroundGuard.shouldCancelCountdown(
            scenePhase: .background,
            countdown: .counting(secondsRemaining: remaining)
        ))
    }
}

@Test func backgroundingWhilePrimingAlsoCancels() {
    // Sensors are already up, and there is still no session behind them.
    #expect(SessionBackgroundGuard.shouldCancelCountdown(
        scenePhase: .background,
        countdown: .priming
    ))
}

// MARK: - What must not cancel

@Test func screenOffDoesNotCancelTheCountdown() {
    // [PRD OQ-6] A user deliberately locking the phone as they pocket it is the
    // countdown working as intended. `.inactive` is that, plus the app switcher
    // and notification banners — none of which is leaving the app.
    #expect(SessionBackgroundGuard.shouldCancelCountdown(
        scenePhase: .inactive,
        countdown: .counting(secondsRemaining: 3)
    ) == false)
}

@Test func backgroundingARunningWalkDoesNotCancelIt() {
    // That is an interruption, not a cancellation: the recorder marks the gap
    // and the pipeline decides validity (docs/07 §7.7). Discarding the walk
    // because the user answered a call would throw away data the PRD says to
    // flag rather than bin.
    #expect(SessionBackgroundGuard.shouldCancelCountdown(
        scenePhase: .background,
        countdown: .running
    ) == false)
}

@Test func thereIsNothingToCancelBeforeOrAfterACountdown() {
    for state: CountdownCoordinator.State in [
        .idle, .cancelled, .failed(.sensor(.primingTimeout))
    ] {
        #expect(SessionBackgroundGuard.shouldCancelCountdown(
            scenePhase: .background,
            countdown: state
        ) == false)
    }
}

@Test func returningToTheForegroundCancelsNothing() {
    #expect(SessionBackgroundGuard.shouldCancelCountdown(
        scenePhase: .active,
        countdown: .counting(secondsRemaining: 2)
    ) == false)
}
