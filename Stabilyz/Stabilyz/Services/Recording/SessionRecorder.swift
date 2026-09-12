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
    private enum State: Equatable {
        case idle
        case recording
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
    /// Recorded on the session so later analysis knows the pedometer
    /// cross-check was not available for it.
    private var pedometerAvailable = true

    private var eventContinuation: AsyncStream<SessionRecordingEvent>.Continuation?
    private var sampleTask: Task<Void, Never>?
    private var pedometerTask: Task<Void, Never>?
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

    var isRecording: Bool { state == .recording }

    // MARK: - Begin

    /// Starts a recording and returns the UI event stream (docs/07 §7.3).
    ///
    /// Order is fixed: start sensors, confirm samples are arriving, signal
    /// readiness, then play the start tone [PRD AC]. Priming failure throws
    /// rather than recording silence — the motion service enforces the latency
    /// budget and reports `sensor(.primingTimeout)`.
    func begin(mode: TestMode, audioConfig: SessionAudioConfig) async throws -> AsyncStream<SessionRecordingEvent> {
        guard state == .idle else {
            throw StabilyzError.recording(.alreadyRecording)
        }

        // Pre-flight the permission before touching hardware. A denied
        // Motion & Fitness permission stops a session outright — it is not a
        // degradable condition (docs/07 §7.6, docs/15 §15.1). This is the error
        // the Start-button pre-flight surfaces.
        try await requirePermission()

        resetSessionState()
        self.mode = mode
        self.audioConfig = audioConfig
        sampleBuffer = SessionSampleBuffer(fileIO: fileIO, logService: logService)
        if audioConfig == .stepFeedback {
            stepDetector = LiveStepDetector(policy: configuration.liveStepFeedback)
        }

        // The anchor is stamped before any sample can arrive, so every sample
        // resolves against it (docs/07 §7.4). It is also T-0: arming the buffer
        // with it opens the session at this instant and closes it to anything
        // earlier ([PRD OQ-6], docs/07 §7.3). Today the sensors start below, so
        // nothing earlier exists to turn away; the gate is what keeps that true
        // once priming moves into the countdown window (Task 4.2.2).
        let anchor = TimeAnchor(clock: clock)
        self.anchor = anchor
        sampleBuffer?.arm(at: anchor)
        startedAt = anchor.wallClock

        let sampleStream: AsyncStream<SensorSample>
        do {
            sampleStream = try await motionSensor.start(policy: configuration.motionAcquisition)
        } catch {
            // Nothing was recorded, so leave no half-started session behind.
            resetSessionState()
            logService.log(.error, .session, "session start failed during priming")
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
                await motionSensor.stop()
                resetSessionState()
                logService.log(.error, .session, "session start refused: motion permission denied")
                throw denial
            }
            logService.log(.warning, .session, "pedometer unavailable; continuing without step context")
        }
        pedometerAvailable = pedometerStream != nil

        let (events, continuation) = AsyncStream<SessionRecordingEvent>.makeStream(bufferingPolicy: .unbounded)
        eventContinuation = continuation
        state = .recording

        // Arm the sound before the first sample can be ingested. Inert unless
        // this session opted in [PRD AC — Step Feedback is off by default].
        // This is the bridge, not the audio layer: it subscribes to a stream
        // and returns; it never awaits a tone.
        await stepFeedback.start(audioConfig: audioConfig, events: stepEvents)

        sampleTask = Task { [weak self] in
            for await sample in sampleStream {
                await self?.ingest(sample)
            }
        }

        if let pedometerStream {
            pedometerTask = Task { [weak self] in
                for await event in pedometerStream {
                    await self?.ingest(event)
                }
            }
        }

        // Any suspension stops sample delivery, so observation has to be live
        // before the session is declared ready (docs/07 §7.7).
        let interruptions = await interruptionObserver.startObserving()
        interruptionTask = Task { [weak self] in
            for await interruption in interruptions {
                await self?.handle(interruption)
            }
        }
        // [REC] keep the screen awake for the duration; no background motion
        // mode is added in v1.
        await screenSleep.preventSleep()

        // Sensors are confirmed delivering by this point: signal readiness,
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

    // MARK: - Stop

    /// Stops recording and returns the frozen buffer (docs/07 §7.3).
    ///
    /// Order is fixed: stop tone, stop sensors, freeze, hand off. This is also
    /// the only way out of a recording — there is no separate cancel — so it is
    /// the one place the audio session can be released.
    func stop() async throws -> RawSessionBuffer {
        guard state == .recording, let anchor, let startedAt, let mode else {
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

        await motionSensor.stop()
        await pedometer.stop()
        await interruptionObserver.stopObserving()
        await screenSleep.allowSleep()
        interruptionTask?.cancel()
        interruptionTask = nil

        // Drain rather than cancel. Stopping a service finishes its stream, so
        // these complete; cancelling here would discard samples that had
        // already been delivered but not yet consumed, quietly shortening the
        // recording. Awaiting suspends the actor, so the consumers can run.
        await sampleTask?.value
        await pedometerTask?.value
        sampleTask = nil
        pedometerTask = nil

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
        guard state == .recording else { return }

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
        guard state == .recording else { return }

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
        guard state == .recording else { return }
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
        pedometerAvailable = true
        suspendedAt = nil
        lastSampleTimestamp = nil
        lastReportedSecond = -1
        eventContinuation = nil
    }
}
