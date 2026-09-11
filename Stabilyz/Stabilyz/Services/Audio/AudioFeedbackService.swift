import Foundation

/// Route and interruption notifications from the audio session, surfaced as
/// domain values (docs/10-audio-feedback-architecture.md §10.3).
enum AudioFeedbackEvent: Sendable, Equatable {
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
protocol AudioFeedbackService: Sendable {
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

    /// Activates the audio session and gets the engine ready to play.
    ///
    /// On the protocol rather than only on the engine because the **recorder**
    /// owns this lifecycle: it is what knows when a session starts and ends, and
    /// an `AVAudioSession` that something activates has to be something's job to
    /// release. Safe to call repeatedly.
    func prepare() async

    /// Releases the engine and deactivates the audio session.
    ///
    /// Called after the stop tone, and it is the implementation's job to let
    /// that tone finish first (docs/10: "stop tone plays before teardown").
    func teardown() async
}

extension AudioFeedbackService {
    /// Nothing to build, and nothing to release.
    ///
    /// Only the engine-backed implementation owns an `AVAudioSession`. Silence
    /// and the test doubles have no state, so requiring them to write two empty
    /// methods each would be ceremony — but an implementation that *does* hold
    /// the session must override both, which is what the doc comments above say
    /// and what `SessionRecorder` relies on.
    func prepare() async {}
    func teardown() async {}
}
