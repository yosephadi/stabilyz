import Foundation
import Testing
@testable import Stabilyz

/// The countdown's haptic channel (Task 7.3.1, [PRD OQ-6], docs/07 §7.1).
///
/// Haptics have no observable output — no route, no events, nothing audible —
/// so the double is the only place the countdown's shape can be asserted, and
/// the live service can only be held to "does not blow up where it cannot
/// play". Both are worth having, for different reasons.

private final class HapticLog: LogService, @unchecked Sendable {
    let entries = Locked<[String]>([])

    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        entries.withLock { $0.append(message) }
    }
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

// MARK: - The double records what it was asked to play

@Test func theMockRecordsEveryCallInOrder() async {
    let haptics = MockHapticFeedbackService()

    await haptics.prepare()
    await haptics.playCadenceTick()
    await haptics.playSessionStart()
    await haptics.playSessionStop()
    await haptics.teardown()

    #expect(await haptics.recordedCalls == [.prepare, .cadenceTick, .sessionStart, .sessionStop, .teardown])
}

@Test func theMockStartsEmpty() async {
    let haptics = MockHapticFeedbackService()

    #expect(await haptics.recordedCalls.isEmpty)
    #expect(await haptics.taps.isEmpty)
}

@Test func aFiveSecondCountdownIsFiveTicksThenOneGo() async {
    // The shape Task 8.2.6 will drive: a tick per numeral, then the distinct
    // tap at T-0 — not six identical taps, and not a Go that arrives early.
    let haptics = MockHapticFeedbackService()

    await haptics.prepare()
    for _ in 0..<5 { await haptics.playCadenceTick() }
    await haptics.playSessionStart()

    #expect(await haptics.taps == [
        .cadenceTick, .cadenceTick, .cadenceTick, .cadenceTick, .cadenceTick, .sessionStart
    ])
    #expect(await haptics.count(of: .cadenceTick) == 5)
    #expect(await haptics.count(of: .sessionStart) == 1)
}

@Test func goIsNotACadenceTick() async {
    // The PRD's requirement is contrast: a user reading the countdown through
    // a pocket has only the difference between these two to tell "1" from
    // "go". They must never collapse into the same call.
    let haptics = MockHapticFeedbackService()

    await haptics.playCadenceTick()
    await haptics.playSessionStart()

    #expect(await haptics.count(of: .cadenceTick) == 1)
    #expect(await haptics.count(of: .sessionStart) == 1)
}

@Test func stopIsItsOwnPulse() async {
    let haptics = MockHapticFeedbackService()

    await haptics.playSessionStart()
    await haptics.playSessionStop()

    #expect(await haptics.taps == [.sessionStart, .sessionStop])
}

@Test func theMockCanBeResetBetweenPhases() async {
    let haptics = MockHapticFeedbackService()
    await haptics.playCadenceTick()
    await haptics.reset()

    await haptics.playSessionStart()

    #expect(await haptics.recordedCalls == [.sessionStart])
}

@Test func anAbortedCountdownTapsNoGo() async {
    // A cancelled countdown creates no session, so nothing may announce one.
    let haptics = MockHapticFeedbackService()

    await haptics.prepare()
    await haptics.playCadenceTick()
    await haptics.playCadenceTick()
    await haptics.teardown()

    #expect(await haptics.count(of: .sessionStart) == 0)
    #expect(await haptics.recordedCalls.last == .teardown)
}

// MARK: - The silent double

@Test func theSilentDoublePlaysAndRemembersNothing() async {
    // It has to satisfy the protocol without holding anything — it is what a
    // preview and a placeholder graph get.
    let haptics = SilentHapticFeedbackService()

    await haptics.prepare()
    await haptics.playCadenceTick()
    await haptics.playSessionStart()
    await haptics.playSessionStop()
    await haptics.teardown()
}

// MARK: - The live service where it cannot play

@Test func theLiveServiceSurvivesUnsupportedHardware() async {
    // The simulator has no Taptic Engine, which is the whole point of running
    // this here: every method must be a no-op that returns, not a throw and
    // not a crash [PRD §7 AC — no error, no blocked Start].
    let log = HapticLog()
    let haptics = LiveHapticFeedbackService(logService: log)

    await haptics.prepare()
    await haptics.playCadenceTick()
    await haptics.playSessionStart()
    await haptics.playSessionStop()
    await haptics.teardown()
}

@Test func theLiveServiceTapsWithoutAPrepare() async {
    // prepare() is an optimisation, not an initialisation. A countdown that
    // reached Go without one must still tap — slightly late, never silent.
    let haptics = LiveHapticFeedbackService(logService: HapticLog())

    await haptics.playSessionStart()
    await haptics.playCadenceTick()
}

@Test func theLiveServiceToleratesRepeatedLifecycleCalls() async {
    // The countdown screen may appear, be cancelled and appear again; nothing
    // here accumulates or double-releases.
    let haptics = LiveHapticFeedbackService(logService: HapticLog())

    await haptics.prepare()
    await haptics.prepare()
    await haptics.playCadenceTick()
    await haptics.teardown()
    await haptics.teardown()

    // Usable again afterwards — an aborted countdown must not cost the user
    // haptics on their next attempt.
    await haptics.prepare()
    await haptics.playSessionStart()
    await haptics.teardown()
}

@Test func theLiveServiceExplainsItselfOnceWhenHapticsAreAbsent() async {
    // Silent degradation still leaves a trail: "no haptics" and "haptics
    // broken" look identical from outside, and only the log tells them apart.
    //
    // Branches on the hardware rather than assuming a simulator, so this says
    // the same true thing when the suite runs on a phone.
    let log = HapticLog()
    let haptics = LiveHapticFeedbackService(logService: log)

    await haptics.prepare()
    await haptics.prepare()
    await haptics.prepare()

    let unavailable = log.entries.withLock { $0.filter { $0.contains("haptics unavailable") } }
    if haptics.isSupported {
        #expect(unavailable.isEmpty, "a device with a Taptic Engine has nothing to explain")
    } else {
        // Once per service, not once per countdown — prepare() runs every time
        // the countdown screen appears.
        #expect(unavailable.count == 1)
        #expect(unavailable.first?.contains("countdown stays visual") == true)
    }
}

@Test func theLiveServiceNeverBlocksOnAbsentHardware() async {
    // Five ticks and a Go, back to back. If any of these awaited hardware that
    // is not there, a countdown would stall rather than degrade.
    let haptics = LiveHapticFeedbackService(logService: HapticLog())
    await haptics.prepare()

    for _ in 0..<5 { await haptics.playCadenceTick() }
    await haptics.playSessionStart()
    await haptics.playSessionStop()
    await haptics.teardown()
}

// MARK: - Wiring

@Test func bothProductionGraphsCarryRealHaptics() throws {
    // The mistake the EPIC 7 audit caught for audio — a service built, tested
    // and never reachable from the production graph — must not repeat here.
    // Both graphs, because the degraded one is where a user is most likely to
    // be looking when they need the app to behave normally.
    let live = AppDependencies.live(container: try StoreContainer.make(inMemory: true))
    let degraded = AppDependencies.storeUnavailable()

    #expect(live.hapticFeedback is LiveHapticFeedbackService)
    #expect(degraded.hapticFeedback is LiveHapticFeedbackService)
}
