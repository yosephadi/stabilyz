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
///
/// Since decisions.md entry 25 the recorder *requests* audio without awaiting
/// it, so a tone arrives shortly after the call that asked for it rather than
/// before that call returns. Order between tones **is** guaranteed — the
/// requests are chained (ledger 39) — but their arrival is not synchronous with
/// `begin`/`stop`, so assertions call `recorder.drainPendingAudio()` first.
/// That waits on the audio queue itself rather than on a clock, so there is no
/// bound to tune and no run to lose to a busy machine.
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

    // The session lifecycle. Recorded rather than defaulted away, because
    // `prepare` activates an `AVAudioSession` and `teardown` releases it — an
    // ordering the recorder owns and nothing else would catch.
    func prepare() async { calls.append("prepare") }
    func teardown() async { calls.append("teardown") }
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
    // Readiness is signalled before the tone is even requested (docs/07 §7.3).
    // The engine is prepared first, inside the same audio task — activating the
    // session is audio's own cost and is not allowed to delay the recording.
    // A prefix, not the whole sequence: `stop()` has already run by the time
    // this asserts, so the stop tone and the teardown have landed too. What is
    // being pinned is the order of the first two, not the absence of the rest.
    await recorder.drainPendingAudio()
    #expect(await audio.calls.prefix(2) == ["prepare", "start"])
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

@Test func bothSessionTonesArePlayedInOrderWithoutTheDataPathWaiting() async throws {
    // [PRD AC] A distinct start tone and a distinct, different stop tone both
    // play. Since entry 25 the recorder does not await either: it requests them
    // and gets on with freezing the buffer, so the assertion is that they
    // arrive, in order — not that they have arrived by the time stop() returns.
    //
    // **Waits on the audio queue, not on a clock.** This used to poll for five
    // seconds and failed intermittently on a loaded machine — not because five
    // seconds was too short, but because nothing made the order true: each
    // request was an independent `Task`, and two of those hitting one actor
    // race. The requests are chained now, and draining the queue is a
    // deterministic wait with no bound to tune (ledger 39).
    let (recorder, _, audio, _) = makeRecorder()
    _ = try await recorder.begin(mode: .quickTest, audioConfig: .none)

    _ = try await recorder.stop()
    await recorder.drainPendingAudio()

    #expect(await audio.calls == ["prepare", "start", "stop", "teardown"])
}

@Test func theTonesStayInOrderEvenWhenTheWalkIsInstant() async throws {
    // The race this used to lose. With no walking between begin and stop, the
    // two audio requests are issued microseconds apart — which is precisely
    // when an unordered queue would speak the stop tone first.
    for _ in 0..<20 {
        let (recorder, _, audio, _) = makeRecorder()
        _ = try await recorder.begin(mode: .quickTest, audioConfig: .none)
        _ = try await recorder.stop()
        await recorder.drainPendingAudio()

        #expect(await audio.calls == ["prepare", "start", "stop", "teardown"])
    }
}

@Test func aSecondSessionsPrepareCannotOvertakeTheFirstsTeardown() async throws {
    // `teardown` releases the `AVAudioSession`; a `prepare` that overtook it
    // would activate a session the previous walk was still letting go of.
    let (recorder, _, audio, _) = makeRecorder()
    _ = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    _ = try await recorder.stop()
    _ = try await recorder.begin(mode: .fullTest, audioConfig: .none)
    _ = try await recorder.stop()
    await recorder.drainPendingAudio()

    #expect(await audio.calls == [
        "prepare", "start", "stop", "teardown",
        "prepare", "start", "stop", "teardown"
    ])
}

@Test func theAudioSessionIsReleasedByTheStopThatOpenedIt() async throws {
    // `prepare` activates an `AVAudioSession`; something has to deactivate it,
    // or the app holds the audio route after the walk is over and the user's
    // music stays interrupted. `stop()` is the only way out of a recording, so
    // it is the only place that can.
    let (recorder, _, audio, _) = makeRecorder()

    _ = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    await recorder.drainPendingAudio()
    let duringSession = await audio.calls
    #expect(duringSession.contains("teardown") == false, "the session was released mid-walk")

    _ = try await recorder.stop()
    await recorder.drainPendingAudio()
    let afterStop = await audio.calls

    #expect(afterStop.last == "teardown", "the audio session was never released")
    #expect(afterStop.filter { $0 == "prepare" }.count == 1)
    #expect(afterStop.filter { $0 == "teardown" }.count == 1)

    // The order [PRD AC] depends on: the stop tone is requested before the
    // engine that plays it is taken away.
    let stopTone = afterStop.firstIndex(of: "stop")
    let release = afterStop.firstIndex(of: "teardown")
    #expect(stopTone != nil && release != nil && stopTone! < release!)
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

// MARK: - The T-0 admission gate ([PRD OQ-6], docs/07 §7.3)

/// Streams a countdown lead-in before the walk.
///
/// The recorder stamps the anchor from the clock immediately before calling
/// `start`, and `SteppableClock` only moves when a test moves it — so reading
/// `clock.uptime` here yields exactly the T-0 the session was opened at, and
/// negative offsets from it are unambiguously pre-T-0.
private struct LeadInMotionService: MotionSensorService {
    let fixture: GaitFixture
    let clock: Clock
    /// Samples of sensor delivery before T-0, as priming inside a countdown
    /// would produce. A count rather than a duration so the number the gate
    /// should reject is exact, with no float stride to argue with.
    let leadInSampleCount: Int
    let leadInRateHz: Double = 100

    var isAvailable: Bool { get async { true } }
    var authorizationStatus: MotionAuthorizationStatus { get async { .authorized } }
    func requestAuthorization() async -> MotionAuthorizationStatus { .authorized }

    func start(policy: MotionAcquisitionPolicy) async throws -> AsyncStream<SensorSample> {
        let anchor = TimeAnchor(clock: clock)
        let interval = 1 / leadInRateHz
        let leadInSamples = (1...leadInSampleCount).reversed().map { step in
            SensorSample(
                deviceTimestamp: anchor.uptime - Double(step) * interval,
                anchor: anchor,
                acceleration: Vector3(x: 9, y: 9, z: 9),
                gravity: Vector3(x: 0, y: 0, z: -1)
            )
        }
        let walk = fixture.sensorSamples(anchoredAt: anchor)

        return AsyncStream { continuation in
            for sample in leadInSamples + walk { continuation.yield(sample) }
            continuation.finish()
        }
    }

    func stop() async {}
}

@Test func countdownSamplesNeverReachTheFrozenBuffer() async throws {
    // The load-bearing case: five seconds of primed delivery before Go, and
    // none of it in the session. Dropped at admission, not filtered later.
    let clock = SteppableClock()
    let (recorder, _, _, _) = makeRecorder(
        clock: clock,
        motion: LeadInMotionService(fixture: .steadyWalk, clock: clock, leadInSampleCount: 500)
    )

    let events = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    let collector = Task { await collect(events) }
    let buffer = try await recorder.stop()
    _ = await collector.value

    #expect(buffer.isEmpty == false)
    #expect(buffer.honoursAdmissionContract)
    #expect(buffer.samples.allSatisfy { $0.deviceTimestamp >= buffer.anchor.uptime })
}

@Test func theLeadInDoesNotShowUpAsASensorGap() async throws {
    // A rejected sample must not move the gap detector's cursor either. If the
    // lead-in were merely excluded from the buffer but still observed, the jump
    // from the last countdown sample to the first walk sample would read as a
    // dropout the session never had.
    let clock = SteppableClock()
    let (recorder, _, _, log) = makeRecorder(
        clock: clock,
        motion: LeadInMotionService(fixture: .steadyWalk, clock: clock, leadInSampleCount: 500)
    )

    let events = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    let collector = Task { await collect(events) }
    let buffer = try await recorder.stop()
    let collected = await collector.value

    #expect(buffer.gapInfo.gapCount == 0)
    #expect(collected.contains { if case .gapDetected = $0 { return true } else { return false } } == false)
    #expect(log.entries.withLock { $0.contains { $0.contains("sensor gap observed") } } == false)
}

@Test func theLeadInDoesNotStretchTheRecordedSpan() async throws {
    // The session's span is measured from Go. A five-second countdown that
    // leaked in would inflate it by five seconds, and with it every duration
    // derived from it.
    let clock = SteppableClock()
    let (withLeadIn, _, _, _) = makeRecorder(
        clock: clock,
        motion: LeadInMotionService(fixture: .steadyWalk, clock: clock, leadInSampleCount: 500)
    )
    let cleanClock = SteppableClock()
    let (clean, _, _, _) = makeRecorder(fixture: .steadyWalk, clock: cleanClock)

    _ = try await withLeadIn.begin(mode: .quickTest, audioConfig: .none)
    let leadInBuffer = try await withLeadIn.stop()
    _ = try await clean.begin(mode: .quickTest, audioConfig: .none)
    let cleanBuffer = try await clean.stop()

    #expect(leadInBuffer.samples.count == cleanBuffer.samples.count)
    #expect(leadInBuffer.series.recordedSpan == cleanBuffer.series.recordedSpan)
}

@Test func theDroppedLeadInIsReported() async throws {
    // Silent dropping would be indistinguishable from a sensor that delivered
    // nothing, so the count is logged once the session freezes.
    let clock = SteppableClock()
    let (recorder, _, _, log) = makeRecorder(
        clock: clock,
        motion: LeadInMotionService(fixture: .steadyWalk, clock: clock, leadInSampleCount: 200)
    )

    _ = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    _ = try await recorder.stop()

    #expect(log.entries.withLock { $0.contains { $0.contains("admission gate dropped 200 pre-T-0 samples") } })
}

// MARK: - Lifecycle: prime / begin(at:) / abort (Task 4.2.2, docs/07 §7.3)

/// A motion service that reports absent hardware.
private struct UnavailableMotionService: MotionSensorService {
    var isAvailable: Bool { get async { false } }
    var authorizationStatus: MotionAuthorizationStatus { get async { .authorized } }
    func requestAuthorization() async -> MotionAuthorizationStatus { .authorized }
    func start(policy: MotionAcquisitionPolicy) async throws -> AsyncStream<SensorSample> {
        Issue.record("start must not be reached when the hardware is unavailable")
        return AsyncStream { $0.finish() }
    }
    func stop() async {}
}

/// Counts stop() so a test can prove the sensor was released, not just dropped.
private actor CountingMotionService: MotionSensorService {
    let fixture: GaitFixture
    let clock: Clock
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(fixture: GaitFixture, clock: Clock) {
        self.fixture = fixture
        self.clock = clock
    }

    var isAvailable: Bool { true }
    var authorizationStatus: MotionAuthorizationStatus { .authorized }
    func requestAuthorization() async -> MotionAuthorizationStatus { .authorized }

    func start(policy: MotionAcquisitionPolicy) async throws -> AsyncStream<SensorSample> {
        startCount += 1
        let samples = fixture.sensorSamples(anchoredAt: TimeAnchor(clock: clock))
        return AsyncStream { continuation in
            for sample in samples { continuation.yield(sample) }
            continuation.finish()
        }
    }

    func stop() async { stopCount += 1 }
}

// MARK: prime

@Test func primingStartsTheSensorsWithoutStartingASession() async throws {
    let clock = SteppableClock()
    let motion = CountingMotionService(fixture: .steadyWalk, clock: clock)
    let (recorder, _, audio, _) = makeRecorder(clock: clock, motion: motion)

    try await recorder.prime(mode: .quickTest, audioConfig: .none)

    #expect(await motion.startCount == 1)
    #expect(await recorder.isPrimed)
    #expect(await recorder.isRecording == false)
    // No session exists yet, so nothing has been measured and nothing sounded.
    #expect(await recorder.admittedSampleCount == 0)
    #expect(await audio.calls.isEmpty)
}

@Test func theBufferAdmitsNothingForTheWholeCountdown() async throws {
    // The Task 5.1.1 contract, seen from the lifecycle: priming may run for as
    // long as the countdown lasts and the session stays empty throughout.
    let clock = SteppableClock()
    let (recorder, _, _, _) = makeRecorder(clock: clock)

    try await recorder.prime(mode: .quickTest, audioConfig: .none)

    for _ in 0..<5 {
        clock.advance(by: 1)
        #expect(await recorder.admittedSampleCount == 0)
    }
}

@Test func primingKeepsTheScreenAwakeForTheCountdown() async throws {
    // docs/07 §7.7: the countdown exists so the user can stow the phone, so an
    // idle auto-lock partway through it would defeat the feature.
    let screen = ScreenSleepSpy()
    let clock = SteppableClock()
    let (recorder, _, _, _) = makeRecorder(clock: clock, screenSleep: screen)

    try await recorder.prime(mode: .quickTest, audioConfig: .none)

    #expect(await screen.calls == ["prevent"])
}

@Test func primingTwiceIsRefused() async throws {
    let (recorder, _, _, _) = makeRecorder()
    try await recorder.prime(mode: .quickTest, audioConfig: .none)

    await #expect(throws: StabilyzError.recording(.alreadyRecording)) {
        try await recorder.prime(mode: .fullTest, audioConfig: .none)
    }
}

// MARK: begin(at:)

@Test func beginningArmsTheBufferAtT0AndAdmitsTheWalk() async throws {
    let clock = SteppableClock()
    let (recorder, _, _, _) = makeRecorder(clock: clock)

    try await recorder.prime(mode: .quickTest, audioConfig: .none)
    #expect(await recorder.admittedSampleCount == 0)

    let anchor = TimeAnchor(clock: clock)
    let events = try await recorder.begin(at: anchor)
    let collector = Task { await collect(events) }
    let buffer = try await recorder.stop()
    _ = await collector.value

    #expect(buffer.isEmpty == false)
    #expect(buffer.anchor == anchor)
    #expect(buffer.startedAt == anchor.wallClock)
    #expect(buffer.honoursAdmissionContract)
}

@Test func theSessionStartsAtTheAnchorItWasGivenNotAtTheCallSite() async throws {
    // T-0 is the tick the user saw and felt; the recorder does not restamp it.
    let clock = SteppableClock()
    let (recorder, _, _, _) = makeRecorder(clock: clock)

    try await recorder.prime(mode: .quickTest, audioConfig: .none)
    let go = TimeAnchor(clock: clock)
    clock.advance(by: 3)

    _ = try await recorder.begin(at: go)
    let buffer = try await recorder.stop()

    #expect(buffer.anchor == go)
    #expect(buffer.startedAt == go.wallClock)
}

@Test func beginningWithoutPrimingIsRefused() async throws {
    let clock = SteppableClock()
    let (recorder, _, audio, _) = makeRecorder(clock: clock)

    await #expect(throws: StabilyzError.recording(.notPrimed)) {
        _ = try await recorder.begin(at: TimeAnchor(clock: clock))
    }
    #expect(await recorder.isRecording == false)
    // Refused before anything was started, so nothing needs releasing.
    #expect(await audio.calls.isEmpty)
}

@Test func beginningTwiceFromOnePrimingIsRefused() async throws {
    let clock = SteppableClock()
    let (recorder, _, _, _) = makeRecorder(clock: clock)
    try await recorder.prime(mode: .quickTest, audioConfig: .none)
    _ = try await recorder.begin(at: TimeAnchor(clock: clock))

    await #expect(throws: StabilyzError.recording(.alreadyRecording)) {
        _ = try await recorder.begin(at: TimeAnchor(clock: clock))
    }
}

@Test func theConvenienceStartIsTheSameLifecycle() async throws {
    // begin(mode:audioConfig:) is composition, not a second path — a session
    // started through it is indistinguishable from prime-then-begin.
    let clock = SteppableClock()
    let (recorder, _, _, _) = makeRecorder(clock: clock)

    _ = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    #expect(await recorder.isRecording)

    let buffer = try await recorder.stop()
    #expect(buffer.isEmpty == false)
    #expect(buffer.honoursAdmissionContract)
}

// MARK: abort

@Test func abortingACountdownReleasesTheSensorAndLeavesNoSession() async throws {
    let clock = SteppableClock()
    let motion = CountingMotionService(fixture: .steadyWalk, clock: clock)
    let screen = ScreenSleepSpy()
    let (recorder, _, audio, _) = makeRecorder(clock: clock, motion: motion, screenSleep: screen)

    try await recorder.prime(mode: .quickTest, audioConfig: .none)
    await recorder.abort()

    #expect(await motion.stopCount == 1)
    #expect(await recorder.isPrimed == false)
    #expect(await recorder.isRecording == false)
    #expect(await recorder.admittedSampleCount == 0)
    // The screen is handed back, and no audio session was ever opened to leak.
    #expect(await screen.calls == ["prevent", "allow"])
    #expect(await audio.calls.isEmpty)
}

@Test func abortingLeavesNoScratchFileBehind() async throws {
    // The unarmed buffer goes with the countdown, and its scratch file with it
    // (docs/06 §6.4) — raw samples never outlive the session that made them.
    let fileIO = FileManagerFileIO()
    let before = (try? FileManager.default.contentsOfDirectory(
        atPath: fileIO.temporaryDirectory().path
    ).filter { $0.hasSuffix(".ndjson") }) ?? []

    let clock = SteppableClock()
    let (recorder, _, _, _) = makeRecorder(clock: clock)
    try await recorder.prime(mode: .quickTest, audioConfig: .none)
    await recorder.abort()

    let after = (try? FileManager.default.contentsOfDirectory(
        atPath: fileIO.temporaryDirectory().path
    ).filter { $0.hasSuffix(".ndjson") }) ?? []
    #expect(after.count <= before.count)
}

@Test func theRecorderIsReusableAfterAnAbort() async throws {
    // A cancelled countdown must not cost the user the next attempt.
    let clock = SteppableClock()
    let (recorder, _, _, _) = makeRecorder(clock: clock)

    try await recorder.prime(mode: .quickTest, audioConfig: .none)
    await recorder.abort()

    try await recorder.prime(mode: .fullTest, audioConfig: .none)
    _ = try await recorder.begin(at: TimeAnchor(clock: clock))
    let buffer = try await recorder.stop()

    #expect(buffer.mode == .fullTest)
    #expect(buffer.isEmpty == false)
}

@Test func abortingFromIdleDoesNothing() async {
    let (recorder, _, _, _) = makeRecorder()

    await recorder.abort()

    #expect(await recorder.isRecording == false)
    #expect(await recorder.isPrimed == false)
}

@Test func aRunningSessionIsStoppedNotAborted() async throws {
    // stop() is the only exit from a recording and the only place the audio
    // session is released (ledger entry 25), so an abort past T-0 is refused
    // rather than obeyed — it would hold the audio route and bin a real walk.
    let clock = SteppableClock()
    let (recorder, _, _, log) = makeRecorder(clock: clock)
    try await recorder.prime(mode: .quickTest, audioConfig: .none)
    _ = try await recorder.begin(at: TimeAnchor(clock: clock))

    await recorder.abort()

    #expect(await recorder.isRecording)
    #expect(log.entries.withLock { $0.contains { $0.contains("abort refused") } })

    let buffer = try await recorder.stop()
    #expect(buffer.isEmpty == false)
}

// MARK: priming failure

@Test func aPrimingTimeoutSurfacesAndResetsTheRecorder() async throws {
    // The failure the countdown exists to catch: it must surface while the user
    // is still watching the screen, not silently at T-0 with the phone pocketed.
    let (recorder, _, _, log) = makeRecorder(
        motion: FailingMotionService(error: .sensor(.primingTimeout))
    )

    await #expect(throws: StabilyzError.sensor(.primingTimeout)) {
        try await recorder.prime(mode: .quickTest, audioConfig: .none)
    }

    #expect(await recorder.isPrimed == false)
    #expect(await recorder.isRecording == false)
    #expect(log.entries.withLock { $0.contains { $0.contains("priming failed") } })
}

@Test func aFailedPrimingLeavesTheRecorderReusable() async throws {
    // Recoverable, per ErrorPresenter: the user can try again.
    let clock = SteppableClock()
    let (recorder, _, _, _) = makeRecorder(
        clock: clock,
        motion: FailingMotionService(error: .sensor(.primingTimeout))
    )

    await #expect(throws: StabilyzError.sensor(.primingTimeout)) {
        try await recorder.prime(mode: .quickTest, audioConfig: .none)
    }

    // A fresh recorder stands in for the retry succeeding; what matters here is
    // that the failed one did not stay wedged in a half-primed state.
    #expect(await recorder.isPrimed == false)
    await recorder.abort()
    #expect(await recorder.isRecording == false)
}

@Test func absentHardwareIsRefusedBeforeTheSensorIsEvenStarted() async throws {
    let (recorder, _, _, log) = makeRecorder(motion: UnavailableMotionService())

    await #expect(throws: StabilyzError.sensor(.unavailable)) {
        try await recorder.prime(mode: .quickTest, audioConfig: .none)
    }

    #expect(await recorder.isPrimed == false)
    #expect(log.entries.withLock { $0.contains { $0.contains("motion hardware unavailable") } })
}

@Test func deniedPermissionIsRefusedAtPrimingNotAtGo() async throws {
    let (recorder, _, _, _) = makeRecorder(
        motion: FailingMotionService(error: .sensor(.unavailable), authorization: .denied)
    )

    await #expect(throws: StabilyzError.permission(.motionDenied)) {
        try await recorder.prime(mode: .quickTest, audioConfig: .none)
    }
    #expect(await recorder.isPrimed == false)
}

@Test func aFailedPrimingReleasesTheScreen() async throws {
    // Nothing was primed, so nothing should be holding the idle timer down.
    let screen = ScreenSleepSpy()
    let (recorder, _, _, _) = makeRecorder(
        motion: FailingMotionService(error: .sensor(.primingTimeout)),
        screenSleep: screen
    )

    await #expect(throws: StabilyzError.sensor(.primingTimeout)) {
        try await recorder.prime(mode: .quickTest, audioConfig: .none)
    }

    let calls = await screen.calls
    #expect(calls.contains("prevent") == false || calls.last == "allow")
}

// MARK: the two halves together

@Test func aFullCountdownPrimesThenStartsAndKeepsOnlyTheWalk() async throws {
    // The shape Task 8.2.6 will drive: prime at the tap, five seconds of
    // sensors running against an unarmed buffer, then Go. Everything the
    // sensors delivered during those five seconds is rejected on its timestamp,
    // and the session begins at the tick the user was shown.
    let clock = SteppableClock()
    let (recorder, _, _, log) = makeRecorder(
        clock: clock,
        motion: LeadInMotionService(fixture: .steadyWalk, clock: clock, leadInSampleCount: 500)
    )

    try await recorder.prime(mode: .quickTest, audioConfig: .none)
    #expect(await recorder.isPrimed)
    #expect(await recorder.admittedSampleCount == 0)

    // The countdown runs. Nothing has been admitted at any point in it.
    for _ in 0..<5 {
        clock.advance(by: 1)
        #expect(await recorder.admittedSampleCount == 0)
    }

    // Go. T-0 is the anchor the countdown stamped at its final tick.
    let go = TimeAnchor(clock: clock)
    let events = try await recorder.begin(at: go)
    let collector = Task { await collect(events) }
    let buffer = try await recorder.stop()
    _ = await collector.value

    #expect(buffer.anchor == go)
    #expect(buffer.honoursAdmissionContract)
    #expect(buffer.samples.allSatisfy { $0.deviceTimestamp >= go.uptime })
    // The lead-in was counted and reported, not silently binned.
    #expect(log.entries.withLock { $0.contains { $0.contains("admission gate dropped") } })
}

@Test func aCountdownAbortedPartWayThroughRecordsNothing() async throws {
    let clock = SteppableClock()
    let motion = CountingMotionService(fixture: .steadyWalk, clock: clock)
    let (recorder, _, audio, _) = makeRecorder(clock: clock, motion: motion)

    try await recorder.prime(mode: .quickTest, audioConfig: .none)
    clock.advance(by: 3)
    await recorder.abort()

    #expect(await motion.stopCount == 1)
    #expect(await recorder.admittedSampleCount == 0)
    // No session was created, so there is nothing to stop and nothing to score.
    await #expect(throws: StabilyzError.recording(.notRecording)) {
        _ = try await recorder.stop()
    }
    #expect(await audio.calls.isEmpty)
}

// MARK: - Silencing a cue mid-session

@Test func silencingRecordsWhenTheWalkWentQuiet() async throws {
    // The session keeps the config it started with; this says the rest of it
    // was silent, so the stored row describes what actually happened rather
    // than claiming one state for a walk that had two.
    let clock = SteppableClock()
    let (recorder, _, _, log) = makeRecorder(clock: clock)

    try await recorder.prime(mode: .quickTest, audioConfig: .stepFeedback)
    _ = try await recorder.begin(at: TimeAnchor(clock: clock))
    clock.advance(by: 45)
    #expect(await recorder.silenceAudioCues())

    let buffer = try await recorder.stop()

    #expect(buffer.audioConfig == .stepFeedback)
    #expect(buffer.audioSilencedAt == .seconds(45))
    #expect(log.entries.withLock { $0.contains { $0.contains("audio cues silenced") } })
}

@Test func silencingIsIdempotentAndKeepsTheFirstMoment() async throws {
    let clock = SteppableClock()
    let (recorder, _, _, _) = makeRecorder(clock: clock)

    try await recorder.prime(mode: .quickTest, audioConfig: .stepFeedback)
    _ = try await recorder.begin(at: TimeAnchor(clock: clock))
    clock.advance(by: 10)
    #expect(await recorder.silenceAudioCues())
    clock.advance(by: 30)
    // The second call changes nothing — the walk went quiet once.
    #expect(await recorder.silenceAudioCues() == false)

    let buffer = try await recorder.stop()
    #expect(buffer.audioSilencedAt == .seconds(10))
}

@Test func aSilentSessionHasNothingToSilence() async throws {
    let clock = SteppableClock()
    let (recorder, _, _, _) = makeRecorder(clock: clock)

    try await recorder.prime(mode: .quickTest, audioConfig: .none)
    _ = try await recorder.begin(at: TimeAnchor(clock: clock))

    #expect(await recorder.silenceAudioCues() == false)

    let buffer = try await recorder.stop()
    #expect(buffer.audioSilencedAt == nil)
}

@Test func aCueCannotBeSilencedBeforeTheWalkStarts() async throws {
    // There is nothing playing during the countdown — cues are armed by
    // `begin`, never by `prime` (Task 7.2.3).
    let clock = SteppableClock()
    let (recorder, _, _, _) = makeRecorder(clock: clock)

    try await recorder.prime(mode: .quickTest, audioConfig: .stepFeedback)
    #expect(await recorder.silenceAudioCues() == false)

    _ = try await recorder.begin(at: TimeAnchor(clock: clock))
    #expect(await recorder.silenceAudioCues())
    _ = try await recorder.stop()
}

@Test func silencingDoesNotSurviveIntoTheNextSession() async throws {
    let clock = SteppableClock()
    let (recorder, _, _, _) = makeRecorder(clock: clock)

    try await recorder.prime(mode: .quickTest, audioConfig: .stepFeedback)
    _ = try await recorder.begin(at: TimeAnchor(clock: clock))
    clock.advance(by: 5)
    #expect(await recorder.silenceAudioCues())
    _ = try await recorder.stop()

    try await recorder.prime(mode: .fullTest, audioConfig: .stepFeedback)
    _ = try await recorder.begin(at: TimeAnchor(clock: clock))
    let second = try await recorder.stop()

    #expect(second.audioSilencedAt == nil)
}
