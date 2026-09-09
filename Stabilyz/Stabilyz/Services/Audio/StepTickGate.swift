import Foundation

/// Decides whether a live step event earns a sound (docs/10 §10.3, Task 7.2.1).
///
/// Two gates, in order: confidence, then refractory. Only steps the detector
/// was confident about make a sound — a raw spike must never create an
/// accidental rhythm [PRD §6, OQ-4] — and one footfall must never produce two
/// or three beeps [PRD §6, §7].
///
/// This repeats gates the `LiveStepDetector` already applies, deliberately.
/// The detector's job is to find footfalls; this one's job is to decide what is
/// audible, and it is the last thing between an event and a sound. Keeping the
/// decision here means the audible contract holds whatever a future detector
/// emits, and it can be tested without one.
///
/// A struct with no allocation and no clock: the decision is arithmetic on the
/// event's own device timestamp, which keeps the tick path as short as [PRD §7]
/// requires and — just as importantly — leaves nothing that could schedule.
struct StepTickGate {
    private let policy: LiveStepDetectionPolicy
    /// The last event that produced a tick. The refractory window is measured
    /// from the last *tick*, not the last event, so a suppressed event cannot
    /// extend the silence.
    private var lastTick: TimeInterval?

    init(policy: LiveStepDetectionPolicy) {
        self.policy = policy
    }

    /// Whether this event should make a sound, advancing the window if so.
    mutating func admits(_ event: LiveStepEvent) -> Bool {
        guard event.confidence >= policy.confidenceThreshold else { return false }

        if let lastTick {
            // Device timestamps are monotonic (docs/07 §7.4); an out-of-order
            // event yields a negative interval and is suppressed, which is the
            // right answer for a sound cue.
            guard Duration.seconds(event.deviceTimestamp - lastTick) >= policy.refractory else {
                return false
            }
        }

        lastTick = event.deviceTimestamp
        return true
    }

    /// Clears the window between sessions, so the first step of a new walk is
    /// never judged against the last step of the previous one.
    mutating func reset() {
        lastTick = nil
    }
}
