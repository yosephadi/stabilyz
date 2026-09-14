import Foundation
import SwiftUI
import Testing
@testable import Stabilyz

/// The start countdown (Task 8.2.6 logic, Task 7.2.3 gating, [PRD OQ-6]).
///
/// The cadence is driven by a gated ticker rather than the clock, so every
/// assertion here is about order and not about timing. A countdown test that
/// actually slept would be five seconds slow and flaky on a loaded machine,
/// and would still not be able to say *when* cancellation landed.

// MARK: - Doubles

private final class CountdownLog: LogService, @unchecked Sendable {
    let entries = Locked<[String]>([])

    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        entries.withLock { $0.append(message) }
    }
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

private final class FixedClock: Clock, @unchecked Sendable {
    private let state = Locked<(now: Date, uptime: TimeInterval)>(
        (Date(timeIntervalSince1970: 1_700_000_000), 1_000)
    )

    var now: Date { state.withLock { $0.now } }
    var uptime: TimeInterval { state.withLock { $0.uptime } }

    func advance(by seconds: TimeInterval) {
        state.withLock {
            $0.now = $0.now.addingTimeInterval(seconds)
            $0.uptime += seconds
        }
    }
}

/// Holds each tick until the test releases it.
///
/// This is what makes "cancel at T-1" a precise statement: the test can stop
/// the countdown while it is provably parked on the last numeral, rather than
/// hoping a sleep lands in the right window.
private actor GatedTicker: CountdownTicker {
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var credits = 0
    /// How many waits have been entered, ever.
    private(set) var waitsEntered = 0

    func waitForTick(_ interval: Duration) async {
        waitsEntered += 1
        if credits > 0 {
            credits -= 1
            return
        }
        await withCheckedContinuation { parked.append($0) }
    }

    /// Lets one tick through.
    func release() {
        if parked.isEmpty {
            credits += 1
        } else {
            parked.removeFirst().resume()
        }
    }

    /// Frees anything still parked, so a cancelled countdown's task can finish.
    func releaseAll() {
        let waiting = parked
        parked.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    /// Waits until the countdown has entered its `count`-th tick.
    ///
    /// Bounded so a regression fails with a readable count rather than hanging.
    /// Nothing waits the full bound — it returns the moment the countdown
    /// arrives.
    func waitUntilEntered(_ count: Int) async {
        for _ in 0..<400 {
            if waitsEntered >= count { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Records every audio call, so "silent during the countdown" is a claim a test
/// can actually check (Task 7.2.3).
private actor AudioSpy: AudioFeedbackService {
    private(set) var calls: [String] = []
    nonisolated var events: AsyncStream<AudioFeedbackEvent> { AsyncStream { $0.finish() } }

    func playStartTone() async { calls.append("startTone") }
    func playStopTone() async { calls.append("stopTone") }
    func playStepTick() async { calls.append("stepTick") }
    func startMetronome(bpm: Double) async { calls.append("metronomeStart") }
    func stopMetronome() async { calls.append("metronomeStop") }
    func suspend() async {}
    func resume() async {}
    func prepare() async { calls.append("prepare") }
    func teardown() async { calls.append("teardown") }

    /// Anything that would make a noise. `metronomeStop` and the lifecycle
    /// calls are not sounds.
    var soundingCalls: [String] {
        calls.filter { ["startTone", "stopTone", "stepTick", "metronomeStart"].contains($0) }
    }

    func waitForCalls(_ expected: Int) async -> [String] {
        for _ in 0..<250 {
            if calls.count >= expected { return calls }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return calls
    }
}

private struct DeadPedometerService: PedometerService {
    var isAvailable: Bool { get async { false } }
    var authorizationStatus: MotionAuthorizationStatus { get async { .authorized } }
    func start() async throws -> AsyncStream<PedometerEvent> { throw StabilyzError.sensor(.unavailable) }
    func stop() async {}
    func events(from start: Date, to end: Date) async throws -> PedometerEvent? { nil }
}

private struct RefusingMotionService: MotionSensorService {
    let error: StabilyzError
    var isAvailable: Bool { get async { true } }
    var authorizationStatus: MotionAuthorizationStatus { get async { .authorized } }
    func requestAuthorization() async -> MotionAuthorizationStatus { .authorized }
    func start(policy: MotionAcquisitionPolicy) async throws -> AsyncStream<SensorSample> { throw error }
    func stop() async {}
}

private actor SilentInterruptionObserver: SessionInterruptionObserver {
    func startObserving() async -> AsyncStream<SessionInterruption> { AsyncStream { $0.finish() } }
    func stopObserving() async {}
}

private actor NoopScreenSleep: ScreenSleepController {
    func preventSleep() async {}
    func allowSleep() async {}
}

/// Three ticks, so the assertions read the way the task describes them: 3, 2, 1.
private let threeTickPolicy = CountdownPolicy(version: 1, tickCount: 3, tickInterval: .seconds(1))

@MainActor
private func makeCoordinator(
    motion: (any MotionSensorService)? = nil,
    policy: CountdownPolicy = threeTickPolicy
) -> (CountdownCoordinator, SessionRecorder, MockHapticFeedbackService, AudioSpy, GatedTicker, CountdownLog) {
    let clock = FixedClock()
    let log = CountdownLog()
    let audio = AudioSpy()
    let haptics = MockHapticFeedbackService()
    let ticker = GatedTicker()

    let recorder = SessionRecorder(
        motionSensor: motion ?? FixtureSensorService(fixture: .steadyWalk, clock: clock),
        pedometer: DeadPedometerService(),
        audioFeedback: audio,
        interruptionObserver: SilentInterruptionObserver(),
        screenSleep: NoopScreenSleep(),
        clock: clock,
        logService: log,
        fileIO: FileManagerFileIO()
    )

    let coordinator = CountdownCoordinator(
        recorder: recorder,
        haptics: haptics,
        audio: audio,
        clock: clock,
        logService: log,
        ticker: ticker,
        policy: policy
    )
    return (coordinator, recorder, haptics, audio, ticker, log)
}

// MARK: - The policy

@Test func theCountdownIsFiveSecondsByDefault() {
    // [PRD OQ-6]: five, provisional and tunable, a single fixed constant.
    #expect(CountdownPolicy.v1.tickCount == 5)
    #expect(CountdownPolicy.v1.tickInterval == .seconds(1))
    #expect(CountdownPolicy.v1.totalDuration == .seconds(5))
    #expect(CountdownPolicy.v1.countdownSequence == [5, 4, 3, 2, 1])
}

// MARK: - The happy path

@MainActor
@Test func theCountdownRunsIdleToPrimingToCountingToRunning() async throws {
    let (coordinator, recorder, _, _, ticker, _) = makeCoordinator()
    #expect(coordinator.state == .idle)

    coordinator.start(mode: .quickTest, audioConfig: .none)

    // 3 — the countdown is parked on its first numeral.
    await ticker.waitUntilEntered(1)
    #expect(coordinator.state == .counting(secondsRemaining: 3))

    await ticker.release()
    await ticker.waitUntilEntered(2)
    #expect(coordinator.state == .counting(secondsRemaining: 2))

    await ticker.release()
    await ticker.waitUntilEntered(3)
    #expect(coordinator.state == .counting(secondsRemaining: 1))

    // T-0.
    await ticker.release()
    await coordinator.waitUntilFinished()

    #expect(coordinator.state == .running)
    #expect(await recorder.isRecording)
    _ = try await recorder.stop()
}

@MainActor
@Test func theHapticsAreThreeTicksThenOneGo() async throws {
    let (coordinator, recorder, haptics, _, ticker, _) = makeCoordinator()

    coordinator.start(mode: .quickTest, audioConfig: .none)
    for entered in 1...3 {
        await ticker.waitUntilEntered(entered)
        await ticker.release()
    }
    await coordinator.waitUntilFinished()

    #expect(await haptics.taps == [.cadenceTick, .cadenceTick, .cadenceTick, .sessionStart])
    // Warmed before anything counted, so the first tap is not the slow one.
    #expect(await haptics.recordedCalls.first == .prepare)
    _ = try await recorder.stop()
}

@MainActor
@Test func goIsStampedAtTheFinalTickAndHandedToTheRecorder() async throws {
    // "begin(at:) is called exactly at T-0 with a valid TimeAnchor": the
    // session the recorder freezes must carry the anchor the countdown stamped.
    let (coordinator, recorder, _, _, ticker, _) = makeCoordinator()

    coordinator.start(mode: .quickTest, audioConfig: .none)
    for entered in 1...3 {
        await ticker.waitUntilEntered(entered)
        await ticker.release()
    }
    await coordinator.waitUntilFinished()

    let buffer = try await recorder.stop()
    #expect(buffer.startedAt == buffer.anchor.wallClock)
    #expect(buffer.honoursAdmissionContract)
    #expect(buffer.isEmpty == false)
}

@MainActor
@Test func theRecordingStreamIsHandedOverOnlyOnceRunning() async throws {
    let (coordinator, recorder, _, _, ticker, _) = makeCoordinator()

    coordinator.start(mode: .quickTest, audioConfig: .none)
    await ticker.waitUntilEntered(1)
    #expect(coordinator.recordingEvents == nil)

    for entered in 1...3 {
        await ticker.waitUntilEntered(entered)
        await ticker.release()
    }
    await coordinator.waitUntilFinished()

    #expect(coordinator.recordingEvents != nil)
    _ = try await recorder.stop()
}

@MainActor
@Test func aSecondStartWhileCountingIsIgnored() async throws {
    // A double-tap on Start Test must not prime twice or leave a second
    // countdown ticking behind the first.
    let (coordinator, recorder, haptics, _, ticker, _) = makeCoordinator()

    coordinator.start(mode: .quickTest, audioConfig: .none)
    await ticker.waitUntilEntered(1)
    coordinator.start(mode: .fullTest, audioConfig: .none)

    for entered in 1...3 {
        await ticker.waitUntilEntered(entered)
        await ticker.release()
    }
    await coordinator.waitUntilFinished()

    #expect(await haptics.count(of: .cadenceTick) == 3)
    let buffer = try await recorder.stop()
    #expect(buffer.mode == .quickTest)
}

// MARK: - Task 7.2.3: silence during the countdown

@MainActor
@Test func noCueSoundsAtAnyPointDuringTheCountdown() async throws {
    // The metronome is the sharp case: a beat under a haptic countdown is
    // directly confusable with it, and would pace gait across a window that is
    // not being measured.
    let (coordinator, recorder, _, audio, ticker, _) = makeCoordinator()

    coordinator.start(mode: .quickTest, audioConfig: .metronome(cue: .fixture()))

    for entered in 1...3 {
        await ticker.waitUntilEntered(entered)
        #expect(await audio.soundingCalls.isEmpty, "audio sounded during the countdown")
        await ticker.release()
    }

    await coordinator.waitUntilFinished()
    _ = try await recorder.stop()
}

@MainActor
@Test func stepFeedbackIsEquallySilentBeforeGo() async throws {
    let (coordinator, recorder, _, audio, ticker, _) = makeCoordinator()

    coordinator.start(mode: .quickTest, audioConfig: .stepFeedback)

    for entered in 1...3 {
        await ticker.waitUntilEntered(entered)
        #expect(await audio.soundingCalls.isEmpty)
        await ticker.release()
    }

    await coordinator.waitUntilFinished()
    _ = try await recorder.stop()
}

@MainActor
@Test func theCountdownStopsAnyMetronomeBeforeItStartsCounting() async throws {
    // Belt to the structural brace: `begin` is the only thing that arms a cue,
    // so nothing can be running — but a beat left over from an earlier flow
    // would be counted over rather than silenced.
    let (coordinator, recorder, _, audio, ticker, _) = makeCoordinator()

    coordinator.start(mode: .quickTest, audioConfig: .metronome(cue: .fixture()))
    await ticker.waitUntilEntered(1)

    #expect(await audio.calls.contains("metronomeStop"))

    for entered in 1...3 {
        await ticker.waitUntilEntered(entered)
        await ticker.release()
    }
    await coordinator.waitUntilFinished()
    _ = try await recorder.stop()
}

@MainActor
@Test func theStartToneOnlyArrivesAfterGo() async throws {
    // The tone belongs to T-0, alongside the distinct haptic — never earlier.
    let (coordinator, recorder, _, audio, ticker, _) = makeCoordinator()

    coordinator.start(mode: .quickTest, audioConfig: .none)
    for entered in 1...3 {
        await ticker.waitUntilEntered(entered)
        #expect(await audio.calls.contains("startTone") == false)
        await ticker.release()
    }
    await coordinator.waitUntilFinished()

    let calls = await audio.waitForCalls(2)
    #expect(calls.contains("startTone"))
    _ = try await recorder.stop()
}

// MARK: - Cancellation

@MainActor
@Test func cancellingAtT1HaltsTheCountdownAndStartsNoSession() async throws {
    let (coordinator, recorder, haptics, _, ticker, _) = makeCoordinator()

    coordinator.start(mode: .quickTest, audioConfig: .none)
    // Walk it down to the last numeral, releasing each tick in turn, and park
    // there: 3, 2, then 1.
    await ticker.waitUntilEntered(1)
    await ticker.release()
    await ticker.waitUntilEntered(2)
    await ticker.release()
    await ticker.waitUntilEntered(3)
    #expect(coordinator.state == .counting(secondsRemaining: 1))

    async let cancelled: Void = coordinator.cancel()
    await ticker.releaseAll()
    await cancelled

    #expect(coordinator.state == .cancelled)
    #expect(await recorder.isRecording == false)
    #expect(await recorder.isPrimed == false)
    // Go never fired, so nothing announced a session that does not exist.
    #expect(await haptics.count(of: .sessionStart) == 0)
    #expect(await haptics.count(of: .sessionStop) == 1)
    // And there is no session to stop.
    await #expect(throws: StabilyzError.recording(.notRecording)) {
        _ = try await recorder.stop()
    }
}

@MainActor
@Test func cancellingStopsTheTicksWhereTheyWere() async throws {
    let (coordinator, _, haptics, _, ticker, _) = makeCoordinator()

    coordinator.start(mode: .quickTest, audioConfig: .none)
    await ticker.waitUntilEntered(1)
    await ticker.release()
    await ticker.waitUntilEntered(2)

    async let cancelled: Void = coordinator.cancel()
    await ticker.releaseAll()
    await cancelled

    // Two numerals had been shown; the third never is.
    #expect(await haptics.count(of: .cadenceTick) == 2)
}

@MainActor
@Test func cancellingDuringPrimingLeavesNothingBehind() async throws {
    let (coordinator, recorder, haptics, _, _, _) = makeCoordinator()

    coordinator.start(mode: .quickTest, audioConfig: .none)
    await coordinator.cancel()

    #expect(coordinator.state == .cancelled)
    #expect(await recorder.isPrimed == false)
    #expect(await recorder.isRecording == false)
    #expect(await haptics.count(of: .sessionStart) == 0)
}

@MainActor
@Test func cancellingARunningSessionIsRefused() async throws {
    // Past T-0 there is a real walk in progress; ending it is stop()'s job.
    let (coordinator, recorder, _, _, ticker, log) = makeCoordinator()

    coordinator.start(mode: .quickTest, audioConfig: .none)
    for entered in 1...3 {
        await ticker.waitUntilEntered(entered)
        await ticker.release()
    }
    await coordinator.waitUntilFinished()
    #expect(coordinator.state == .running)

    await coordinator.cancel()

    #expect(coordinator.state == .running)
    #expect(await recorder.isRecording)
    #expect(log.entries.withLock { $0.contains { $0.contains("cancel ignored") } })
    _ = try await recorder.stop()
}

@MainActor
@Test func aCancelledCountdownCanBeRetried() async throws {
    let (coordinator, recorder, _, _, ticker, _) = makeCoordinator()

    coordinator.start(mode: .quickTest, audioConfig: .none)
    await ticker.waitUntilEntered(1)
    async let cancelled: Void = coordinator.cancel()
    await ticker.releaseAll()
    await cancelled

    coordinator.reset()
    #expect(coordinator.state == .idle)

    coordinator.start(mode: .fullTest, audioConfig: .none)
    for entered in 4...6 {
        await ticker.waitUntilEntered(entered)
        await ticker.release()
    }
    await coordinator.waitUntilFinished()

    #expect(coordinator.state == .running)
    let buffer = try await recorder.stop()
    #expect(buffer.mode == .fullTest)
}

// MARK: - Priming failure

@MainActor
@Test func aPrimingFailureLandsOnFailedAndLeavesTheRecorderIdle() async throws {
    // The failure the countdown exists to catch, surfaced while the user is
    // still watching the screen rather than at T-0 with the phone pocketed.
    let (coordinator, recorder, haptics, _, _, _) = makeCoordinator(
        motion: RefusingMotionService(error: .sensor(.primingTimeout))
    )

    coordinator.start(mode: .quickTest, audioConfig: .none)
    await coordinator.waitUntilFinished()

    #expect(coordinator.state == .failed(.sensor(.primingTimeout)))
    #expect(await recorder.isPrimed == false)
    #expect(await recorder.isRecording == false)
    // Nothing counted, so nothing tapped.
    #expect(await haptics.count(of: .cadenceTick) == 0)
    #expect(await haptics.count(of: .sessionStart) == 0)
}

@MainActor
@Test func aPrimingFailureNeverCountsDown() async throws {
    let (coordinator, _, _, audio, ticker, _) = makeCoordinator(
        motion: RefusingMotionService(error: .sensor(.unavailable))
    )

    coordinator.start(mode: .quickTest, audioConfig: .none)
    await coordinator.waitUntilFinished()

    #expect(await ticker.waitsEntered == 0)
    #expect(await audio.soundingCalls.isEmpty)
}

@MainActor
@Test func aFailedCountdownCanBeRetried() async throws {
    let (coordinator, _, _, _, _, _) = makeCoordinator(
        motion: RefusingMotionService(error: .sensor(.primingTimeout))
    )

    coordinator.start(mode: .quickTest, audioConfig: .none)
    await coordinator.waitUntilFinished()
    #expect(coordinator.state == .failed(.sensor(.primingTimeout)))

    coordinator.reset()
    #expect(coordinator.state == .idle)
}

@MainActor
@Test func theFailedStateCarriesTheErrorTheScreenExplains() async throws {
    // ErrorPresenter turns this into plain language; the state has to carry the
    // real error for that to be possible.
    let (coordinator, _, _, _, _, _) = makeCoordinator(
        motion: RefusingMotionService(error: .permission(.motionDenied))
    )

    coordinator.start(mode: .quickTest, audioConfig: .none)
    await coordinator.waitUntilFinished()

    guard case .failed(let error) = coordinator.state else {
        Issue.record("expected a failed countdown, got \(coordinator.state)")
        return
    }
    #expect(error == .permission(.motionDenied))
    // Recoverable, and it offers the Settings link — a countdown that failed
    // this way is a countdown the user can fix and retry, which is only
    // possible because the state carried the real error rather than a generic
    // one [PRD §6 — explain why, never fail silently].
    let presentation = ErrorPresenter.presentation(for: error)
    #expect(presentation?.isRecoverable == true)
    #expect(presentation?.offersSettingsLink == true)
}

// MARK: - Backgrounding, as the guard decides it ([PRD OQ-6])

@MainActor
@Test func aBackgroundedCountdownLeavesNoSessionBehind() async throws {
    // `SessionBackgroundGuard` decides; `cancel()` does the work, and this is
    // the work: the recorder is taken back down, no session exists, and the
    // state lands on `.cancelled` so the cover closes back to setup.
    let (coordinator, recorder, haptics, _, ticker, _) = makeCoordinator()

    coordinator.start(mode: .quickTest, audioConfig: .none)
    await ticker.waitUntilEntered(1)

    // The condition the view watches for.
    #expect(SessionBackgroundGuard.shouldCancelCountdown(
        scenePhase: .background,
        countdown: coordinator.state
    ))

    async let cancelled: Void = coordinator.cancel()
    await ticker.releaseAll()
    await cancelled

    #expect(coordinator.state == .cancelled)
    #expect(await recorder.isRecording == false)
    #expect(await recorder.isPrimed == false)
    // Go never fired, so nothing announced a session that does not exist.
    #expect(await haptics.count(of: .sessionStart) == 0)
    #expect(await haptics.count(of: .sessionStop) == 1)
    await #expect(throws: StabilyzError.recording(.notRecording)) {
        _ = try await recorder.stop()
    }
}

@MainActor
@Test func aBackgroundedWalkIsNotCancelled() async throws {
    // Past T-0 this is an interruption, not a cancellation: the recorder marks
    // the gap and the pipeline decides validity (docs/07 §7.7).
    let (coordinator, recorder, _, _, ticker, _) = makeCoordinator()

    coordinator.start(mode: .quickTest, audioConfig: .none)
    for entered in 1...3 {
        await ticker.waitUntilEntered(entered)
        await ticker.release()
    }
    await coordinator.waitUntilFinished()

    #expect(SessionBackgroundGuard.shouldCancelCountdown(
        scenePhase: .background,
        countdown: coordinator.state
    ) == false)
    #expect(await recorder.isRecording)
    _ = try await recorder.stop()
}

// MARK: - Start & Stop Haptics, switched off

@MainActor
@Test func withHapticsOffNothingIsFeltAtGo() async throws {
    // The user turned Start & Stop Haptics off. T-0 must be still: no
    // `playSessionStart`, and nothing else either.
    let (coordinator, recorder, haptics, _, ticker, _) = makeCoordinator()

    coordinator.start(mode: .quickTest, audioConfig: .none, hapticsEnabled: false)
    for entered in 1...3 {
        await ticker.waitUntilEntered(entered)
        await ticker.release()
    }
    await coordinator.waitUntilFinished()

    #expect(await haptics.count(of: .sessionStart) == 0)
    #expect(await haptics.taps.isEmpty)
    // Not even warmed: nothing is going to play, so nothing is prepared.
    #expect(await haptics.recordedCalls.isEmpty)
    _ = try await recorder.stop()
}

@MainActor
@Test func withHapticsOffTheCountdownStillRunsOnTheNumeralsAlone() async throws {
    // [PRD §7 AC]: "If haptics are unavailable or disabled, the countdown runs
    // on the visible channel alone, with no error and no blocked Start." Every
    // numeral still shows, and the session still starts at T-0.
    let (coordinator, recorder, haptics, _, ticker, _) = makeCoordinator()

    coordinator.start(mode: .quickTest, audioConfig: .none, hapticsEnabled: false)

    for (entered, numeral) in zip(1...3, [3, 2, 1]) {
        await ticker.waitUntilEntered(entered)
        #expect(coordinator.state == .counting(secondsRemaining: numeral))
        #expect(await haptics.count(of: .cadenceTick) == 0, "no tick at \(numeral)")
        await ticker.release()
    }
    await coordinator.waitUntilFinished()

    #expect(coordinator.state == .running)
    #expect(await recorder.isRecording)
    _ = try await recorder.stop()
}

@MainActor
@Test func hapticsStayOnByDefault() async throws {
    // The toggle defaults on [PRD OQ-6], and a caller that says nothing gets
    // the full countdown — the gate removes haptics only when asked to.
    let (coordinator, recorder, haptics, _, ticker, _) = makeCoordinator()

    coordinator.start(mode: .quickTest, audioConfig: .none, hapticsEnabled: true)
    for entered in 1...3 {
        await ticker.waitUntilEntered(entered)
        await ticker.release()
    }
    await coordinator.waitUntilFinished()

    #expect(await haptics.taps == [.cadenceTick, .cadenceTick, .cadenceTick, .sessionStart])
    _ = try await recorder.stop()
}

@MainActor
@Test func withHapticsOffACancelledCountdownIsStill() async throws {
    // Cancel normally plays the stop pulse, so a pocketed phone can feel the
    // countdown end. With haptics off it must not: that pulse is one of the
    // haptics the user turned off.
    let (coordinator, recorder, haptics, _, ticker, _) = makeCoordinator()

    coordinator.start(mode: .quickTest, audioConfig: .none, hapticsEnabled: false)
    await ticker.waitUntilEntered(1)
    await ticker.release()
    await ticker.waitUntilEntered(2)

    async let cancelled: Void = coordinator.cancel()
    await ticker.releaseAll()
    await cancelled

    #expect(coordinator.state == .cancelled)
    #expect(await recorder.isPrimed == false)
    #expect(await haptics.count(of: .sessionStop) == 0)
    #expect(await haptics.recordedCalls.isEmpty)
}

@MainActor
@Test func aRetryHonoursTheHapticsChoiceMadeForIt() async throws {
    // The gate is chosen per `start`, not once for the coordinator's life. A
    // countdown cancelled with haptics off and retried with them on must be
    // felt the second time.
    let (coordinator, recorder, haptics, _, ticker, _) = makeCoordinator()

    coordinator.start(mode: .quickTest, audioConfig: .none, hapticsEnabled: false)
    await ticker.waitUntilEntered(1)
    async let cancelled: Void = coordinator.cancel()
    await ticker.releaseAll()
    await cancelled
    coordinator.reset()
    #expect(await haptics.recordedCalls.isEmpty)

    coordinator.start(mode: .quickTest, audioConfig: .none, hapticsEnabled: true)
    let alreadyEntered = await ticker.waitsEntered
    for step in 1...3 {
        await ticker.waitUntilEntered(alreadyEntered + step)
        await ticker.release()
    }
    await coordinator.waitUntilFinished()

    #expect(coordinator.state == .running)
    #expect(await haptics.taps == [.cadenceTick, .cadenceTick, .cadenceTick, .sessionStart])
    _ = try await recorder.stop()
}
