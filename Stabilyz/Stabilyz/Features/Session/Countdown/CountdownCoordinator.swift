import Foundation

/// Drives the start countdown ([PRD OQ-6], docs/04 §4.6, docs/07 §7.3).
///
/// The countdown is the seam between "the user tapped Start Test" and "the
/// session began", and this is what holds the two apart. It primes the sensors
/// at the tap, counts the numerals down, and calls `begin(at:)` at the final
/// tick with the anchor it stamped — so T-0 is the instant the user was shown
/// and felt, not whenever a call happened to be scheduled.
///
/// **No DSP, no buffer, no sensor.** It orchestrates `SessionRecorder` and the
/// two feedback services and nothing else [PRD Rule 12].
///
/// `@MainActor` because it drives a screen and publishes state to it; the
/// services it calls are actors and hop on their own.
@MainActor
@Observable
final class CountdownCoordinator {
    /// Where the countdown is, as the screen needs to see it.
    enum State: Equatable {
        /// Nothing started. Also where a cancelled or failed countdown is
        /// returned to once the user has seen the outcome.
        case idle
        /// Sensors coming up. The countdown has not started, because a
        /// countdown that had to stop and wait for hardware would be a
        /// countdown that lied about how long it was.
        case priming
        /// Counting. `secondsRemaining` is the numeral on screen.
        case counting(secondsRemaining: Int)
        /// Past T-0 — the session is recording.
        case running
        /// Priming or start failed. Carries the error the screen explains
        /// [PRD §7 AC — plain language, while the user is still watching].
        case failed(StabilyzError)
        /// The user cancelled, or the app was backgrounded. No session exists.
        case cancelled
    }

    private(set) var state: State = .idle

    /// The recorder's event stream, handed over once the session is running so
    /// the recording screen can take it. Nil until then.
    private(set) var recordingEvents: AsyncStream<SessionRecordingEvent>?

    private let recorder: SessionRecorder
    private let haptics: HapticFeedbackService
    private let audio: AudioFeedbackService
    private let ticker: CountdownTicker
    private let clock: Clock
    private let logService: LogService
    private let policy: CountdownPolicy

    /// The running countdown, so `cancel()` can interrupt a sleeping tick
    /// rather than letting the user wait out the rest of a second they have
    /// already decided against.
    private var countdownTask: Task<Void, Never>?

    init(
        recorder: SessionRecorder,
        haptics: HapticFeedbackService,
        audio: AudioFeedbackService,
        clock: Clock,
        logService: LogService,
        ticker: CountdownTicker = RealTimeCountdownTicker(),
        policy: CountdownPolicy = .v1
    ) {
        self.recorder = recorder
        self.haptics = haptics
        self.audio = audio
        self.clock = clock
        self.logService = logService
        self.ticker = ticker
        self.policy = policy
    }

    /// The numeral currently on screen, or nil when not counting.
    var visibleNumeral: Int? {
        if case .counting(let remaining) = state { return remaining }
        return nil
    }

    var isCounting: Bool { visibleNumeral != nil }

    // MARK: - Start

    /// Primes, counts down, and starts the session at the final tick.
    ///
    /// Returns immediately; the work runs in a task so `cancel()` can interrupt
    /// it. Await `waitUntilFinished()` to observe the outcome.
    ///
    /// Ignored if a countdown is already running — a double-tap on Start Test
    /// must not prime twice or leave a second countdown ticking behind the
    /// first.
    func start(mode: TestMode, audioConfig: SessionAudioConfig) {
        guard countdownTask == nil else { return }
        countdownTask = Task { [weak self] in
            await self?.run(mode: mode, audioConfig: audioConfig)
        }
    }

    /// Waits for the countdown to reach an outcome — running, cancelled or
    /// failed.
    func waitUntilFinished() async {
        await countdownTask?.value
    }

    // MARK: - Cancel

    /// Ends the countdown without a session ([PRD OQ-6], docs/07 §7.7).
    ///
    /// The user tapped Cancel, or the app was backgrounded. Interrupts the
    /// tick in progress, tears the primed sensors down, plays the stop pulse
    /// and lands on `.cancelled`. No session is created and nothing is marked
    /// invalid, because nothing was recorded.
    ///
    /// Does nothing once the session is `running`: past T-0 there is a real
    /// walk in progress, and ending it is `stop()`'s job, not this one's.
    func cancel() async {
        guard state != .running else {
            logService.log(.warning, .session, "countdown cancel ignored: the session is already running")
            return
        }

        countdownTask?.cancel()
        // Let `run` finish its own teardown rather than racing it — otherwise
        // the abort below and the task's cleanup could both be tearing the
        // recorder down at once.
        await countdownTask?.value
        countdownTask = nil

        await finishCancelled()
    }

    /// Returns to `.idle` once the screen has shown the outcome, so a cancelled
    /// or failed countdown can be retried.
    func reset() {
        guard state != .running else { return }
        state = .idle
        recordingEvents = nil
    }

    // MARK: - The sequence

    private func run(mode: TestMode, audioConfig: SessionAudioConfig) async {
        state = .priming

        // Warm the taps before anything is counting, so the first tick is not
        // the slow one. Never load-bearing: a device with no Taptic Engine
        // degrades silently here and the numerals carry the countdown alone
        // [PRD OQ-6].
        await haptics.prepare()

        do {
            try await recorder.prime(mode: mode, audioConfig: audioConfig)
        } catch {
            await failPriming(error)
            return
        }

        // Cancelled while the sensors were coming up. Priming succeeded, so
        // there is a primed recorder to take back down.
        if Task.isCancelled { return }

        // **Task 7.2.3, made unconditional.** Step Feedback and the Metronome
        // are armed by `begin`, never by `prime`, so neither can sound before
        // Go by construction. This is the belt to that structural brace: a beat
        // left running by an earlier flow would be counted over, and a
        // metronome under a haptic countdown is directly confusable with it.
        // Safe to call when nothing is running — it is a no-op.
        await audio.stopMetronome()

        for remaining in policy.countdownSequence {
            if Task.isCancelled { return }

            state = .counting(secondsRemaining: remaining)
            // The tap lands with the numeral, not after it.
            await haptics.playCadenceTick()
            await ticker.waitForTick(policy.tickInterval)
        }

        if Task.isCancelled { return }

        await reachT0()
    }

    /// Go.
    private func reachT0() async {
        // Stamped here, at the final tick, and handed to the recorder — so the
        // session's origin is the moment the countdown ended rather than the
        // moment `begin` was scheduled (docs/07 §7.4).
        let anchor = TimeAnchor(clock: clock)

        // The heavy, distinct tap, alongside the start tone the recorder
        // requests. Fired before `begin` rather than after, so what the user
        // feels marks T-0 rather than trailing it.
        await haptics.playSessionStart()

        do {
            recordingEvents = try await recorder.begin(at: anchor)
            state = .running
            logService.log(.info, .session, "countdown reached T-0; session started")
        } catch {
            // The session never opened, so the primed sensors are still ours
            // to release.
            await recorder.abort()
            await haptics.teardown()
            state = .failed(stabilyzError(from: error))
            logService.log(.error, .session, "countdown reached T-0 but the session refused to start")
        }
    }

    // MARK: - Outcomes

    private func failPriming(_ error: some Error) async {
        // `prime` already unwound itself on the way out. Aborting anyway is
        // harmless — it is a no-op from idle — and means this path does not
        // depend on remembering how far priming got.
        await recorder.abort()
        await haptics.teardown()
        state = .failed(stabilyzError(from: error))
        logService.log(.error, .session, "countdown abandoned: priming failed")
    }

    private func finishCancelled() async {
        await recorder.abort()
        // The same single pulse that ends a walk. A cancelled countdown is an
        // ending too, and the user who has already pocketed the phone needs to
        // feel that it stopped.
        await haptics.playSessionStop()
        await haptics.teardown()
        state = .cancelled
        recordingEvents = nil
        logService.log(.info, .session, "countdown cancelled before T-0; no session created")
    }

    /// Everything the recorder throws is a `StabilyzError`; this keeps the
    /// state's payload honest if that ever stops being true.
    private func stabilyzError(from error: some Error) -> StabilyzError {
        error as? StabilyzError ?? .recording(.notPrimed)
    }
}
