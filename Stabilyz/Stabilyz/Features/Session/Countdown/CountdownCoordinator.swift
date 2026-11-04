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
    private let watchSession: WatchSessionService

    /// The session this countdown is for, as the watch knows it. Minted per
    /// `start`, so a late message about an earlier attempt can be told apart.
    private(set) var sessionID: UUID?

    /// Who plays the session haptics [PRD §8 decision 3]. Nil until the
    /// countdown starts counting; then fixed for the session.
    private(set) var hapticOwner: HapticOwner?

    /// The user's Start & Stop Haptics choice, as it stands now. Set at
    /// `start`, and updated mid-walk through `hapticsSettingChanged`.
    private var hapticsEnabled = true

    /// Messages to the watch in flight. Sent from tasks so a slow or absent
    /// watch never holds the countdown up; kept so tests can wait for them.
    private var watchTasks: [Task<Void, Never>] = []

    /// Called once when the watch asks to stop the running session
    /// (Task 12.3.2). The cover points it at `ActiveSessionViewModel.stop()`,
    /// the same entry point as the Stop button and the clock reaching 00:00.
    var onWatchStop: (@MainActor () -> Void)?

    /// Listens for the watch's stop requests from T-0 until the walk stops.
    private var stopListener: Task<Void, Never>?

    /// Set once the walk has stopped, from either device or the clock, so a
    /// late or repeated request is dropped.
    private var isSessionStopped = false

    /// What this countdown actually plays through: `haptics` when the user left
    /// Start & Stop Haptics on, a silent double when they turned it off.
    ///
    /// **Swapped once, at `start`, rather than checked at each call.** Every
    /// haptic this type plays — the warm-up, each tick, Go, the cancel pulse —
    /// goes through here, so a disabled countdown cannot leak one through a
    /// branch someone forgot to guard. It is re-chosen on every `start`, so a
    /// retry after a cancel honours whatever the user has chosen since.
    ///
    /// Turning haptics off costs the user nothing they need: the numerals run
    /// regardless, which is the channel [PRD §7 AC] requires — "if haptics are
    /// unavailable or disabled, the countdown runs on the visible channel
    /// alone".
    private var cues: HapticFeedbackService

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
        policy: CountdownPolicy = .v1,
        watchSession: WatchSessionService = SilentWatchSessionService()
    ) {
        self.recorder = recorder
        self.haptics = haptics
        self.cues = haptics
        self.audio = audio
        self.clock = clock
        self.logService = logService
        self.ticker = ticker
        self.policy = policy
        self.watchSession = watchSession
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
    /// - Parameter hapticsEnabled: the user's Start & Stop Haptics choice. Off
    ///   means no tick, no Go and no cancel pulse — nothing felt at all.
    func start(mode: TestMode, audioConfig: SessionAudioConfig, hapticsEnabled: Bool = true) {
        guard countdownTask == nil else { return }
        cues = hapticsEnabled ? haptics : SilentHapticFeedbackService()
        self.hapticsEnabled = hapticsEnabled
        sessionID = UUID()
        hapticOwner = nil
        isSessionStopped = false
        stopListener?.cancel()
        stopListener = nil
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
        await cues.prepare()

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

        for (index, remaining) in policy.countdownSequence.enumerated() {
            if Task.isCancelled { return }

            if index == 0 { await chooseHapticOwner(mode: mode) }
            state = .counting(secondsRemaining: remaining)
            // The tap lands with the numeral, not after it.
            await cues.playCadenceTick()
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

        // The sustained, distinct vibration, alongside the start tone the
        // recorder requests. Fired before `begin` rather than after, so what the
        // user feels marks T-0 rather than trailing it — and the service returns
        // as soon as the vibration is scheduled, so its own length does not push
        // the session open behind the anchor stamped above.
        await cues.playSessionStart()

        do {
            recordingEvents = try await recorder.begin(at: anchor)
            state = .running
            logService.log(.info, .session, "countdown reached T-0; session started")
            sendStarted(t0: anchor.wallClock)
            listenForWatchStop()
        } catch {
            // The session never opened, so the primed sensors are still ours
            // to release.
            await recorder.abort()
            await cues.teardown()
            sendToWatch { .cancelled(sessionID: $0) }
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
        await cues.teardown()
        state = .failed(stabilyzError(from: error))
        logService.log(.error, .session, "countdown abandoned: priming failed")
    }

    private func finishCancelled() async {
        await recorder.abort()
        // The same vibration that ends a walk. A cancelled countdown is an ending
        // too, and the user who has already pocketed the phone needs to feel
        // that it stopped.
        await cues.playSessionStop()
        await cues.teardown()
        sendToWatch { .cancelled(sessionID: $0) }
        state = .cancelled
        recordingEvents = nil
        logService.log(.info, .session, "countdown cancelled before T-0; no session created")
    }

    // MARK: - The watch (Task 12.3.1)

    /// Fixes the haptic owner, at the first numeral and before its tick.
    ///
    /// If the watch owns, the phone's countdown taps go silent — the phone
    /// still shows the numerals and plays every sound [PRD §8 decision 3].
    /// Then the watch is told the countdown has begun and when Go is planned.
    private func chooseHapticOwner(mode: TestMode) async {
        let owner = HapticOwner(for: await watchSession.currentReachability())
        hapticOwner = owner
        if owner == .watch {
            await cues.teardown()
            cues = SilentHapticFeedbackService()
        }

        let countdownLength = policy.tickInterval.seconds * Double(policy.tickCount)
        let plannedGoAt = clock.now.addingTimeInterval(countdownLength)
        let hapticsEnabled = hapticsEnabled
        sendToWatch {
            .countdownStarted(
                sessionID: $0,
                mode: WireTestMode(mode),
                durationSeconds: WatchSyncMapping.durationSeconds(for: mode),
                plannedGoAt: plannedGoAt,
                hapticOwner: owner.wire,
                hapticsEnabled: hapticsEnabled
            )
        }
        logService.log(.info, .session, "countdown: haptics owned by the \(owner == .watch ? "watch" : "phone")")
    }

    /// Tells the watch Go happened. If the owning watch did not confirm it,
    /// the phone plays the Go pulse instead, so Go is never silent to touch.
    private func sendStarted(t0: Date) {
        guard let id = sessionID, let owner = hapticOwner else { return }
        let watchSession = watchSession
        let haptics = haptics
        let hapticsOn = hapticsEnabled
        let logService = logService
        let previous = watchTasks.last
        watchTasks.append(Task {
            await previous?.value
            let delivery = await watchSession.send(.started(sessionID: id, t0: t0))
            if HapticOwnership.phonePlaysGoFallback(owner: owner, startedDelivery: delivery, hapticsOn: hapticsOn) {
                logService.log(.info, .session, "countdown: watch missed Go; the phone played it")
                await haptics.playSessionStart()
            }
        })
    }

    /// The walk ended: plays the Stop pulse if the phone should, and tells the
    /// watch.
    ///
    /// The phone plays it when it owns the haptics, and also when the owning
    /// watch is not reachable at Stop — a Stop is never silent to touch. Off
    /// when Start & Stop Haptics is off. The pulse comes first, so the user
    /// feels the end the moment it happens.
    func sessionStopped(hapticsOn: Bool) async {
        isSessionStopped = true
        stopListener?.cancel()
        stopListener = nil
        self.hapticsEnabled = hapticsOn
        let owner = hapticOwner ?? .phone
        let reachability = await watchSession.currentReachability()
        if HapticOwnership.phonePlaysStopPulse(owner: owner, reachabilityAtStop: reachability, hapticsOn: hapticsOn) {
            await haptics.playSessionStop()
        }
        sendToWatch { .stopped(sessionID: $0) }
    }

    /// Routes the watch's stop requests for this session to `onWatchStop`,
    /// through `WatchStopFilter`.
    private func listenForWatchStop() {
        let requests = watchSession.stopRequests()
        stopListener = Task { [weak self] in
            for await request in requests {
                guard let self else { return }
                self.handleWatchStop(request)
            }
        }
    }

    private func handleWatchStop(_ request: WatchStopRequest) {
        guard WatchStopFilter.accepts(
            request,
            currentSession: sessionID,
            isRunning: state == .running,
            alreadyStopped: isSessionStopped
        ) else {
            logService.log(.info, .session, "watch: stop request dropped")
            return
        }
        // Marked here, not only in `sessionStopped`, so a second request that
        // lands before the walk has finished stopping is dropped too.
        isSessionStopped = true
        logService.log(.info, .session, "watch: stop requested from the watch")
        onWatchStop?()
    }

    /// The user changed Start & Stop Haptics mid-walk. It governs the watch
    /// too [PRD §8 decision 3]. (Before the countdown starts counting, the
    /// choice travels in `countdownStarted` instead.)
    func hapticsSettingChanged(_ enabled: Bool) {
        hapticsEnabled = enabled
        guard hapticOwner != nil else { return }
        sendToWatch { _ in .hapticsChanged(enabled: enabled) }
    }

    /// Waits for every message to the watch sent so far, including the Go
    /// fallback. For tests; production never waits on the watch.
    func watchSyncSettled() async {
        let tasks = watchTasks
        for task in tasks { await task.value }
    }

    /// Sends a message for this session from a task, once the watch has been
    /// told the countdown started. Before that the watch knows nothing about
    /// this session, so there is nothing to tell it.
    ///
    /// Each send waits for the one before it, so the watch hears them in the
    /// order they happened: a cancel can never overtake the countdown it
    /// cancels.
    private func sendToWatch(_ message: @escaping @Sendable (UUID) -> PhoneToWatchMessage) {
        guard let id = sessionID, hapticOwner != nil else { return }
        let watchSession = watchSession
        let previous = watchTasks.last
        watchTasks.append(Task {
            await previous?.value
            await watchSession.send(message(id))
        })
    }

    /// Everything the recorder throws is a `StabilyzError`; this keeps the
    /// state's payload honest if that ever stops being true.
    private func stabilyzError(from error: some Error) -> StabilyzError {
        error as? StabilyzError ?? .recording(.notPrimed)
    }
}
