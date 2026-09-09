import Foundation

/// Connects live footfalls to the tick sound (docs/10 §10.1, §10.4, Task 7.2.1).
///
/// The whole of Step Feedback's behaviour lives here: it *subscribes* to the
/// recorder's `LiveStepEvent` stream, gates each event, and asks the audio
/// service for a tick. It never writes to the sample buffer, never calls the
/// pipeline, and holds no reference into processing (docs/10 §10.4).
///
/// **Reactive, never a tempo** [PRD AC, OQ-4]. There is no timer, no interval
/// and nothing scheduled anywhere in this type: a tick exists only because a
/// step happened, so irregular walking produces irregular ticks and standing
/// still produces silence. That is the difference between this and the
/// metronome of Task 7.2.2, and it is the reason they are two components rather
/// than one with a flag.
///
/// **Off by default** [PRD AC]. Without the session's opt-in the wiring is
/// inert: `start` returns without creating a consumer, so nothing is heard and
/// the event stream is not even read.
///
/// An actor, so the refractory window has one owner. The tick path from here is
/// a gate decision and an `await` into the audio service — no allocation, no
/// main-actor hop, and nothing that would undo the preloaded design of
/// Task 7.1.1.
actor StepFeedbackBridge {
    private let audioFeedback: AudioFeedbackService
    private let policy: LiveStepDetectionPolicy
    private let logService: LogService

    private var gate: StepTickGate
    /// Nil until the first session opts in; long-lived thereafter. See `start`.
    private var consumer: Task<Void, Never>?
    /// Whether a session is currently entitled to ticks.
    private var isArmed = false

    /// Ticks actually requested of the audio service.
    ///
    /// Exists so the wiring is observable: "no opt-in means no ticks" and "a
    /// suspended service drops rather than queues" are otherwise claims about
    /// something inaudible. Not used by any decision here.
    private(set) var tickCount = 0

    init(audioFeedback: AudioFeedbackService, policy: LiveStepDetectionPolicy, logService: LogService) {
        self.audioFeedback = audioFeedback
        self.policy = policy
        self.logService = logService
        self.gate = StepTickGate(policy: policy)
    }

    /// Whether the event stream is being read at all.
    var isConsuming: Bool { consumer != nil }

    /// Arms the wiring for one session.
    ///
    /// Does nothing at all unless the session opted into Step Feedback: no
    /// ticks and no stream consumption [PRD AC — off by default].
    ///
    /// The consumer is created at most once and is deliberately **not**
    /// cancelled by `stop`. The recorder's step stream is long-lived and shared
    /// across sessions (docs/07 §7.2), and cancelling a task iterating an
    /// `AsyncStream` terminates that stream permanently — the second session
    /// would then be silent forever. Disarming is what ends a session's ticks;
    /// the consumer parks on a stream that emits nothing between sessions,
    /// because the recorder only runs its detector while recording.
    func start(audioConfig: SessionAudioConfig, events: AsyncStream<LiveStepEvent>) {
        guard audioConfig == .stepFeedback else { return }

        gate.reset()
        isArmed = true
        logService.log(.info, .audio, "step feedback armed")

        guard consumer == nil else { return }
        consumer = Task { [weak self] in
            for await event in events {
                guard let self else { break }
                await self.handle(event)
            }
        }
    }

    /// Ends this session's ticks. Anything already in flight is dropped, never
    /// replayed — a tick arriving after the walk has ended is worse than no
    /// tick (Task 7.1.1's decision, and 7.1.2's).
    func stop() {
        guard isArmed else { return }
        isArmed = false
        gate.reset()
    }

    /// One event, gated.
    ///
    /// Nothing here can fail a session: the audio service is non-throwing by
    /// contract, and a service that is suspended or degraded drops the tick
    /// silently (docs/10 §10.4).
    private func handle(_ event: LiveStepEvent) async {
        guard isArmed, gate.admits(event) else { return }
        tickCount += 1
        await audioFeedback.playStepTick()
    }

    /// Waits for the consumer to finish, which happens only once its source
    /// stream has finished.
    ///
    /// For teardown and for tests that need the ticks for a finished stream to
    /// have been counted. Never called on the tick path.
    func drain() async {
        await consumer?.value
        consumer = nil
    }
}
