import Foundation

/// Where the metronome's beats fall on the engine's sample timeline
/// (docs/10 §10.1 — a steady, pre-scheduled timeline, not a `Timer`).
///
/// Pure arithmetic on frame counts, so the timing this app's metronome will
/// actually produce is testable without an audio route — which matters, because
/// "steady" is the whole claim and a listener is not a test.
///
/// The beat interval is rounded to a whole number of frames **once**, and every
/// later beat is that many frames after the previous one. Rounding per beat
/// would let the error walk, which is audible as drift over a six-minute walk.
///
/// It has no notion of a step. That is the inverse of `StepTickGate`, which has
/// no notion of an interval: the metronome schedules and never mirrors steps,
/// Step Feedback mirrors steps and never schedules [PRD OQ-4].
struct MetronomeSchedule: Sendable, Equatable {
    let sampleRate: Double
    /// Frames between beats. Fixed for the life of the schedule.
    let framesPerBeat: Int64
    /// The frame the next beat lands on.
    private(set) var nextBeatFrame: Int64

    /// Nil for a tempo or a format that cannot produce beats — a zero sample
    /// rate, or an interval shorter than a single frame. Silence is the right
    /// answer there; a schedule that fires every frame is not.
    init?(interval: Duration, sampleRate: Double, startingAt frame: Int64) {
        let seconds = Double(interval.components.seconds)
            + Double(interval.components.attoseconds) / 1e18

        guard sampleRate > 0, seconds.isFinite, seconds > 0 else { return nil }

        let frames = (seconds * sampleRate).rounded()
        guard frames >= 1, frames <= Double(Int64.max) else { return nil }

        self.sampleRate = sampleRate
        self.framesPerBeat = Int64(frames)
        self.nextBeatFrame = frame
    }

    /// Returns the next beat's frame and advances the schedule.
    ///
    /// The only mutation on the scheduling path: two integer operations, no
    /// allocation, nothing to grow. Beats are handed out one at a time so a
    /// caller can fill the engine's queue without an array in between.
    mutating func nextBeat() -> Int64 {
        defer { nextBeatFrame += framesPerBeat }
        return nextBeatFrame
    }

    /// Restarts the beat grid from `frame`, discarding everything that would
    /// have played before it.
    ///
    /// Used on resume after an interruption: the metronome comes back at tempo
    /// from now, and the beats missed while a call was in progress are never
    /// replayed as a burst [PRD §6 — never crash, never freeze; a flurry of
    /// catch-up beats would also be its own kind of failure].
    mutating func reanchor(at frame: Int64) {
        nextBeatFrame = frame
    }
}
