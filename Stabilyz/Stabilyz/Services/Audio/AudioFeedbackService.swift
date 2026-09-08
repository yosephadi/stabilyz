import Foundation

/// Route and interruption notifications from the audio session, surfaced as
/// domain values (docs/10-audio-feedback-architecture.md §10.3).
nonisolated enum AudioFeedbackEvent: Sendable, Equatable {
    case routeChanged
    case interrupted
    case interruptionEnded
    /// Playback stopped or degraded silently; the session is unaffected (docs/10 §10.4).
    case degraded
}

/// One service front over the two distinct audio engines — reactive Step
/// Feedback and the scheduled Metronome — plus session tones
/// (docs/10-audio-feedback-architecture.md §10.1, §10.2).
///
/// No method throws: audio failure is logged and surfaced only as silent
/// degradation, and can never fail a session (docs/10 §10.4, docs/15 §15.1).
/// This service subscribes to step events; it never writes to the sample buffer
/// and never calls the processing pipeline (docs/10 §10.4).
nonisolated protocol AudioFeedbackService: Sendable {
    var events: AsyncStream<AudioFeedbackEvent> { get }

    func playStartTone() async
    func playStopTone() async

    /// Fires one tick for a confidence-gated, refractory-passed step (docs/10 §10.3).
    func playStepTick() async

    /// Interval is `60 / bpm`, from the mode's `Baseline.cadenceBPM` (docs/10 §10.1).
    func startMetronome(bpm: Double) async
    func stopMetronome() async

    func suspend() async
    func resume() async
}
