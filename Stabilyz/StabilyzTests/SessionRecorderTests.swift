import Foundation
import Testing
@testable import Stabilyz

// MARK: - Doubles

/// Advances on demand, so elapsed time is deterministic.
private final class SteppableClock: Clock, @unchecked Sendable {
    private let state = Locked<(now: Date, uptime: TimeInterval)>((Date(timeIntervalSince1970: 1_700_000_000), 1_000))

    var now: Date { state.withLock { $0.now } }
    var uptime: TimeInterval { state.withLock { $0.uptime } }

    func advance(by seconds: TimeInterval) {
        state.withLock {
            $0.now = $0.now.addingTimeInterval(seconds)
            $0.uptime += seconds
        }
    }
}

private final class RecorderLog: LogService, @unchecked Sendable {
    let entries = Locked<[String]>([])

    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        entries.withLock { $0.append(message) }
    }
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

/// Records the order tones were played in, which is a PRD-specified sequence.
private actor ToneSpy: AudioFeedbackService {
    private(set) var calls: [String] = []
    nonisolated var events: AsyncStream<AudioFeedbackEvent> { AsyncStream { $0.finish() } }

    func playStartTone() async { calls.append("start") }
    func playStopTone() async { calls.append("stop") }
    func playStepTick() async { calls.append("tick") }
    func startMetronome(bpm: Double) async { calls.append("metronome") }
    func stopMetronome() async { calls.append("metronomeOff") }
    func suspend() async {}
    func resume() async {}
}

/// A motion service that refuses to prime, for the fail-fast path.
private struct FailingMotionService: MotionSensorService {
    let error: StabilyzError
    var authorization: MotionAuthorizationStatus = .authorized
    var isAvailable: Bool { get async { true } }
    var authorizationStatus: MotionAuthorizationStatus { get async { authorization } }
    func requestAuthorization() async -> MotionAuthorizationStatus { .authorized }
    func start(policy: MotionAcquisitionPolicy) async throws -> AsyncStream<SensorSample> { throw error }
    func stop() async {}
}

/// A pedometer that is unavailable, to prove it does not fail a session.
private struct FailingPedometerService: PedometerService {
    /// Absent hardware, permission untouched.
    var authorization: MotionAuthorizationStatus = .authorized
    var isAvailable: Bool { get async { false } }
    var authorizationStatus: MotionAuthorizationStatus { get async { authorization } }
    func start() async throws -> AsyncStream<PedometerEvent> { throw StabilyzError.sensor(.unavailable) }
    func stop() async {}
    func events(from start: Date, to end: Date) async throws -> PedometerEvent? { nil }
}

/// Lets a test inject interruptions on demand.
private actor ManualInterruptionObserver: SessionInterruptionObserver {
    private var continuation: AsyncStream<SessionInterruption>.Continuation?
    private(set) var isObserving = false

    func startObserving() async -> AsyncStream<SessionInterruption> {
        let (stream, continuation) = AsyncStream<SessionInterruption>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        isObserving = true
        return stream
    }

    func stopObserving() async {
        isObserving = false
        continuation?.finish()
        continuation = nil
    }

    func send(_ interruption: SessionInterruption) {
        continuation?.yield(interruption)
    }
}

private actor ScreenSleepSpy: ScreenSleepController {
    private(set) var calls: [String] = []

    func preventSleep() async { calls.append("prevent") }
    func allowSleep() async { calls.append("allow") }
}

private func makeRecorder(
    fixture: GaitFixture = .steadyWalk,
    clock: SteppableClock = SteppableClock(),
    motion: (any MotionSensorService)? = nil,
    pedometer: (any PedometerService)? = nil,
    audio: ToneSpy = ToneSpy(),
    log: RecorderLog = RecorderLog(),
    interruptions: ManualInterruptionObserver = ManualInterruptionObserver(),
    screenSleep: ScreenSleepSpy = ScreenSleepSpy()
) -> (SessionRecorder, SteppableClock, ToneSpy, RecorderLog) {
    let recorder = SessionRecorder(
        motionSensor: motion ?? FixtureSensorService(fixture: fixture, clock: clock),
        pedometer: pedometer ?? FixturePedometerService(fixture: fixture, clock: clock),
        audioFeedback: audio,
        interruptionObserver: interruptions,
        screenSleep: screenSleep,
        clock: clock,
        logService: log,
        fileIO: FileManagerFileIO()
    )
    return (recorder, clock, audio, log)
}

/// Drains the event stream so assertions see everything emitted.
private func collect(_ events: AsyncStream<SessionRecordingEvent>) async -> [SessionRecordingEvent] {
    var collected: [SessionRecordingEvent] = []
    for await event in events { collected.append(event) }
    return collected
}

// MARK: - Start

@Test func beginSignalsReadinessBeforePlayingTheStartTone() async throws {
    // docs/07 §7.3: sensors confirmed delivering, then readiness, then tone.
    let (recorder, _, audio, _) = makeRecorder()

    let events = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    let collector = Task { await collect(events) }
    _ = try await recorder.stop()

    let collected = await collector.value
    #expect(collected.first == .ready)
    #expect(await audio.calls.first == "start")
}

@Test func beginStampsOneAnchorEverySampleResolvesAgainst() async throws {
    let (recorder, clock, _, _) = makeRecorder()

    _ = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    let buffer = try await recorder.stop()

    #expect(buffer.anchor.wallClock == clock.now)
    #expect(buffer.samples.allSatisfy { $0.anchor == buffer.anchor })
}

@Test func primingFailureFailsFastAndLeavesNoSession() async {
    // docs/07 §7.3: no silent failure; the session must not half-start.
    let (recorder, _, audio, _) = makeRecorder(motion: FailingMotionService(error: .sensor(.primingTimeout)))

    await #expect(throws: StabilyzError.sensor(.primingTimeout)) {
        _ = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    }

    #expect(await recorder.isRecording == false)
    // No start tone for a session that never started.
    #expect(await audio.calls.isEmpty)
    // And the recorder is reusable, not wedged.
    await #expect(throws: StabilyzError.recording(.notRecording)) {
        _ = try await recorder.stop()
    }
}

@Test func aMissingPedometerDoesNotFailTheSession() async throws {
    // The pedometer is context data (docs/05 §5.1). Losing it degrades
    // segmentation hints; it must not stop a measurable session.
    let (recorder, _, _, log) = makeRecorder(pedometer: FailingPedometerService())

    _ = try await recorder.begin(mode: .fullTest, audioConfig: .none)
    let buffer = try await recorder.stop()

    #expect(buffer.samples.isEmpty == false)
    #expect(buffer.pedometerEvents.isEmpty)
    #expect(log.entries.withLock { $0.contains { $0.contains("pedometer unavailable") } })
    // Recorded so later analysis knows the cross-check was missing, rather than
    // having to infer it from an empty event list.
    #expect(buffer.pedometerAvailable == false)
}

@Test func anAvailablePedometerIsRecordedAsAvailable() async throws {
    let (recorder, _, _, _) = makeRecorder()

    _ = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    let buffer = try await recorder.stop()

    #expect(buffer.pedometerAvailable)
    #expect(buffer.pedometerEvents.isEmpty == false)
}

// MARK: - Permission is not degradable

@Test func aDeniedMotionPermissionRefusesToStart() async {
    // [PRD] a denied Motion & Fitness permission means recording cannot
    // proceed at all — this is the error the Start-button pre-flight surfaces.
    let motion = FailingMotionService(error: .sensor(.unavailable), authorization: .denied)
    let (recorder, _, audio, _) = makeRecorder(motion: motion)

    await #expect(throws: StabilyzError.permission(.motionDenied)) {
        _ = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    }

    #expect(await recorder.isRecording == false)
    #expect(await audio.calls.isEmpty)
}

@Test func aRestrictedMotionPermissionRefusesToStart() async {
    let motion = FailingMotionService(error: .sensor(.unavailable), authorization: .restricted)
    let (recorder, _, _, _) = makeRecorder(motion: motion)

    await #expect(throws: StabilyzError.permission(.motionRestricted)) {
        _ = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    }
}

@Test func notDeterminedIsNotARefusal() async throws {
    // The system prompt appears on first access; refusing here would deny the
    // user the chance to grant.
    let clock = SteppableClock()
    let recorder = SessionRecorder(
        motionSensor: UndeterminedMotionService(fixture: .steadyWalk, clock: clock),
        pedometer: FixturePedometerService(fixture: .steadyWalk, clock: clock),
        audioFeedback: ToneSpy(),
        interruptionObserver: ManualInterruptionObserver(),
        screenSleep: ScreenSleepSpy(),
        clock: clock,
        logService: RecorderLog(),
        fileIO: FileManagerFileIO()
    )

    _ = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    let buffer = try await recorder.stop()
    #expect(buffer.samples.isEmpty == false)
}

@Test func aDeniedPedometerPermissionStopsTheSessionRatherThanDegrading() async {
    // Distinct from absent hardware: a denial must not quietly become a
    // session recorded without its cross-check.
    let clock = SteppableClock()
    let recorder = SessionRecorder(
        motionSensor: FixtureSensorService(fixture: .steadyWalk, clock: clock),
        pedometer: FailingPedometerService(authorization: .denied),
        audioFeedback: ToneSpy(),
        interruptionObserver: ManualInterruptionObserver(),
        screenSleep: ScreenSleepSpy(),
        clock: clock,
        logService: RecorderLog(),
        fileIO: FileManagerFileIO()
    )

    await #expect(throws: StabilyzError.permission(.motionDenied)) {
        _ = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    }
    #expect(await recorder.isRecording == false)
}

/// Reports notDetermined authorization but streams normally.
private struct UndeterminedMotionService: MotionSensorService {
    let fixture: GaitFixture
    let clock: Clock
    var isAvailable: Bool { get async { true } }
    var authorizationStatus: MotionAuthorizationStatus { get async { .notDetermined } }
    func requestAuthorization() async -> MotionAuthorizationStatus { .authorized }
    func start(policy: MotionAcquisitionPolicy) async throws -> AsyncStream<SensorSample> {
        let samples = fixture.sensorSamples(anchoredAt: TimeAnchor(clock: clock))
        return AsyncStream { continuation in
            for sample in samples { continuation.yield(sample) }
            continuation.finish()
        }
    }
    func stop() async {}
}

@Test func beginningTwiceIsRefused() async throws {
    let (recorder, _, _, _) = makeRecorder()
    _ = try await recorder.begin(mode: .quickTest, audioConfig: .none)

    await #expect(throws: StabilyzError.recording(.alreadyRecording)) {
        _ = try await recorder.begin(mode: .fullTest, audioConfig: .none)
    }

    _ = try await recorder.stop()
}

// MARK: - Stop

@Test func stopPlaysTheStopToneBeforeFreezing() async throws {
    // docs/07 §7.3 order: stop tone, stop sensors, freeze, hand off.
    let (recorder, _, audio, _) = makeRecorder()
    _ = try await recorder.begin(mode: .quickTest, audioConfig: .none)

    _ = try await recorder.stop()

    #expect(await audio.calls == ["start", "stop"])
}

@Test func stopWithoutBeginIsRefused() async {
    let (recorder, _, _, _) = makeRecorder()

    await #expect(throws: StabilyzError.recording(.notRecording)) {
        _ = try await recorder.stop()
    }
}

@Test func stopKeepsEverySampleTheSensorDelivered() async throws {
    // Cancelling the consumer instead of draining would quietly shorten the
    // recording, which is the irreplaceable data (docs/14 §14.3).
    let fixture = GaitFixture.makeWalk(name: "drain", cadenceBPM: 108, seconds: 3)
    let (recorder, _, _, _) = makeRecorder(fixture: fixture)

    _ = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    let buffer = try await recorder.stop()

    #expect(buffer.samples.count == fixture.samples.count)
}

@Test func stopFreezesTheBufferWithSessionContext() async throws {
    let (recorder, _, _, _) = makeRecorder()

    _ = try await recorder.begin(mode: .fullTest, audioConfig: .metronome(cue: .fixture(bpm: 104)))
    let buffer = try await recorder.stop()

    // audioConfig is persisted with the session for transparency [REC].
    #expect(buffer.mode == .fullTest)
    #expect(buffer.audioConfig == .metronome(cue: .fixture(bpm: 104)))
    #expect(buffer.isEmpty == false)
}

@Test func elapsedComesFromTheMonotonicClockNotDateArithmetic() async throws {
    // docs/07 §7.4: all durations from device timestamps.
    let (recorder, clock, _, _) = makeRecorder()
    _ = try await recorder.begin(mode: .quickTest, audioConfig: .none)

    clock.advance(by: 125)
    let buffer = try await recorder.stop()

    #expect(buffer.advertisedClockElapsed == .seconds(125))
}

// MARK: - Gaps

@Test func aScriptedGapReachesBothTheLiveStreamAndTheFrozenBuffer() async throws {
    let (recorder, _, _, _) = makeRecorder(fixture: .walkWithSensorGap)

    let events = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    let collector = Task { await collect(events) }
    let buffer = try await recorder.stop()
    let collected = await collector.value

    // Live notice for the UI...
    #expect(collected.contains { if case .gapDetected = $0 { return true } else { return false } })
    // ...and the authoritative record in the frozen buffer (docs/07 §7.8).
    #expect(buffer.gapInfo.gapCount == 1)
    #expect(buffer.gapInfo.longestGapDuration > .seconds(1.9))
}

@Test func elapsedIsReportedOncePerWholeSecond() async throws {
    let fixture = GaitFixture.makeWalk(name: "elapsed", cadenceBPM: 108, seconds: 3)
    let (recorder, _, _, _) = makeRecorder(fixture: fixture)

    let events = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    let collector = Task { await collect(events) }
    _ = try await recorder.stop()
    let collected = await collector.value

    let elapsedValues = collected.compactMap { event -> Duration? in
        if case .elapsed(let duration) = event { return duration } else { return nil }
    }
    // Monotonic, one per second, no duplicates.
    #expect(elapsedValues == elapsedValues.sorted())
    #expect(Set(elapsedValues).count == elapsedValues.count)
    #expect(elapsedValues.contains(.seconds(2)))
}

@Test func theEventStreamFinishesAfterStopping() async throws {
    let (recorder, _, _, _) = makeRecorder()

    let events = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    let collector = Task { await collect(events) }
    _ = try await recorder.stop()

    // A stream that never finishes would leak the Recording screen's observer.
    let collected = await collector.value
    #expect(collected.last == .stopped)
}

// MARK: - Reuse

@Test func theRecorderIsReusedAcrossSessionsWithoutBleedingState() async throws {
    // docs/12 §12.3: created once and restarted per session, never recreated.
    let (recorder, _, _, _) = makeRecorder(fixture: .walkWithSensorGap)

    _ = try await recorder.begin(mode: .quickTest, audioConfig: .stepFeedback)
    let first = try await recorder.stop()

    _ = try await recorder.begin(mode: .fullTest, audioConfig: .none)
    let second = try await recorder.stop()

    #expect(first.mode == .quickTest)
    #expect(second.mode == .fullTest)
    #expect(second.audioConfig == .none)
    // The second session carries its own samples, not the first session's too.
    #expect(second.samples.count == first.samples.count)
}

// MARK: - Interruptions (Task 4.2.3)

@Test func backgroundingIsCountedAndSurfacedToTheUI() async throws {
    let interruptions = ManualInterruptionObserver()
    let (recorder, _, _, _) = makeRecorder(interruptions: interruptions)

    let events = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    let collector = Task { await collect(events) }
    await interruptions.send(.didEnterBackground)
    await interruptions.send(.didBecomeActive)
    let buffer = try await recorder.stop()
    let collected = await collector.value

    #expect(buffer.interruptionCount == 1)
    #expect(collected.contains(.interrupted))
}

@Test func feedbackOnlyEventsDoNotCountAsInterruptions() async throws {
    // Counting a route change would overstate how disturbed the walk was and
    // could push a sound session toward the noisy path (docs/10 §10.4).
    let interruptions = ManualInterruptionObserver()
    let (recorder, _, _, _) = makeRecorder(interruptions: interruptions)

    _ = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    await interruptions.send(.audioRouteChanged)
    await interruptions.send(.audioInterrupted)
    await interruptions.send(.willResignActive)
    let buffer = try await recorder.stop()

    #expect(buffer.interruptionCount == 0)
}

@Test func repeatedSuspensionsAreCountedIndividually() async throws {
    let interruptions = ManualInterruptionObserver()
    let (recorder, _, _, _) = makeRecorder(interruptions: interruptions)

    _ = try await recorder.begin(mode: .fullTest, audioConfig: .none)
    for _ in 0..<3 {
        await interruptions.send(.didEnterBackground)
        await interruptions.send(.didBecomeActive)
    }
    let buffer = try await recorder.stop()

    #expect(buffer.interruptionCount == 3)
}

@Test func anInterruptionNeverAltersTheRecordedSamples() async throws {
    // [PRD §6] the suspension shows up as a gap; nothing is patched over, and
    // the normal pipeline decides validity.
    let interruptions = ManualInterruptionObserver()
    let fixture = GaitFixture.makeWalk(name: "interrupted", cadenceBPM: 108, seconds: 2)
    let (recorder, _, _, _) = makeRecorder(fixture: fixture, interruptions: interruptions)

    _ = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    await interruptions.send(.didEnterBackground)
    let buffer = try await recorder.stop()

    #expect(buffer.samples.count == fixture.samples.count)
    #expect(buffer.interruptionCount == 1)
}

@Test func interruptionsAfterStopAreIgnored() async throws {
    let interruptions = ManualInterruptionObserver()
    let (recorder, _, _, _) = makeRecorder(interruptions: interruptions)

    _ = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    let buffer = try await recorder.stop()
    await interruptions.send(.didEnterBackground)

    #expect(buffer.interruptionCount == 0)
    #expect(await recorder.isRecording == false)
}

@Test func interruptionCountDoesNotCarryIntoTheNextSession() async throws {
    let interruptions = ManualInterruptionObserver()
    let (recorder, _, _, _) = makeRecorder(interruptions: interruptions)

    _ = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    await interruptions.send(.didEnterBackground)
    let first = try await recorder.stop()

    _ = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    let second = try await recorder.stop()

    #expect(first.interruptionCount == 1)
    #expect(second.interruptionCount == 0)
}

// MARK: - Screen sleep

@Test func theScreenIsKeptAwakeForTheDurationOfASession() async throws {
    // [REC — docs/07 §7.7] and released afterwards, so the setting does not
    // leak into the rest of the app.
    let screenSleep = ScreenSleepSpy()
    let (recorder, _, _, _) = makeRecorder(screenSleep: screenSleep)

    _ = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    #expect(await screenSleep.calls == ["prevent"])

    _ = try await recorder.stop()
    #expect(await screenSleep.calls == ["prevent", "allow"])
}

@Test func observationStopsWithTheSession() async throws {
    let interruptions = ManualInterruptionObserver()
    let (recorder, _, _, _) = makeRecorder(interruptions: interruptions)

    _ = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    #expect(await interruptions.isObserving)

    _ = try await recorder.stop()
    #expect(await interruptions.isObserving == false)
}
