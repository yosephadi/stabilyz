import Foundation

/// Owns the start/stop lifecycle of a recording (docs/07 §7.2, §7.3).
///
/// An actor, so sensor lifecycle and buffering are serialised. Created once at
/// the composition root and restarted per session through `begin`/`stop`,
/// never recreated ad hoc (docs/12 §12.3).
///
/// It orchestrates only. There is no DSP here: gap identification is delegated
/// to the pure `SampleIngestion` stage, and scoring happens later, off the
/// recorder [PRD Rule 10, Rule 12].
actor SessionRecorder {
    /// `idle → priming → primed → running → idle` (docs/07 §7.3).
    ///
    /// There is no distinct `stopped`: a recorder is reused across sessions
    /// (docs/12 §12.3), so the only thing a terminal state could mean is
    /// "ready for the next session", which is what `idle` already means.
    /// `stop()` and `abort()` both land back there.
    private enum State: Equatable {
        /// No session. The only state `prime` will start from.
        case idle
        /// Sensors are being brought up. Transient, and never observed by a
        /// caller — it exists so a second `prime` during the first is refused
        /// rather than racing it.
        case priming
        /// Sensors are live and delivering, the buffer exists but is unarmed.
        /// This is the countdown: every sample that arrives is turned away at
        /// admission (ledger entry 29).
        case primed
        /// Past T-0. The buffer is armed and the walk is being recorded.
        case running
    }

    private let motionSensor: MotionSensorService
    private let pedometer: PedometerService
    private let audioFeedback: AudioFeedbackService
    private let interruptionObserver: SessionInterruptionObserver
    private let screenSleep: ScreenSleepController
    private let clock: Clock
    private let logService: LogService
    private let fileIO: FileIO
    /// Every tunable the recorder needs, from the one place they are declared.
    private let configuration: AlgorithmConfiguration

    /// Live footfalls for audio feedback (docs/07 §7.2). Long-lived and shared,
    /// so the audio layer subscribes once rather than per session. Audio
    /// *subscribes*; it never writes back (docs/10 §10.4).
    nonisolated let stepEvents: AsyncStream<LiveStepEvent>
    private nonisolated let stepContinuation: AsyncStream<LiveStepEvent>.Continuation
    /// Turns those footfalls into sound (Task 7.2.1). Built here rather than
    /// injected because it needs exactly what the recorder already holds — the
    /// audio service and the live-detection policy — and because the recorder
    /// is the one component that knows when a session starts and ends.
    ///
    /// It only ever reads `stepEvents`. Nothing on the sample path waits for
    /// it (docs/10 §10.4).
    private let stepFeedback: StepFeedbackBridge

    private var state: State = .idle
    /// Bounded, with a scratch file behind it (docs/07 §7.2, docs/14 §14.3).
    private var sampleBuffer: SessionSampleBuffer?
    private var pedometerEvents: [PedometerEvent] = []
    private var anchor: TimeAnchor?
    private var startedAt: Date?
    private var mode: TestMode?
    private var audioConfig: SessionAudioConfig = .none
    private var interruptionCount = 0
    /// When the user silenced the audio cue, from T-0. Nil unless they did.
    private var audioSilencedAt: Duration?
    /// Recorded on the session so later analysis knows the pedometer
    /// cross-check was not available for it.
    private var pedometerAvailable = true

    private var eventContinuation: AsyncStream<SessionRecordingEvent>.Continuation?
    private var sampleTask: Task<Void, Never>?
    private var pedometerTask: Task<Void, Never>?
    /// Live from `prime`, consumed from `begin`.
    ///
    /// Held rather than drained during the countdown. Both streams are
    /// unbounded, so the lead-in accumulates without stalling the sensor, and
    /// consuming it before T-0 would mean racing the arm: a sample that *is*
    /// at-or-after T-0 could be read while the buffer was still unarmed and be
    /// rejected — a hole in the recording exactly at its start. Draining after
    /// arming lets the timestamp decide every sample's fate, which is the
    /// admission contract doing its job (ledger entry 29).
    private var primedSampleStream: AsyncStream<SensorSample>?
    private var primedPedometerStream: AsyncStream<PedometerEvent>?
    private var interruptionTask: Task<Void, Never>?
    /// Device timestamp when the app was suspended, so the resulting gap can be
    /// attributed to the interruption rather than to sensor trouble.
    private var suspendedAt: TimeInterval?
    /// Nil unless the session opted into Step Feedback — detection is skipped
    /// entirely otherwise, so an unused session pays nothing per sample.
    private var stepDetector: LiveStepDetector?
    private var lastSampleTimestamp: TimeInterval?
    private var lastReportedSecond = -1

    init(
        motionSensor: MotionSensorService,
        pedometer: PedometerService,
        audioFeedback: AudioFeedbackService,
        interruptionObserver: SessionInterruptionObserver,
        screenSleep: ScreenSleepController,
        clock: Clock,
        logService: LogService,
        fileIO: FileIO,
        configuration: AlgorithmConfiguration = .v1
    ) {
        self.motionSensor = motionSensor
        self.pedometer = pedometer
        self.audioFeedback = audioFeedback
        self.interruptionObserver = interruptionObserver
        self.screenSleep = screenSleep
        self.clock = clock
        self.logService = logService
        self.fileIO = fileIO
        self.configuration = configuration

        let (stream, continuation) = AsyncStream<LiveStepEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
        stepEvents = stream
        stepContinuation = continuation
        stepFeedback = StepFeedbackBridge(
            audioFeedback: audioFeedback,
            policy: configuration.liveStepFeedback,
            logService: logService
        )
    }

    var isRecording: Bool { state == .running }

    /// Sensors are live but the session has not started — the countdown.
    var isPrimed: Bool { state == .primed }

    /// Samples admitted to the session so far. Zero for the whole countdown.
    var admittedSampleCount: Int { sampleBuffer?.count ?? 0 }

    // MARK: - Prime

    /// Brings the sensors up during the countdown, before the session exists
    /// (docs/07 §7.3, [PRD OQ-6]).
    ///
    /// Priming is where every way a session can fail to start is discovered —
    /// permission, absent hardware, a sensor that never delivers — and it runs
    /// while the user is still watching the screen. That is the whole point of
    /// splitting it out: at Go the phone may already be in a pocket, so a
    /// failure discovered then is a failure nobody sees.
    ///
    /// The motion service owns the latency budget and throws
    /// `sensor(.primingTimeout)` if the first sample never arrives, so `start`
    /// returning means the sensor is genuinely delivering, not merely asked to.
    /// The recorder does not re-time it: one budget, in one place.
    ///
    /// Samples begin flowing here, and the buffer is deliberately left
    /// **unarmed** — every one of them is turned away at admission until
    /// `begin(at:)` opens the session (ledger entry 29).
    func prime(mode: TestMode, audioConfig: SessionAudioConfig) async throws {
        guard state == .idle else {
            throw StabilyzError.recording(.alreadyRecording)
        }

        resetSessionState()
        state = .priming
        self.mode = mode
        self.audioConfig = audioConfig

        do {
            // A denied Motion & Fitness permission stops a session outright —
            // it is not a degradable condition (docs/07 §7.6, docs/15 §15.1).
            try await requirePermission()
            // Authorised but absent is still no measurement. Checked here so
            // the countdown never starts against hardware that cannot deliver.
            guard await motionSensor.isAvailable else {
                logService.log(.error, .session, "priming refused: motion hardware unavailable")
                throw StabilyzError.sensor(.unavailable)
            }
        } catch {
            resetSessionState()
            throw error
        }

        // Exists so arriving samples have somewhere to be turned away from.
        sampleBuffer = SessionSampleBuffer(fileIO: fileIO, logService: logService)
        if audioConfig == .stepFeedback {
            stepDetector = LiveStepDetector(policy: configuration.liveStepFeedback)
        }

        let sampleStream: AsyncStream<SensorSample>
        do {
            sampleStream = try await motionSensor.start(policy: configuration.motionAcquisition)
        } catch {
            // Nothing was recorded, so leave no half-primed recorder behind.
            await tearDown()
            logService.log(.error, .session, "priming failed: sensors never delivered")
            throw error
        }

        // The pedometer is context and cross-check data (docs/05 §5.1), not the
        // measurement. Absent hardware degrades segmentation hints and must not
        // fail a session the accelerometer can still measure. A *denied*
        // permission is different and stops the session.
        var pedometerStream: AsyncStream<PedometerEvent>?
        do {
            pedometerStream = try await pedometer.start()
        } catch {
            if let denial = await permissionDenial(of: pedometer.authorizationStatus) {
                await tearDown()
                logService.log(.error, .session, "priming refused: motion permission denied")
                throw denial
            }
            logService.log(.warning, .session, "pedometer unavailable; continuing without step context")
        }
        pedometerAvailable = pedometerStream != nil

        // Held, not consumed — see `primedSampleStream`. The countdown's
        // samples accumulate in the stream and are drained at Go, where the
        // admission gate rejects every one of them on its timestamp.
        primedSampleStream = sampleStream
        primedPedometerStream = pedometerStream

        // [REC] The countdown exists so the user can stow the phone, so the
        // idle timer goes down for the countdown *and* the session, not just
        // the session (docs/07 §7.7). `stop()` and `abort()` both restore it.
        await screenSleep.preventSleep()

        state = .primed
        logService.log(.info, .session, "sensors primed: mode=\(mode.rawValue)")
    }

    // MARK: - Begin

    /// Opens the session at T-0 and returns the UI event stream (docs/07 §7.3).
    ///
    /// Called at Go — the final countdown tick — with the anchor the countdown
    /// itself stamped, so T-0 is the instant the user was shown and felt, not
    /// whenever this call happened to be scheduled.
    ///
    /// Requires a primed recorder. `begin` does not prime on your behalf: doing
    /// so would put a variable, multi-hundred-millisecond sensor spin-up
    /// *after* the instant the session claims to have started, which is exactly
    /// the ambiguity the countdown was introduced to remove.
    func begin(at anchor: TimeAnchor) async throws -> AsyncStream<SessionRecordingEvent> {
        guard state != .running else {
            throw StabilyzError.recording(.alreadyRecording)
        }
        guard state == .primed, let mode else {
            throw StabilyzError.recording(.notPrimed)
        }

        // Everything that opens the session happens without suspending. Samples
        // are already being consumed, so a suspension between arming the buffer
        // and declaring the state would let an at-or-after-T-0 sample meet an
        // unarmed buffer and be dropped — a hole in the recording precisely at
        // its start.
        self.anchor = anchor
        startedAt = anchor.wallClock
        sampleBuffer?.arm(at: anchor)

        let (events, continuation) = AsyncStream<SessionRecordingEvent>.makeStream(bufferingPolicy: .unbounded)
        eventContinuation = continuation
        state = .running

        // Draining starts only now that the buffer is armed. The countdown's
        // accumulated samples come through first and are rejected on their
        // timestamps, which is also what makes the drop count reported at
        // freeze the true size of the lead-in.
        if let sampleStream = primedSampleStream {
            sampleTask = Task { [weak self] in
                for await sample in sampleStream {
                    await self?.ingest(sample)
                }
            }
        }
        if let pedometerStream = primedPedometerStream {
            pedometerTask = Task { [weak self] in
                for await event in pedometerStream {
                    await self?.ingest(event)
                }
            }
        }
        primedSampleStream = nil
        primedPedometerStream = nil

        // Inert unless this session opted in [PRD AC — Step Feedback is off by
        // default]. This is the bridge, not the audio layer: it subscribes to a
        // stream and returns; it never awaits a tone. A footfall detected in
        // the few microseconds before it subscribes is held by the step
        // stream's buffering policy rather than lost.
        await stepFeedback.start(audioConfig: audioConfig, events: stepEvents)

        // Any suspension stops sample delivery, so observation has to be live
        // before the session is declared ready (docs/07 §7.7).
        let interruptions = await interruptionObserver.startObserving()
        interruptionTask = Task { [weak self] in
            for await interruption in interruptions {
                await self?.handle(interruption)
            }
        }

        // Sensors were confirmed delivering during priming: signal readiness,
        // then the tone (docs/07 §7.3).
        //
        // The tone and the metronome are **requested, never awaited** (ledger
        // entry 25). Both PRD ACs still hold — recording starts, and a distinct
        // start tone plays — but the data path does not depend on the audio
        // layer being healthy enough to return. Ordering is preserved where it
        // is observable: the request is issued after readiness, so a tone can
        // never precede a recording.
        continuation.yield(.ready)
        requestAudio { audio, config in
            // Activates the audio session and preloads the buffers. Inside the
            // audio task rather than before it, so an engine that is slow to
            // spin up delays its own first tone and nothing else — the walk is
            // already being recorded by the time this runs.
            await audio.prepare()
            await audio.playStartTone()
            // The other engine, equally opt-in (Task 7.2.2). The tempo travels
            // on the config, which `MetronomeCue` is the only way to build — so
            // it is necessarily this mode's own baseline cadence [PRD §5].
            if case .metronome(let cue) = config {
                await audio.startMetronome(bpm: cue.bpm)
            }
        }
        logService.log(.info, .session, "session started: mode=\(mode.rawValue)")

        return events
    }

    /// Primes and starts in one call, for a start with no countdown in front
    /// of it (docs/07 §7.3).
    ///
    /// Strictly composition — it holds no lifecycle of its own, so the two
    /// paths cannot drift. T-0 is stamped after priming completes, since
    /// nothing earlier would be honest about when the recording began.
    func begin(mode: TestMode, audioConfig: SessionAudioConfig) async throws -> AsyncStream<SessionRecordingEvent> {
        try await prime(mode: mode, audioConfig: audioConfig)
        return try await begin(at: TimeAnchor(clock: clock))
    }

    // MARK: - Abort

    /// Ends a countdown without a session (docs/07 §7.7, [PRD OQ-6]).
    ///
    /// The exit for a cancelled countdown — the user tapped Cancel, the app was
    /// backgrounded, a call arrived. Sensors come down, the unarmed buffer and
    /// its scratch file go with them, and the recorder is idle again. No
    /// session is created and nothing is marked invalid, because nothing was
    /// ever recorded.
    ///
    /// Non-throwing: cancellation paths are the last place that should have to
    /// handle an error. Aborting from idle is a no-op.
    ///
    /// **Not a way out of a recording.** `stop()` is the only exit from a
    /// running session and the only place the audio session is released, so an
    /// abort past T-0 is refused rather than obeyed — it would leave the audio
    /// route held and throw away a real walk.
    func abort() async {
        switch state {
        case .idle:
            return
        case .running:
            logService.log(.warning, .session, "abort refused: a running session must be stopped, not aborted")
            return
        case .priming, .primed:
            break
        }

        await tearDown()
        logService.log(.info, .session, "countdown aborted before T-0; no session created")
    }

    // MARK: - Silencing the cue

    /// Turns this session's audio cue off, mid-walk, for good.
    ///
    /// **One way.** A cue can be silenced but never started, because a walk
    /// that was unpaced and then paced would produce one set of metrics
    /// spanning two different conditions, compared against a baseline
    /// established under one [PRD §5, OQ-5]. Silencing only ever removes
    /// influence, and the alternative — a user with failing earphones
    /// abandoning the walk — costs them the whole session.
    ///
    /// The session keeps the config it started with; `audioSilencedAt` records
    /// where the sound stopped, so the stored row describes what actually
    /// happened rather than claiming one state for a walk that had two.
    ///
    /// Idempotent, and a no-op unless a cue is actually running.
    @discardableResult
    func silenceAudioCues() -> Bool {
        guard state == .running, audioConfig != .none, audioSilencedAt == nil, let anchor else {
            return false
        }

        audioSilencedAt = .seconds(clock.uptime - anchor.uptime)

        // Disarm before asking the engine to stop, so a footfall already in
        // flight cannot schedule a tick behind the silence.
        await_stepFeedbackStop()
        requestAudio { audio, config in
            if case .metronome = config { await audio.stopMetronome() }
        }

        logService.log(.info, .session, "audio cues silenced mid-session")
        return true
    }

    /// `StepFeedbackBridge.stop()` is synchronous on the bridge's own
    /// isolation; this keeps the call out of the guard above.
    private func await_stepFeedbackStop() {
        Task { [stepFeedback] in await stepFeedback.stop() }
    }

    // MARK: - Stop

    /// Stops recording and returns the frozen buffer (docs/07 §7.3).
    ///
    /// Order is fixed: stop tone, stop sensors, freeze, hand off. This is also
    /// the only way out of a recording — there is no separate cancel — so it is
    /// the one place the audio session can be released.
    func stop() async throws -> RawSessionBuffer {
        guard state == .running, let anchor, let startedAt, let mode else {
            throw StabilyzError.recording(.notRecording)
        }

        // Silence the feedback first, so neither a late footfall nor a queued
        // beat sounds over the end of the walk. Disarming is a bridge call: it
        // sets a flag and returns.
        await stepFeedback.stop()

        // From here the data path — sensor stop, drain, freeze, handoff — never
        // awaits audio (ledger entry 25). The stop tone is requested alongside
        // it and is best-effort, like every other sound: a wedged audio layer
        // costs the walk its tone, never its measurement [PRD §7 AC].
        requestAudio { audio, config in
            if case .metronome = config { await audio.stopMetronome() }
            await audio.playStopTone()
            // Whatever activated the `AVAudioSession` has to release it, or the
            // app keeps the audio route after the walk is over and the user's
            // music stays interrupted. `teardown` waits for the tone above to
            // finish rendering before it stops the engine (docs/10).
            await audio.teardown()
        }

        await stopStreams()

        // Elapsed comes from the monotonic clock, never Date arithmetic
        // (docs/07 §7.4).
        let elapsed = Duration.seconds(clock.uptime - anchor.uptime)
        // Freezing reads back memory and scratch together, then deletes the
        // scratch file — raw samples never outlive the session (docs/06 §6.4).
        let frozenSamples = sampleBuffer?.freeze() ?? []
        let series = SampleIngestion.align(
            frozenSamples,
            sampleRateHz: configuration.motionAcquisition.sampleRateHz,
            policy: configuration.gapDetection
        )

        let buffer = RawSessionBuffer(
            mode: mode,
            audioConfig: audioConfig,
            anchor: anchor,
            series: series,
            pedometerEvents: pedometerEvents,
            startedAt: startedAt,
            endedAt: clock.now,
            advertisedClockElapsed: elapsed,
            audioSilencedAt: audioSilencedAt,
            interruptionCount: interruptionCount,
            pedometerAvailable: pedometerAvailable
        )

        logService.log(
            .info,
            .session,
            "session stopped: mode=\(mode.rawValue) samples=\(series.samples.count) gaps=\(series.gaps.count)"
        )

        eventContinuation?.yield(.stopped)
        eventContinuation?.finish()
        resetSessionState()

        return buffer
    }

    // MARK: - Teardown

    /// Brings every stream down and drains the consumers.
    ///
    /// Drains rather than cancels. Stopping a service finishes its stream, so
    /// these complete; cancelling here would discard samples that had already
    /// been delivered but not yet consumed, quietly shortening the recording.
    /// Awaiting suspends the actor, so the consumers can run.
    ///
    /// Shared by `stop()` and `abort()` so a cancelled countdown releases
    /// exactly what a finished session releases — the difference between them
    /// is what happens to the samples, not what happens to the hardware.
    private func stopStreams() async {
        await motionSensor.stop()
        await pedometer.stop()
        await interruptionObserver.stopObserving()
        await screenSleep.allowSleep()
        interruptionTask?.cancel()
        interruptionTask = nil

        await sampleTask?.value
        await pedometerTask?.value
        sampleTask = nil
        pedometerTask = nil
    }

    /// `stopStreams` plus discarding the session — the failed-priming and
    /// cancelled-countdown path. `resetSessionState` discards the buffer, which
    /// deletes its scratch file (docs/06 §6.4), so nothing is left on disk.
    private func tearDown() async {
        await stopStreams()
        eventContinuation?.finish()
        resetSessionState()
    }

    /// Hands a piece of audio work off the critical path (ledger entry 25).
    ///
    /// Audio is fire-and-forget in both directions. Every method on
    /// `AudioFeedbackService` is non-throwing and returns promptly by contract,
    /// and the shipped engine only stops or schedules a preloaded buffer — but
    /// the recorder does not rely on that being true. A session is measured,
    /// frozen and scored whatever the audio layer is doing.
    private func requestAudio(
        _ work: @escaping @Sendable (AudioFeedbackService, SessionAudioConfig) async -> Void
    ) {
        let audio = audioFeedback
        let config = audioConfig
        Task { await work(audio, config) }
    }

    // MARK: - Permission

    /// Refuses to start when Motion & Fitness is denied or restricted.
    private func requirePermission() async throws {
        if let denial = await permissionDenial(of: motionSensor.authorizationStatus) {
            logService.log(.error, .session, "session start refused: motion permission denied")
            throw denial
        }
    }

    /// Maps an authorization state to the error that must stop a session, or
    /// nil when recording may proceed. `notDetermined` is not a refusal: the
    /// system prompt appears on first access.
    private func permissionDenial(of status: MotionAuthorizationStatus) -> StabilyzError? {
        switch status {
        case .denied: .permission(.motionDenied)
        case .restricted: .permission(.motionRestricted)
        case .authorized, .notDetermined: nil
        }
    }

    // MARK: - Interruptions

    /// Records an interruption and surfaces it to the UI (docs/07 §7.7).
    ///
    /// The count is only incremented for events that actually suspend sample
    /// delivery. An audio route change degrades feedback without touching the
    /// accelerometer, so counting it would overstate how disturbed the walk was
    /// and could push an otherwise sound session toward the noisy path.
    ///
    /// Nothing here alters the samples. The suspension shows up as a gap in the
    /// data, walking analysis excludes it, and the normal pipeline decides
    /// validity — a session is never quietly presented as clean [PRD §6].
    private func handle(_ interruption: SessionInterruption) {
        guard state == .running else { return }

        switch interruption {
        case .didEnterBackground:
            interruptionCount += 1
            suspendedAt = lastSampleTimestamp
            logService.log(.warning, .session, "session interrupted: app suspended")
            eventContinuation?.yield(.interrupted)

        case .didBecomeActive:
            if let suspendedAt {
                logService.log(.info, .session, "session resumed after suspension at \(Int(suspendedAt))s")
                self.suspendedAt = nil
            }

        case .willResignActive:
            // Losing focus does not by itself stop delivery; if it becomes a
            // suspension, didEnterBackground follows and counts it.
            logService.log(.info, .session, "session lost focus")

        case .audioInterrupted, .audioRouteChanged:
            // Feedback-only degradation; recording is unaffected (docs/10 §10.4).
            logService.log(.warning, .audio, "audio degraded during session")
        }
    }

    // MARK: - Ingestion

    private func ingest(_ sample: SensorSample) {
        guard state == .running else { return }

        // The T-0 gate ([PRD OQ-6], docs/07 §7.3), and the reason buffering
        // moved ahead of everything else here: the buffer is the one place the
        // admission rule is applied, so asking it whether the sample was
        // admitted is what keeps a second copy of the rule from existing.
        //
        // A sample from before Go is outside the session entirely, so a
        // rejection returns before anything observes it — it must not move the
        // gap detector's cursor, fire a footfall, or advance the elapsed clock.
        // The countdown is not a segment to be filtered later; it is not part
        // of the recording at all.
        guard sampleBuffer?.append(sample) == true else { return }

        // A live gap notice for the UI, measured against the requested rate
        // because no median exists yet mid-stream. The authoritative list is
        // recomputed from the observed median at freeze time, so a missed or
        // spurious live notice cannot change the outcome.
        if let previous = lastSampleTimestamp {
            let spacing = sample.deviceTimestamp - previous
            let nominalInterval = 1 / configuration.motionAcquisition.sampleRateHz
            if spacing > configuration.gapDetection.gapThreshold(medianInterval: nominalInterval) {
                eventContinuation?.yield(.gapDetected(SensorGap(start: previous, end: sample.deviceTimestamp)))
                logService.log(.warning, .motion, "sensor gap observed")
            }
        }
        lastSampleTimestamp = sample.deviceTimestamp

        // Detection is deliberately after buffering: the recording is what
        // matters, and feedback must never delay or alter it (docs/10 §10.4).
        // The buffering policy drops the oldest pending tick rather than
        // blocking the sample path if the audio layer stalls.
        if let event = stepDetector?.process(sample) {
            stepContinuation.yield(event)
        }

        if let anchor {
            let elapsed = sample.deviceTimestamp - anchor.uptime
            let whole = Int(elapsed)
            if whole > lastReportedSecond {
                lastReportedSecond = whole
                eventContinuation?.yield(.elapsed(.seconds(whole)))
            }
        }
    }

    private func ingest(_ event: PedometerEvent) {
        // Running only, unlike samples. Pedometer events have no admission gate
        // of their own, so the state is what keeps the countdown's steps — the
        // walk to the door, the phone going into a pocket — out of the session.
        guard state == .running else { return }
        pedometerEvents.append(event)
    }

    // MARK: - Internals

    private func resetSessionState() {
        state = .idle
        sampleBuffer?.discard()
        sampleBuffer = nil
        stepDetector = nil
        pedometerEvents.removeAll()
        anchor = nil
        startedAt = nil
        mode = nil
        audioConfig = .none
        interruptionCount = 0
        audioSilencedAt = nil
        pedometerAvailable = true
        suspendedAt = nil
        primedSampleStream = nil
        primedPedometerStream = nil
        lastSampleTimestamp = nil
        lastReportedSecond = -1
        eventContinuation = nil
    }
}
