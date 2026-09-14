import CoreHaptics
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

// MARK: - The patterns [PRD OQ-6]

@Test func theCountdownTickStaysASingleLightTap() {
    // It fires once a second for five seconds; the rhythm carries it. A
    // sustained tick would blur into the next one and destroy the contrast
    // against Go, which is the only thing telling "1" apart from "walk now".
    #expect(HapticPattern.cadenceTick.kind == .transient(.light))
    #expect(HapticPattern.cadenceTick.duration == .zero)
    #expect(HapticPattern.cadenceTick.isSustained == false)
}

@Test func goAndStopAreSustainedVibrationsRatherThanTaps() {
    // A transient is a click of a few milliseconds, and a pocket swallows it.
    // Both cues that mark a session boundary hold for hundreds.
    for pattern in [HapticPattern.sessionStart, .sessionStop] {
        #expect(pattern.isSustained)
        #expect(pattern.duration >= .milliseconds(400))
        #expect(pattern.duration <= .milliseconds(500))
    }
}

@Test func sustainedCuesDriveFullyAtLowSharpness() {
    // Fabric damps the high-frequency content that makes a haptic feel sharp
    // and lets the low-frequency body through, so the rumble is what carries.
    for pattern in [HapticPattern.sessionStart, .sessionStop] {
        guard case .continuous(_, let intensity, let sharpness) = pattern.kind else {
            Issue.record("\(pattern) should be continuous")
            continue
        }
        #expect(intensity == 1.0)
        #expect(sharpness == 0.3)
    }
}

@Test func stopIsASinglePulseThatOutlastsGo() {
    // [PRD §5]: "a single haptic pulse". One held vibration, not a burst —
    // and the longer of the two, since Stop is the cue most likely to be
    // waited on with the phone out of sight.
    #expect(HapticPattern.sessionStop.duration > HapticPattern.sessionStart.duration)
    #expect(LiveHapticFeedbackService.events(for: .sessionStop).count == 1)
}

@Test func everyBoundaryCueOutlastsTheTick() {
    // The tick is the floor. Neither boundary cue may collapse into it.
    for pattern in [HapticPattern.sessionStart, .sessionStop] {
        #expect(pattern != HapticPattern.cadenceTick)
        #expect(pattern.duration > HapticPattern.cadenceTick.duration)
    }
}

// MARK: - The CoreHaptics translation

@Test func aSustainedCueBecomesOneContinuousEngineEvent() throws {
    // Asserted without hardware: building an event needs no Taptic Engine,
    // only playing one does.
    let events = LiveHapticFeedbackService.events(for: .sessionStart)
    let event = try #require(events.first)

    #expect(events.count == 1)
    #expect(event.type == .hapticContinuous)
    #expect(event.relativeTime == 0)
    #expect(abs(event.duration - 0.4) < 1e-9)

    let intensity = event.eventParameters.first { $0.parameterID == CHHapticEvent.ParameterID.hapticIntensity }
    let sharpness = event.eventParameters.first { $0.parameterID == CHHapticEvent.ParameterID.hapticSharpness }
    #expect(intensity?.value == 1.0)
    #expect(sharpness?.value == 0.3)
}

@Test func stopBecomesTheLongerEngineEvent() throws {
    let event = try #require(LiveHapticFeedbackService.events(for: .sessionStop).first)
    #expect(event.type == .hapticContinuous)
    #expect(abs(event.duration - 0.5) < 1e-9)
}

@Test func theTickNeverReachesTheEngine() {
    // A transient stays with the feedback generator, which honours the user's
    // System Haptics setting. Only the two boundary cues use CoreHaptics.
    #expect(LiveHapticFeedbackService.events(for: .cadenceTick).isEmpty)
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

@Test func theLiveServiceReturnsWellInsideTheVibrationItStarted() async {
    // The countdown plays Go immediately before opening the session against a
    // `TimeAnchor` already stamped at T-0. A call that held for the length of
    // the vibration would push the recorder open behind its own origin.
    let haptics = LiveHapticFeedbackService(logService: HapticLog())
    await haptics.prepare()

    let started = ContinuousClock.now
    await haptics.playSessionStart()
    await haptics.playSessionStop()
    let elapsed = ContinuousClock.now - started

    let cues = HapticPattern.sessionStart.duration + HapticPattern.sessionStop.duration
    #expect(elapsed < cues, "the service waited for its own pattern to finish")
}

@Test func aSustainedCueSurvivesTheTeardownThatFollowsIt() async {
    // Stop is played and the countdown tears down immediately afterwards. The
    // engine is told to stop once its players finish rather than at once, so a
    // teardown landing mid-vibration cannot cut it short — and on hardware that
    // cannot play at all, no engine exists to stop.
    let haptics = LiveHapticFeedbackService(logService: HapticLog())
    await haptics.prepare()
    await haptics.playSessionStop()
    await haptics.teardown()

    try? await Task.sleep(for: HapticPattern.sessionStop.duration + .milliseconds(50))
    // Usable again straight after, with no half-released state left behind.
    await haptics.prepare()
    await haptics.playSessionStart()
    await haptics.teardown()
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
