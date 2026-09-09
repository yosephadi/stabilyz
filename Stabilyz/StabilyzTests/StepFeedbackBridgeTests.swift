import Foundation
import Testing
@testable import Stabilyz

// MARK: - Doubles

private final class BridgeLog: LogService, @unchecked Sendable {
    let entries = Locked<[String]>([])
    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        entries.withLock { $0.append(message) }
    }
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

/// Counts what the wiring asks for. Ticks are inaudible in a test; the request
/// for one is not.
private actor TickSpy: AudioFeedbackService {
    nonisolated var events: AsyncStream<AudioFeedbackEvent> { AsyncStream { $0.finish() } }

    private(set) var tickCount = 0

    func playStartTone() async {}
    func playStopTone() async {}
    func playStepTick() async { tickCount += 1 }
    func startMetronome(bpm: Double) async {}
    func stopMetronome() async {}
    func suspend() async {}
    func resume() async {}
}

/// An audio service that never finishes a tick, standing in for a stalled or
/// suspended consumer.
///
/// Counts starts and finishes separately, so "the recording did not wait" is a
/// fact about the two counts rather than a stopwatch reading.
private actor SlowTickSpy: AudioFeedbackService {
    nonisolated var events: AsyncStream<AudioFeedbackEvent> { AsyncStream { $0.finish() } }

    private(set) var startedTicks = 0
    private(set) var finishedTicks = 0
    private let delay: Duration

    init(delay: Duration) { self.delay = delay }

    func playStartTone() async {}
    func playStopTone() async {}
    func playStepTick() async {
        startedTicks += 1
        try? await Task.sleep(for: delay)
        finishedTicks += 1
    }
    func startMetronome(bpm: Double) async {}
    func stopMetronome() async {}
    func suspend() async {}
    func resume() async {}
}

private struct BridgeClock: Clock {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let uptime: TimeInterval = 0
}

private let policy = AlgorithmConfiguration.v1.liveStepFeedback

private func event(at t: TimeInterval, confidence: Double = 1) -> LiveStepEvent {
    LiveStepEvent(deviceTimestamp: t, confidence: confidence)
}

/// Runs a scripted event list through a bridge and returns the ticks requested.
private func ticks(
    for events: [LiveStepEvent],
    audioConfig: SessionAudioConfig = .stepFeedback,
    policy: LiveStepDetectionPolicy = policy
) async -> Int {
    let spy = TickSpy()
    let bridge = StepFeedbackBridge(audioFeedback: spy, policy: policy, logService: BridgeLog())
    let (stream, continuation) = AsyncStream<LiveStepEvent>.makeStream(bufferingPolicy: .unbounded)

    await bridge.start(audioConfig: audioConfig, events: stream)
    for event in events { continuation.yield(event) }
    continuation.finish()
    await bridge.drain()

    return await spy.tickCount
}

// MARK: - Off by default [PRD AC]

@Test func theWiringIsInertWithoutTheSessionsOptIn() async {
    // Not "silent but running": the stream is not read at all.
    let spy = TickSpy()
    let bridge = StepFeedbackBridge(audioFeedback: spy, policy: policy, logService: BridgeLog())
    let (stream, continuation) = AsyncStream<LiveStepEvent>.makeStream(bufferingPolicy: .unbounded)

    await bridge.start(audioConfig: .none, events: stream)
    #expect(await bridge.isConsuming == false, "the stream is being consumed without an opt-in")

    for index in 0..<10 { continuation.yield(event(at: Double(index) * 0.6)) }
    continuation.finish()
    await bridge.drain()

    #expect(await spy.tickCount == 0)
    #expect(await bridge.tickCount == 0)
}

@Test func aMetronomeSessionDoesNotGetStepFeedback() async {
    // The two engines are separate (docs/10 §10.1); opting into one is not
    // opting into the other.
    #expect(await ticks(for: [event(at: 0), event(at: 0.6)], audioConfig: .metronome(bpm: 108)) == 0)
}

@Test func optingInTicksOncePerConfidentStep() async {
    let steps = [event(at: 0), event(at: 0.6), event(at: 1.2), event(at: 1.8)]
    #expect(await ticks(for: steps) == 4)
}

@Test func stoppingASessionSilencesFurtherEvents() async {
    let spy = TickSpy()
    let bridge = StepFeedbackBridge(audioFeedback: spy, policy: policy, logService: BridgeLog())
    let (stream, continuation) = AsyncStream<LiveStepEvent>.makeStream(bufferingPolicy: .unbounded)

    await bridge.start(audioConfig: .stepFeedback, events: stream)
    continuation.yield(event(at: 0))
    // Ticks are delivered by an independent task, so the first one has to have
    // landed before stopping means anything.
    #expect(await eventuallyTicked(spy))

    await bridge.stop()
    continuation.yield(event(at: 0.6))
    continuation.finish()
    await bridge.drain()

    #expect(await spy.tickCount == 1)
}

// MARK: - Confidence gate (docs/10 §10.3)

@Test func aStepBelowTheConfidenceThresholdIsSilent() async {
    let below = policy.confidenceThreshold / 2
    #expect(await ticks(for: [event(at: 0, confidence: below)]) == 0)
}

@Test func onlyTheConfidentStepsOfAMixedRunTick() async {
    // Raw spikes must never create an accidental rhythm [PRD §6, OQ-4].
    let steps = [
        event(at: 0, confidence: 0.9),
        event(at: 0.6, confidence: 0.1),
        event(at: 1.2, confidence: 0.8),
        event(at: 1.8, confidence: 0.0),
    ]
    #expect(await ticks(for: steps) == 2)
}

@Test func aStepExactlyAtTheThresholdTicks() {
    // The gate is "at or above", so the boundary is audible.
    var gate = StepTickGate(policy: policy)
    // `#expect` rewrites its sub-expressions, so a mutating call is made first.
    let admitted = gate.admits(event(at: 0, confidence: policy.confidenceThreshold))
    #expect(admitted)
}

// MARK: - Refractory gate (docs/10 §10.3)

@Test func aSecondEventInsideTheRefractoryWindowIsSuppressed() async {
    // One footfall, two peaks: one sound [PRD §6, §7].
    let doubled = [event(at: 0), event(at: 0.05)]
    #expect(await ticks(for: doubled) == 1)
}

@Test func theWindowIsMeasuredFromTheLastTickNotTheLastEvent() {
    // Otherwise a stream of suppressed events would hold the gate shut
    // indefinitely and the walk would fall silent.
    var gate = StepTickGate(policy: LiveStepDetectionPolicy(confidenceThreshold: 0.5, refractory: .milliseconds(300)))
    // 0.35 s after the last tick, though only 0.15 s after the last event.
    let admitted = [0, 0.1, 0.2, 0.35].map { gate.admits(event(at: $0)) }

    #expect(admitted == [true, false, false, true])
}

@Test func anOutOfOrderEventIsSuppressed() {
    var gate = StepTickGate(policy: policy)
    let admitted = [1.0, 0.5].map { gate.admits(event(at: $0)) }

    #expect(admitted == [true, false])
}

@Test func resetLetsTheNextSessionsFirstStepThrough() {
    // A new walk is never judged against the last step of the previous one.
    var gate = StepTickGate(policy: policy)
    let first = gate.admits(event(at: 10.0))
    gate.reset()
    // Well inside the refractory window, and audible anyway.
    let afterReset = gate.admits(event(at: 10.01))

    #expect(first)
    #expect(afterReset)
}

@Test func aShorterWindowLetsCloserStepsThrough() async {
    // The value is [OPEN]; the gate must honour whatever configuration says.
    let close = [event(at: 0), event(at: 0.1)]
    let quick = LiveStepDetectionPolicy(confidenceThreshold: 0.5, refractory: .milliseconds(50))

    #expect(await ticks(for: close) == 1)
    #expect(await ticks(for: close, policy: quick) == 2)
}

// MARK: - Reactive, never a tempo [PRD AC, OQ-4]

@Test func irregularStepsProduceIrregularTicks() {
    // The wiring imposes no period of its own: every admitted tick lands on its
    // own step's timestamp, so an uneven walk sounds uneven.
    let intervals: [TimeInterval] = [0.52, 0.94, 0.61, 1.35, 0.55]
    var times: [TimeInterval] = [0]
    for interval in intervals { times.append(times.last! + interval) }

    var gate = StepTickGate(policy: policy)
    let admitted = times.filter { gate.admits(event(at: $0)) }

    #expect(admitted == times, "the gate re-timed or dropped a confident step")

    let tickIntervals = zip(admitted.dropFirst(), admitted).map { $0 - $1 }
    #expect(tickIntervals.count == intervals.count)
    for (tick, step) in zip(tickIntervals, intervals) {
        #expect(abs(tick - step) < 1e-9, "tick interval \(tick) did not mirror step interval \(step)")
    }

    // And emphatically not a fixed period.
    let spread = (tickIntervals.max() ?? 0) - (tickIntervals.min() ?? 0)
    #expect(spread > 0.5)
}

@Test func ticksFollowDetectedFootfallsThroughTheWholePath() {
    // Detector + gate together, on an irregularly-timed footfall signal: every
    // sound coincides with a scripted footfall, and the sounds are not evenly
    // spaced.
    let footfallTimes: [TimeInterval] = [0.4, 1.0, 1.85, 2.4, 3.5, 4.1]
    let anchor = TimeAnchor(wallClock: Date(timeIntervalSince1970: 1_700_000_000), uptime: 0)
    let sampleRate = 100.0

    let samples = (0..<Int(5 * sampleRate)).map { index -> SensorSample in
        let t = Double(index) / sampleRate
        let isFootfall = footfallTimes.contains { abs($0 - t) < 0.005 }
        return SensorSample(
            deviceTimestamp: t,
            anchor: anchor,
            acceleration: Vector3(x: 0, y: 0, z: isFootfall ? 4 : 1)
        )
    }

    var detector = LiveStepDetector(policy: policy)
    var gate = StepTickGate(policy: policy)
    let tickTimes = samples
        .compactMap { detector.process($0) }
        .filter { gate.admits($0) }
        .map(\.deviceTimestamp)

    #expect(tickTimes.count >= 4, "the path went silent on a real footfall signal")
    for tick in tickTimes {
        // The detector reports a peak one sample late by construction.
        #expect(
            footfallTimes.contains { abs($0 - tick) <= 0.03 },
            "a tick at \(tick) matched no footfall — the path invented a beat"
        )
    }

    let tickIntervals = zip(tickTimes.dropFirst(), tickTimes).map { $0 - $1 }
    let spread = (tickIntervals.max() ?? 0) - (tickIntervals.min() ?? 0)
    #expect(spread > 0.2, "evenly spaced ticks — the path imposed a tempo")
}

@Test func standingStillIsSilent() async throws {
    // No steps, no sound. Nothing in the path can produce a tick on its own.
    let clock = BridgeClock()
    let flat = GaitFixture(
        metadata: .init(name: "standing", sampleRateHz: 100, deviceMotionIncluded: true),
        samples: (0..<300).map { .init(t: Double($0) / 100, ax: 0, ay: 0, az: 1, gx: 0, gy: 0, gz: -1) }
    )
    let spy = TickSpy()
    let recorder = makeRecorder(fixture: flat, clock: clock, audio: spy)

    _ = try await recorder.begin(mode: .quickTest, audioConfig: .stepFeedback)
    _ = try await recorder.stop()
    try await Task.sleep(for: .milliseconds(100))

    #expect(await spy.tickCount == 0)
}

// MARK: - Suspended audio drops rather than queues (7.1.2's decision holds)

@Test func ticksRequestedWhileTheServiceIsSuspendedAreDroppedNotQueued() async {
    let service = EngineAudioFeedbackService(logService: BridgeLog())
    await service.prepare()
    guard await service.isRunning else {
        // No audio route on this host; the drop path is covered by the
        // service's own tests.
        await service.teardown()
        return
    }

    let bridge = StepFeedbackBridge(audioFeedback: service, policy: policy, logService: BridgeLog())
    let (stream, continuation) = AsyncStream<LiveStepEvent>.makeStream(bufferingPolicy: .unbounded)
    await bridge.start(audioConfig: .stepFeedback, events: stream)

    await service.suspend()
    let before = await service.scheduledToneCount

    for index in 0..<5 { continuation.yield(event(at: Double(index) * 0.6)) }
    continuation.finish()
    await bridge.drain()

    #expect(await service.scheduledToneCount == before, "ticks were played while suspended")

    await service.resume()
    #expect(await service.scheduledToneCount == before, "ticks queued up and fired late")

    // The wiring did its job — the drop is the service's decision, not silence
    // from a bridge that stopped working.
    #expect(await bridge.tickCount == 5)

    await service.teardown()
}

// MARK: - The sample path is never blocked (4.3.1's design stands)

@Test func aStalledAudioConsumerNeverDelaysRecording() async throws {
    // Newest-value buffering on the step stream means a slow audio layer drops
    // ticks rather than backing up into ingestion (docs/10 §10.4).
    let clock = BridgeClock()
    let fixture = footfallFixture(name: "stalled-audio")
    // Long enough that a session which waited for it could not possibly finish.
    let slow = SlowTickSpy(delay: .seconds(30))
    let recorder = makeRecorder(fixture: fixture, clock: clock, audio: slow)

    let started = Date()
    _ = try await recorder.begin(mode: .quickTest, audioConfig: .stepFeedback)
    #expect(await eventuallyStartedATick(slow), "no tick was requested, so nothing was stalled")

    let buffer = try await recorder.stop()
    let elapsed = Date().timeIntervalSince(started)

    // The session finished while the audio layer was still stuck inside its
    // first tick — the clock-free form of "recording never waits on audio".
    #expect(await slow.finishedTicks == 0)
    #expect(await slow.startedTicks > 0)
    #expect(elapsed < 20, "recording waited on the stalled audio layer: \(elapsed)s")
    // And nothing was lost on the way through.
    #expect(buffer.series.samples.count == fixture.samples.count)
}

// MARK: - Recorder integration

@Test func aStepFeedbackSessionTicksOnFootfalls() async throws {
    let clock = BridgeClock()
    let fixture = footfallFixture(name: "ticking")
    let spy = TickSpy()
    let recorder = makeRecorder(fixture: fixture, clock: clock, audio: spy)

    // Observed while the session is running: stopping disarms the wiring and
    // drops whatever was in flight, which is the intended behaviour.
    _ = try await recorder.begin(mode: .quickTest, audioConfig: .stepFeedback)
    let ticked = await eventuallyTicked(spy)
    _ = try await recorder.stop()

    #expect(ticked)
}

@Test func aSessionWithoutTheOptInNeverTicks() async throws {
    // The recorder runs no detector and the bridge reads no stream — the two
    // halves of "off by default" [PRD AC].
    let clock = BridgeClock()
    let fixture = footfallFixture(name: "quiet")
    let spy = TickSpy()
    let recorder = makeRecorder(fixture: fixture, clock: clock, audio: spy)

    _ = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    _ = try await recorder.stop()
    try await Task.sleep(for: .milliseconds(100))

    #expect(await spy.tickCount == 0)
}

@Test func aSilentSessionAfterATickingOneStaysSilent() async throws {
    // The consumer outlives one session by design; disarming is what stops the
    // ticks, and it must actually stop them.
    let clock = BridgeClock()
    let fixture = footfallFixture(name: "then-quiet")
    let spy = TickSpy()
    let recorder = makeRecorder(fixture: fixture, clock: clock, audio: spy)

    _ = try await recorder.begin(mode: .quickTest, audioConfig: .stepFeedback)
    #expect(await eventuallyTicked(spy))
    _ = try await recorder.stop()
    let afterFirst = await spy.tickCount

    _ = try await recorder.begin(mode: .fullTest, audioConfig: .none)
    _ = try await recorder.stop()
    try await Task.sleep(for: .milliseconds(100))

    #expect(await spy.tickCount == afterFirst)
}

// MARK: - Helpers

/// A capture of sharp footfalls, the shape the live detector is built for: a
/// quiet baseline with a narrow spike per step (docs/07 §7.9). `makeWalk`'s
/// smooth sine is a plumbing fixture and is deliberately not confident enough
/// to tick.
private func footfallFixture(
    name: String,
    stepsPerSecond: Double = 2,
    seconds: Double = 4,
    sampleRateHz: Double = 100
) -> GaitFixture {
    let count = Int(seconds * sampleRateHz)
    let period = sampleRateHz / stepsPerSecond

    let samples = (0..<count).map { index -> GaitFixture.Sample in
        let phase = Double(index).truncatingRemainder(dividingBy: period)
        return GaitFixture.Sample(
            t: Double(index) / sampleRateHz,
            ax: 0, ay: 0, az: phase < 2 ? 3 : 1,
            gx: 0, gy: 0, gz: -1
        )
    }

    return GaitFixture(
        metadata: .init(
            name: name,
            sampleRateHz: sampleRateHz,
            deviceMotionIncluded: true,
            cadenceBPM: stepsPerSecond * 60
        ),
        samples: samples
    )
}

private func makeRecorder(
    fixture: GaitFixture,
    clock: Clock,
    audio: AudioFeedbackService
) -> SessionRecorder {
    SessionRecorder(
        motionSensor: FixtureSensorService(fixture: fixture, clock: clock),
        pedometer: FixturePedometerService(fixture: fixture, clock: clock),
        audioFeedback: audio,
        interruptionObserver: SystemSessionInterruptionObserver(audioFeedback: SilentAudioFeedbackService()),
        screenSleep: SystemScreenSleepController(),
        clock: clock,
        logService: BridgeLog(),
        fileIO: FileManagerFileIO()
    )
}

/// Ticks are delivered by an independent task, so a session that has stopped
/// may still have one in flight. Waits briefly rather than sleeping a fixed
/// amount.
private func eventuallyTicked(_ spy: TickSpy) async -> Bool {
    for _ in 0..<100 {
        if await spy.tickCount > 0 { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

private func eventuallyStartedATick(_ spy: SlowTickSpy) async -> Bool {
    for _ in 0..<100 {
        if await spy.startedTicks > 0 { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}
