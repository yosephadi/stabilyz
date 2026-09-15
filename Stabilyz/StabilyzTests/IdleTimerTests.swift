import Foundation
import Testing
import UIKit
@testable import Stabilyz

/// The screen stays awake from the countdown to the end of the walk, and is
/// handed back on every way out (Task 8.2.6, docs/07 §7.7, [PRD OQ-6]).
///
/// `SessionRecorderTests` pins the recorder's half: `prime()` holds the idle
/// timer down, and `stop()`, `abort()` and a failed priming release it. This
/// suite pins the controller that actually sets
/// `UIApplication.isIdleTimerDisabled`, and the countdown coordinator's paths
/// through the recorder — start, cancel, Go, and a priming failure.
///
/// Releasing at `stop()` is releasing at the end of every walk, valid or
/// unclear: the recorder stops before the pipeline decides which it was.

// MARK: - Doubles

/// The idle timer, in a box a test owns.
@MainActor
private final class IdleTimerStandIn: IdleTimerHost {
    var isIdleTimerDisabled = false
}

private actor IdleTimerSpy: ScreenSleepController {
    private(set) var calls: [String] = []

    func preventSleep() async { calls.append("prevent") }
    func allowSleep() async { calls.append("allow") }

    /// Held down right now: the last word was "prevent".
    var isHeldDown: Bool { calls.last == "prevent" }
}

private actor QuietInterruptions: SessionInterruptionObserver {
    func startObserving() async -> AsyncStream<SessionInterruption> { AsyncStream { $0.finish() } }
    func stopObserving() async {}
}

private final class QuietLog: LogService, @unchecked Sendable {
    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {}
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

/// A countdown tick that waits for the test to let it through.
private actor HeldTicker: CountdownTicker {
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var credits = 0
    private(set) var waitsEntered = 0

    func waitForTick(_ interval: Duration) async {
        waitsEntered += 1
        if credits > 0 {
            credits -= 1
            return
        }
        await withCheckedContinuation { parked.append($0) }
    }

    func release() {
        if parked.isEmpty { credits += 1 } else { parked.removeFirst().resume() }
    }

    func releaseAll() {
        let waiting = parked
        parked.removeAll()
        credits += 100
        for continuation in waiting { continuation.resume() }
    }

    func waitUntilEntered(_ count: Int) async {
        for _ in 0..<400 where waitsEntered < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Authorised and present, but never delivers.
private struct SilentSensor: MotionSensorService {
    var isAvailable: Bool { get async { true } }
    var authorizationStatus: MotionAuthorizationStatus { get async { .authorized } }
    func requestAuthorization() async -> MotionAuthorizationStatus { .authorized }
    func start(policy: MotionAcquisitionPolicy) async throws -> AsyncStream<SensorSample> {
        throw StabilyzError.sensor(.primingTimeout)
    }
    func stop() async {}
}

@MainActor
private func makeCountdown(
    motion: (any MotionSensorService)? = nil,
    spy: IdleTimerSpy,
    ticker: HeldTicker
) -> (CountdownCoordinator, SessionRecorder) {
    let clock = FixedStoreClock()
    let recorder = SessionRecorder(
        motionSensor: motion ?? FixtureSensorService(fixture: .steadyWalk, clock: clock),
        pedometer: FixturePedometerService(fixture: .steadyWalk, clock: clock),
        audioFeedback: SilentAudioFeedbackService(),
        interruptionObserver: QuietInterruptions(),
        screenSleep: spy,
        clock: clock,
        logService: QuietLog(),
        fileIO: FileManagerFileIO()
    )
    let coordinator = CountdownCoordinator(
        recorder: recorder,
        haptics: SilentHapticFeedbackService(),
        audio: SilentAudioFeedbackService(),
        clock: clock,
        logService: QuietLog(),
        ticker: ticker,
        policy: CountdownPolicy(version: 1, tickCount: 3, tickInterval: .seconds(1))
    )
    return (coordinator, recorder)
}

// MARK: - The controller

@MainActor
@Test func theSystemControllerHoldsTheIdleTimerDownAndHandsItBack() async {
    let standIn = IdleTimerStandIn()
    let controller = SystemScreenSleepController(host: { standIn })

    await controller.preventSleep()
    #expect(standIn.isIdleTimerDisabled)

    await controller.allowSleep()
    #expect(standIn.isIdleTimerDisabled == false)
}

@MainActor
@Test func withoutAStandInTheControllerHoldsTheRunningAppsIdleTimer() {
    let host = SystemScreenSleepController.runningApplication()
    #expect(host === UIApplication.shared)
}

// MARK: - Through the countdown

@MainActor
@Test func theScreenIsHeldFromTheFirstNumeralAndACancelHandsItBack() async {
    let spy = IdleTimerSpy()
    let ticker = HeldTicker()
    let (coordinator, _) = makeCountdown(spy: spy, ticker: ticker)

    coordinator.start(mode: .quickTest, audioConfig: .none)
    await ticker.waitUntilEntered(1)
    #expect(coordinator.state == .counting(secondsRemaining: 3))
    #expect(await spy.isHeldDown, "the countdown is running with the idle timer free")

    let cancelling = Task { await coordinator.cancel() }
    await ticker.releaseAll()
    await cancelling.value
    await coordinator.waitUntilFinished()

    #expect(coordinator.state == .cancelled)
    #expect(await spy.calls == ["prevent", "allow"], "a cancelled countdown kept the screen awake")
}

@MainActor
@Test func aCountdownThatReachesGoKeepsTheScreenAwakeUntilTheWalkStops() async throws {
    let spy = IdleTimerSpy()
    let ticker = HeldTicker()
    let (coordinator, recorder) = makeCountdown(spy: spy, ticker: ticker)

    coordinator.start(mode: .quickTest, audioConfig: .none)
    for entered in 1...3 {
        await ticker.waitUntilEntered(entered)
        await ticker.release()
    }
    await coordinator.waitUntilFinished()

    #expect(coordinator.state == .running)
    #expect(await spy.calls == ["prevent"], "Go handed the screen back before the walk")

    _ = try await recorder.stop()
    #expect(await spy.calls == ["prevent", "allow"], "the finished walk kept the screen awake")
}

@MainActor
@Test func aCountdownWhoseSensorsNeverPrimeNeverLeavesTheScreenHeld() async {
    let spy = IdleTimerSpy()
    let ticker = HeldTicker()
    let (coordinator, _) = makeCountdown(motion: SilentSensor(), spy: spy, ticker: ticker)

    coordinator.start(mode: .quickTest, audioConfig: .none)
    await ticker.releaseAll()
    await coordinator.waitUntilFinished()

    if case .failed = coordinator.state {} else {
        Issue.record("expected the countdown to fail, got \(coordinator.state)")
    }
    #expect(await spy.isHeldDown == false, "a failed countdown left the idle timer held down")
}
