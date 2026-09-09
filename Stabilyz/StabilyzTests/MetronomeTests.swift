import AVFoundation
import Foundation
import Testing
@testable import Stabilyz

// MARK: - Doubles

private final class MetronomeLog: LogService, @unchecked Sendable {
    let entries = Locked<[String]>([])
    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        entries.withLock { $0.append(message) }
    }
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

/// Records what the session asked the audio layer for.
private actor MetronomeSpy: AudioFeedbackService {
    nonisolated var events: AsyncStream<AudioFeedbackEvent> { AsyncStream { $0.finish() } }

    private(set) var startedTempos: [Double] = []
    private(set) var stopCount = 0
    private(set) var stepTickCount = 0

    func playStartTone() async {}
    func playStopTone() async {}
    func playStepTick() async { stepTickCount += 1 }
    func startMetronome(bpm: Double) async { startedTempos.append(bpm) }
    func stopMetronome() async { stopCount += 1 }
    func suspend() async {}
    func resume() async {}
}

private struct MetronomeClock: Clock {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let uptime: TimeInterval = 0
}

private let stepPolicy = AlgorithmConfiguration.v1.liveStepFeedback

// MARK: - Interval derivation from BPM

@Test func theIntervalIsSixtyOverTheBaselineCadence() {
    // docs/10 §10.1: interval = 60 / Baseline.cadenceBPM.
    let cue = MetronomeCue(baseline: .fixture(mode: .quickTest, cadenceBPM: 120), mode: .quickTest)

    #expect(cue?.bpm == 120)
    #expect(cue?.interval == .seconds(0.5))
}

@Test func anAwkwardCadenceStillYieldsItsExactInterval() {
    // Real baselines are means of five sessions, so round numbers are the
    // exception rather than the rule.
    let cue = MetronomeCue(baseline: .fixture(mode: .fullTest, cadenceBPM: 108.4), mode: .fullTest)

    #expect(cue?.interval == .seconds(60 / 108.4))
}

@Test func theCueCarriesTheTempoOntoTheSessionRecord() {
    // What is persisted says the walk was paced, and at what [docs/05 §5.1].
    let cue = MetronomeCue(baseline: .fixture(cadenceBPM: 104), mode: .quickTest)

    #expect(cue?.audioConfig == .metronome(bpm: 104))
}

// MARK: - The baseline gate is structural [PRD AC]

@Test func withoutABaselineTheMetronomeCannotBeSelected() {
    // Sessions 1–5 have no baseline in that mode, so there is no value to
    // build — not a disabled toggle, an unconstructible one.
    #expect(MetronomeCue(baseline: nil, mode: .quickTest) == nil)
    #expect(MetronomeCue(baseline: nil, mode: .fullTest) == nil)
}

@Test func aBaselineFromTheOtherModeIsRefused() {
    // [PRD OQ-5] A Quick Test is never paced by the Full Test's tempo.
    let full = Baseline.fixture(mode: .fullTest, cadenceBPM: 120)

    #expect(MetronomeCue(baseline: full, mode: .quickTest) == nil)
}

@Test func eachModePacesFromItsOwnBaseline() async throws {
    // Two established baselines with different cadences; each mode's session
    // uses its own, and there is no path by which it could use the other's.
    let repository = try InMemoryStore().baselines
    try await repository.save(.fixture(mode: .quickTest, cadenceBPM: 96))
    try await repository.save(.fixture(mode: .fullTest, cadenceBPM: 124))

    let quick = MetronomeCue(baseline: try await repository.baseline(mode: .quickTest), mode: .quickTest)
    let full = MetronomeCue(baseline: try await repository.baseline(mode: .fullTest), mode: .fullTest)

    #expect(quick?.bpm == 96)
    #expect(full?.bpm == 124)
    // 60.0, not 60: an integer literal here divides to zero and the
    // expectation would be comparing the tempo against silence.
    #expect(quick?.interval == .seconds(60.0 / 96))
    #expect(full?.interval == .seconds(60.0 / 124))
}

@Test func aModeWithNoBaselineYetGetsNoMetronomeEvenWhenTheOtherModeHasOne() async throws {
    // The realistic mid-way state: Quick calibrated, Full still building.
    let repository = try InMemoryStore().baselines
    try await repository.save(.fixture(mode: .quickTest, cadenceBPM: 96))

    let full = MetronomeCue(baseline: try await repository.baseline(mode: .fullTest), mode: .fullTest)

    #expect(full == nil)
}

@Test func anImplausibleCadenceProducesNoCueRatherThanAnUnplayableTempo() {
    #expect(MetronomeCue(baseline: .fixture(cadenceBPM: 0), mode: .quickTest) == nil)
    #expect(MetronomeCue(baseline: .fixture(cadenceBPM: -20), mode: .quickTest) == nil)
    #expect(MetronomeCue(baseline: .fixture(cadenceBPM: .nan), mode: .quickTest) == nil)
}

// MARK: - The beat grid

@Test func theGridIsAWholeNumberOfFramesPerBeat() {
    let schedule = MetronomeSchedule(interval: .seconds(0.5), sampleRate: 48_000, startingAt: 0)

    #expect(schedule?.framesPerBeat == 24_000)
}

@Test func beatsAreEvenlySpacedAndDoNotDrift() {
    // Rounding once and stepping by that amount, rather than rounding each
    // beat, is what keeps a six-minute walk in time.
    var schedule = try! #require(
        MetronomeSchedule(interval: .seconds(60 / 108.4), sampleRate: 44_100, startingAt: 1_000)
    )
    let framesPerBeat = schedule.framesPerBeat

    let beats = (0..<200).map { _ in schedule.nextBeat() }
    let gaps = Set(zip(beats.dropFirst(), beats).map { $0 - $1 })

    #expect(gaps == [framesPerBeat], "the beat spacing varied: \(gaps.sorted())")
    #expect(beats.last == 1_000 + 199 * framesPerBeat, "the grid drifted over 200 beats")
}

@Test func anUnusableTempoOrFormatProducesNoSchedule() {
    // Silence is the right answer; a schedule that fires every frame is not.
    #expect(MetronomeSchedule(interval: .seconds(0.5), sampleRate: 0, startingAt: 0) == nil)
    #expect(MetronomeSchedule(interval: .zero, sampleRate: 48_000, startingAt: 0) == nil)
    #expect(MetronomeSchedule(interval: .seconds(-1), sampleRate: 48_000, startingAt: 0) == nil)
    // Shorter than a single frame.
    #expect(MetronomeSchedule(interval: .nanoseconds(1), sampleRate: 48_000, startingAt: 0) == nil)
}

@Test func reanchoringResumesFromNowAndReplaysNothing() {
    // An interruption of any length costs the beats that fell during it — they
    // are gone, not queued behind the resume.
    var schedule = try! #require(
        MetronomeSchedule(interval: .seconds(0.5), sampleRate: 48_000, startingAt: 0)
    )
    let beforeSuspension = (0..<4).map { _ in schedule.nextBeat() }

    // Ten seconds pass with the engine stopped: twenty beats' worth.
    let resumeFrame: Int64 = 48_000 * 10
    schedule.reanchor(at: resumeFrame)
    let afterResume = (0..<4).map { _ in schedule.nextBeat() }

    #expect(afterResume.first == resumeFrame, "the metronome did not resume from now")
    #expect(afterResume.allSatisfy { $0 >= resumeFrame }, "a missed beat was replayed")
    #expect(afterResume.count == beforeSuspension.count, "resume produced a catch-up burst")
    // Same tempo on the other side.
    let gaps = Set(zip(afterResume.dropFirst(), afterResume).map { $0 - $1 })
    #expect(gaps == [schedule.framesPerBeat])
}

// MARK: - THE MIRROR TEST [PRD OQ-4]

@Test func theMetronomeSchedulesAndNeverMirrorsStepsWhileStepFeedbackDoesTheReverse() {
    // One irregular walk, both engines. Step Feedback's ticks follow the steps
    // and are as uneven as the walk; the metronome's beats are unmoved by them.
    let footfallTimes: [TimeInterval] = [0.4, 1.0, 1.85, 2.4, 3.5, 4.1]
    let sampleRate = 100.0
    let anchor = TimeAnchor(wallClock: Date(timeIntervalSince1970: 1_700_000_000), uptime: 0)

    let samples = (0..<Int(5 * sampleRate)).map { index -> SensorSample in
        let t = Double(index) / sampleRate
        let isFootfall = footfallTimes.contains { abs($0 - t) < 0.005 }
        return SensorSample(
            deviceTimestamp: t,
            anchor: anchor,
            acceleration: Vector3(x: 0, y: 0, z: isFootfall ? 4 : 1)
        )
    }

    // Step Feedback: mirrors the walk.
    var detector = LiveStepDetector(policy: stepPolicy)
    var gate = StepTickGate(policy: stepPolicy)
    let tickTimes = samples
        .compactMap { detector.process($0) }
        .filter { gate.admits($0) }
        .map(\.deviceTimestamp)
    let tickGaps = zip(tickTimes.dropFirst(), tickTimes).map { $0 - $1 }
    let tickSpread = (tickGaps.max() ?? 0) - (tickGaps.min() ?? 0)

    // The metronome: same walk, same five seconds, unmoved by any of it. There
    // is no API by which those steps could reach it.
    let cue = try! #require(MetronomeCue(baseline: .fixture(cadenceBPM: 120), mode: .quickTest))
    var schedule = try! #require(
        MetronomeSchedule(interval: cue.interval, sampleRate: 48_000, startingAt: 0)
    )
    let beats = (0..<10).map { _ in schedule.nextBeat() }
    let beatGaps = Set(zip(beats.dropFirst(), beats).map { $0 - $1 })

    #expect(tickSpread > 0.2, "step feedback did not follow the irregular walk")
    #expect(beatGaps.count == 1, "the metronome's spacing varied with something")
    #expect(beatGaps.first == 24_000, "the metronome's period was not 60 / 120")
}

// MARK: - Opt-in only

@Test func noSessionOptInStartsNoScheduling() async throws {
    // Inert, not silent-but-running: nothing is scheduled at all.
    let clock = MetronomeClock()
    let fixture = GaitFixture.makeWalk(name: "no-metronome", cadenceBPM: 108, seconds: 2)

    for config in [SessionAudioConfig.none, .stepFeedback] {
        let spy = MetronomeSpy()
        let recorder = makeRecorder(fixture: fixture, clock: clock, audio: spy)

        _ = try await recorder.begin(mode: .quickTest, audioConfig: config)
        _ = try await recorder.stop()

        #expect(await spy.startedTempos.isEmpty, "\(config) started the metronome")
        #expect(await spy.stopCount == 0)
    }
}

@Test func aMetronomeSessionStartsAndStopsAtTheSessionsTempo() async throws {
    let clock = MetronomeClock()
    let fixture = GaitFixture.makeWalk(name: "paced", cadenceBPM: 108, seconds: 2)
    let cue = try #require(MetronomeCue(baseline: .fixture(mode: .quickTest, cadenceBPM: 104), mode: .quickTest))
    let spy = MetronomeSpy()
    let recorder = makeRecorder(fixture: fixture, clock: clock, audio: spy)

    _ = try await recorder.begin(mode: .quickTest, audioConfig: cue.audioConfig)
    _ = try await recorder.stop()

    #expect(await spy.startedTempos == [104])
    #expect(await spy.stopCount == 1)
    // The metronome paces; it never turns the walk's own steps into sound.
    #expect(await spy.stepTickCount == 0)
}

// MARK: - The engine

@Test func startingTheMetronomeQueuesBeatsAheadOnTheTimeline() async {
    let service = EngineAudioFeedbackService(logService: MetronomeLog())
    await service.prepare()
    guard await service.isRunning else {
        await service.teardown()
        return
    }

    await service.startMetronome(bpm: 120)

    #expect(await service.isMetronomeRunning)
    // A batch is queued up front rather than one beat at a time.
    #expect(await service.scheduledBeatCount >= 8)

    await service.stopMetronome()
    #expect(await service.isMetronomeRunning == false)

    await service.teardown()
}

@Test func schedulingReusesTheOnePreloadedBeatBuffer() async {
    // No per-tick allocation: every beat is the same buffer, re-scheduled.
    let service = EngineAudioFeedbackService(logService: MetronomeLog())
    await service.prepare()
    guard await service.isRunning else {
        await service.teardown()
        return
    }

    let before = await service.metronomeBuffer
    await service.startMetronome(bpm: 120)
    let during = await service.metronomeBuffer
    await service.startMetronome(bpm: 96)
    let afterRestart = await service.metronomeBuffer

    #expect(before === during)
    #expect(during === afterRestart)

    await service.teardown()
}

@Test func anInterruptionStopsTheBeatAndResumeCostsTheSameWhateverItsLength() async {
    // 7.1.2's machinery drives this; the metronome's part is that it comes back
    // at tempo **from now** [PRD §6]. The observable form of "missed beats are
    // never replayed" is that resuming costs the same whether the call lasted a
    // moment or ten times as long — a catch-up burst would scale with it.
    let service = EngineAudioFeedbackService(logService: MetronomeLog())
    await service.prepare()
    guard await service.isRunning else {
        await service.teardown()
        return
    }

    await service.startMetronome(bpm: 240)

    func interruption(lasting duration: Duration) async -> Int? {
        await service.handle(.interrupted)
        #expect(await service.isMetronomeRunning == false, "the beat survived the interruption")
        let queuedWhileSuspended = await service.scheduledBeatCount

        try? await Task.sleep(for: duration)
        let before = await service.scheduledBeatCount
        #expect(before == queuedWhileSuspended, "beats were queued while suspended")

        await service.handle(.interruptionEnded)
        guard await service.isRunning else { return nil }
        #expect(await service.isMetronomeRunning, "the metronome did not come back")
        return await service.scheduledBeatCount - before
    }

    // At 240 bpm the long interruption covers twenty beats; a replay could not
    // hide inside a batch.
    let shortResume = await interruption(lasting: .milliseconds(500))
    let longResume = await interruption(lasting: .seconds(5))

    if let shortResume, let longResume {
        #expect(
            longResume <= shortResume + Int(8),
            "resume replayed the missed beats: \(shortResume) then \(longResume)"
        )
    } else {
        // Degraded to silence instead — also allowed, never a third state.
        #expect(await service.isDegraded)
    }

    await service.teardown()
}

@Test func aMetronomeRequestBeforePrepareOrAfterTeardownIsSilentNotFatal() async {
    let service = EngineAudioFeedbackService(logService: MetronomeLog())

    await service.startMetronome(bpm: 120)
    #expect(await service.isMetronomeRunning == false)

    await service.prepare()
    await service.teardown()
    await service.startMetronome(bpm: 120)
    await service.stopMetronome()

    #expect(await service.isMetronomeRunning == false)
}

// MARK: - Helpers

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
        logService: MetronomeLog(),
        fileIO: FileManagerFileIO()
    )
}
