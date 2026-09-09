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
    private let acquisitionPolicy: MotionAcquisitionPolicy
    private let gapPolicy: GapDetectionPolicy

    private var state: State = .idle
    private var samples: [SensorSample] = []
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
        acquisitionPolicy: MotionAcquisitionPolicy = .recommendedDefault,
        gapPolicy: GapDetectionPolicy = .recommendedDefault
    ) {
        self.motionSensor = motionSensor
        self.pedometer = pedometer
        self.audioFeedback = audioFeedback
        self.interruptionObserver = interruptionObserver
        self.screenSleep = screenSleep
        self.clock = clock
        self.logService = logService
        self.acquisitionPolicy = acquisitionPolicy
        self.gapPolicy = gapPolicy
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

        // The anchor is stamped before any sample can arrive, so every sample
        // resolves against it (docs/07 §7.4).
        let anchor = TimeAnchor(clock: clock)
        self.anchor = anchor
        startedAt = anchor.wallClock

        let sampleStream: AsyncStream<SensorSample>
        do {
            sampleStream = try await motionSensor.start(policy: acquisitionPolicy)
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
        continuation.yield(.ready)
        await audioFeedback.playStartTone()
        logService.log(.info, .session, "session started: mode=\(mode.rawValue)")

        return events
    }

    // MARK: - Stop

    /// Stops recording and returns the frozen buffer (docs/07 §7.3).
    ///
    /// Order is fixed: stop tone, stop sensors, freeze, hand off.
    func stop() async throws -> RawSessionBuffer {
        guard state == .recording, let anchor, let startedAt, let mode else {
            throw StabilyzError.recording(.notRecording)
        }

        await audioFeedback.playStopTone()
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
        let series = SampleIngestion.align(
            samples,
            sampleRateHz: acquisitionPolicy.sampleRateHz,
            policy: gapPolicy
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

        // A live gap notice for the UI. The authoritative list is recomputed at
        // freeze time, so a missed notice cannot change the outcome.
        if let previous = lastSampleTimestamp {
            let spacing = sample.deviceTimestamp - previous
            if spacing > gapPolicy.gapThreshold(sampleRateHz: acquisitionPolicy.sampleRateHz) {
                eventContinuation?.yield(.gapDetected(SensorGap(start: previous, end: sample.deviceTimestamp)))
                logService.log(.warning, .motion, "sensor gap observed")
            }
        }
        lastSampleTimestamp = sample.deviceTimestamp

        samples.append(sample)

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
        samples.removeAll()
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
