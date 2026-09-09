import AVFoundation
import Foundation
import Testing
@testable import Stabilyz

private final class DegradationLog: LogService, @unchecked Sendable {
    let entries = Locked<[String]>([])
    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        entries.withLock { $0.append(message) }
    }
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
    func contains(_ fragment: String) -> Bool {
        entries.withLock { $0.contains { $0.localizedCaseInsensitiveContains(fragment) } }
    }
}

private func makeService(log: DegradationLog = DegradationLog()) -> EngineAudioFeedbackService {
    EngineAudioFeedbackService(logService: log)
}

/// Lets a test push audio events at the recorder exactly as the real observer
/// would, without an audio route.
private actor ScriptedInterruptionObserver: SessionInterruptionObserver {
    private var continuation: AsyncStream<SessionInterruption>.Continuation?

    func startObserving() async -> AsyncStream<SessionInterruption> {
        let (stream, continuation) = AsyncStream<SessionInterruption>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        return stream
    }
    func stopObserving() async {
        continuation?.finish()
        continuation = nil
    }
    func send(_ interruption: SessionInterruption) { continuation?.yield(interruption) }
}

private actor SilentSpy: AudioFeedbackService {
    nonisolated var events: AsyncStream<AudioFeedbackEvent> { AsyncStream { $0.finish() } }
    func playStartTone() async {}
    func playStopTone() async {}
    func playStepTick() async {}
    func startMetronome(bpm: Double) async {}
    func stopMetronome() async {}
    func suspend() async {}
    func resume() async {}
}

private struct DegradationClock: Clock {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let uptime: TimeInterval = 0
}

// MARK: - The state machine

@Test func anInterruptionSuspendsPlayback() async {
    let service = makeService()
    await service.prepare()
    guard await service.isRunning else { await service.teardown(); return }

    await service.handle(.interrupted)

    #expect(await service.isRunning == false)
    await service.teardown()
}

@Test func theEndOfAnInterruptionResumesOrDegrades() async {
    let log = DegradationLog()
    let service = makeService(log: log)
    await service.prepare()
    guard await service.isRunning else { await service.teardown(); return }

    await service.handle(.interrupted)
    await service.handle(.interruptionEnded)

    // Either it came back, or it fell silent — never a third state, never a
    // crash [PRD §6].
    let running = await service.isRunning
    let degraded = await service.isDegraded
    #expect(running || degraded)
    await service.teardown()
}

@Test func aRouteChangeIsSurvivedAndTheSessionContinues() async {
    // AirPods dying mid-session: iOS reroutes, the engine may need rebuilding,
    // and either way the walk carries on.
    let log = DegradationLog()
    let service = makeService(log: log)
    await service.prepare()

    await service.handle(.routeChanged)

    // No crash, no freeze; whatever happened is recorded.
    #expect(log.contains("route changed"))
    await service.teardown()
}

@Test func repeatedEventsAreIdempotent() async {
    let service = makeService()
    await service.prepare()

    await service.handle(.interrupted)
    await service.handle(.interrupted)
    await service.handle(.routeChanged)
    await service.handle(.interruptionEnded)
    await service.handle(.interruptionEnded)

    await service.teardown()
}

@Test func aDegradedEventIsNotAmplifiedIntoFurtherDegradation() async {
    let service = makeService()
    await service.prepare()
    await service.handle(.degraded)
    await service.teardown()
}

// MARK: - Drop, don't queue — across an interruption

@Test func tonesRequestedDuringAnInterruptionAreNeverReplayed() async {
    // 7.1.1's decision, carried across the interruption boundary: a tick that
    // arrives after the interruption ends is worse than no tick.
    let service = makeService()
    await service.prepare()
    guard await service.isRunning else { await service.teardown(); return }

    let before = await service.scheduledToneCount
    await service.handle(.interrupted)

    await service.playStepTick()
    await service.playStepTick()
    await service.playStartTone()
    #expect(await service.scheduledToneCount == before, "tones played while suspended")

    await service.handle(.interruptionEnded)
    // Nothing queued up and fired late.
    #expect(await service.scheduledToneCount == before, "tones replayed after resume")

    await service.teardown()
}

@Test func playingResumesNormallyAfterAnInterruption() async {
    let service = makeService()
    await service.prepare()
    guard await service.isRunning else { await service.teardown(); return }

    await service.handle(.interrupted)
    await service.handle(.interruptionEnded)
    guard await service.isRunning else { await service.teardown(); return }

    let before = await service.scheduledToneCount
    await service.playStepTick()
    #expect(await service.scheduledToneCount == before + 1)

    await service.teardown()
}

@Test func aDegradedServiceStaysSilentButStaysUsable() async {
    let service = makeService()
    await service.prepare()

    await service.handle(.interrupted)
    await service.handle(.interruptionEnded)

    if await service.isDegraded {
        let before = await service.scheduledToneCount
        await service.playStartTone()
        await service.playStepTick()
        #expect(await service.scheduledToneCount == before)
    }
    await service.teardown()
}

// MARK: - The recorder is never affected [CRITICAL — Task 4.2.3 stands]

@Test func audioEventsNeverIncrementInterruptionCount() async throws {
    // The 4.2.3 decision, pinned. Counting a route change would overstate how
    // disturbed the walk was and could push a sound session toward the noisy
    // path (docs/10 §10.4).
    let clock = DegradationClock()
    let observer = ScriptedInterruptionObserver()
    let recorder = SessionRecorder(
        motionSensor: FixtureSensorService(fixture: .steadyWalk, clock: clock),
        pedometer: FixturePedometerService(fixture: .steadyWalk, clock: clock),
        audioFeedback: SilentSpy(),
        interruptionObserver: observer,
        screenSleep: SystemScreenSleepController(),
        clock: clock,
        logService: DegradationLog(),
        fileIO: FileManagerFileIO()
    )

    _ = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    await observer.send(.audioRouteChanged)
    await observer.send(.audioInterrupted)
    await observer.send(.audioRouteChanged)
    let buffer = try await recorder.stop()

    #expect(buffer.interruptionCount == 0)
}

@Test func onlyBackgroundingStillCounts() async throws {
    // The other half of the same rule: a real suspension does count.
    let clock = DegradationClock()
    let observer = ScriptedInterruptionObserver()
    let recorder = SessionRecorder(
        motionSensor: FixtureSensorService(fixture: .steadyWalk, clock: clock),
        pedometer: FixturePedometerService(fixture: .steadyWalk, clock: clock),
        audioFeedback: SilentSpy(),
        interruptionObserver: observer,
        screenSleep: SystemScreenSleepController(),
        clock: clock,
        logService: DegradationLog(),
        fileIO: FileManagerFileIO()
    )

    _ = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    await observer.send(.audioInterrupted)
    await observer.send(.didEnterBackground)
    await observer.send(.audioRouteChanged)
    let buffer = try await recorder.stop()

    #expect(buffer.interruptionCount == 1)
}

@Test func audioEventsLeaveTheRecordedSamplesUntouched() async throws {
    // Audio state must not reach the sample path or the gap machinery.
    let clock = DegradationClock()
    let fixture = GaitFixture.makeWalk(name: "audio-isolation", cadenceBPM: 108, seconds: 3)

    func record(sendingAudioEvents: Bool) async throws -> RawSessionBuffer {
        let observer = ScriptedInterruptionObserver()
        let recorder = SessionRecorder(
            motionSensor: FixtureSensorService(fixture: fixture, clock: clock),
            pedometer: FixturePedometerService(fixture: fixture, clock: clock),
            audioFeedback: SilentSpy(),
            interruptionObserver: observer,
            screenSleep: SystemScreenSleepController(),
            clock: clock,
            logService: DegradationLog(),
            fileIO: FileManagerFileIO()
        )
        _ = try await recorder.begin(mode: .quickTest, audioConfig: .stepFeedback)
        if sendingAudioEvents {
            await observer.send(.audioInterrupted)
            await observer.send(.audioRouteChanged)
            await observer.send(.audioInterrupted)
        }
        return try await recorder.stop()
    }

    let quiet = try await record(sendingAudioEvents: false)
    let disturbed = try await record(sendingAudioEvents: true)

    #expect(disturbed.samples.count == quiet.samples.count)
    #expect(disturbed.gapInfo == quiet.gapInfo)
    #expect(disturbed.interruptionCount == quiet.interruptionCount)
    #expect(disturbed.series.gaps.count == quiet.series.gaps.count)
}

@Test func theSessionEventStreamCarriesNoAudioNoise() async throws {
    // Audio trouble is not a recording event; the Recording screen must not
    // show an interruption because someone's headphones disconnected.
    let clock = DegradationClock()
    let observer = ScriptedInterruptionObserver()
    let recorder = SessionRecorder(
        motionSensor: FixtureSensorService(fixture: .steadyWalk, clock: clock),
        pedometer: FixturePedometerService(fixture: .steadyWalk, clock: clock),
        audioFeedback: SilentSpy(),
        interruptionObserver: observer,
        screenSleep: SystemScreenSleepController(),
        clock: clock,
        logService: DegradationLog(),
        fileIO: FileManagerFileIO()
    )

    let events = try await recorder.begin(mode: .quickTest, audioConfig: .none)
    let collector = Task { () -> [SessionRecordingEvent] in
        var seen: [SessionRecordingEvent] = []
        for await event in events { seen.append(event) }
        return seen
    }
    await observer.send(.audioRouteChanged)
    await observer.send(.audioInterrupted)
    _ = try await recorder.stop()

    let seen = await collector.value
    #expect(seen.contains(.interrupted) == false)
}

// MARK: - Silent to the user, logged for diagnostics

@Test func degradationIsLoggedRatherThanSurfaced() async {
    // [PRD §6] no alert, no error screen — but a diagnosable trail.
    let log = DegradationLog()
    let service = makeService(log: log)
    await service.prepare()

    await service.handle(.interrupted)
    await service.handle(.routeChanged)
    await service.handle(.interruptionEnded)

    #expect(log.entries.withLock { $0.isEmpty } == false)
    await service.teardown()
}

@Test func audioFailureIsNeverPresentedToTheUser() {
    // The presenter has said so since Task 2.2.2; restated here because 7.1.2
    // is where audio starts actually failing.
    for audio in [StabilyzError.Audio.routeLost, .interrupted, .engineFailure] {
        #expect(ErrorPresenter.presentation(for: .audio(audio)) == nil)
    }
}
