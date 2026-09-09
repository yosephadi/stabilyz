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

    private var eventContinuation: AsyncStream<SessionRecordingEvent>.Continuation?
    private var sampleTask: Task<Void, Never>?
    private var pedometerTask: Task<Void, Never>?
    private var lastSampleTimestamp: TimeInterval?
    private var lastReportedSecond = -1

    init(
        motionSensor: MotionSensorService,
        pedometer: PedometerService,
        audioFeedback: AudioFeedbackService,
        clock: Clock,
        logService: LogService,
        acquisitionPolicy: MotionAcquisitionPolicy = .recommendedDefault,
        gapPolicy: GapDetectionPolicy = .recommendedDefault
    ) {
        self.motionSensor = motionSensor
        self.pedometer = pedometer
        self.audioFeedback = audioFeedback
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
        // measurement. Losing it degrades segmentation hints; it must not fail
        // a session that the accelerometer can still measure.
        var pedometerStream: AsyncStream<PedometerEvent>?
        do {
            pedometerStream = try await pedometer.start()
        } catch {
            logService.log(.warning, .session, "pedometer unavailable; continuing without step context")
        }

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
            interruptionCount: interruptionCount
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
        lastSampleTimestamp = nil
        lastReportedSecond = -1
        eventContinuation = nil
    }
}
