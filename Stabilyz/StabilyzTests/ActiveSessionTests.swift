import Foundation
import Testing
@testable import Stabilyz

/// The walk in progress and the countdown over it (Tasks 8.2.2 base, 8.2.6 UI;
/// Figma node 128:2591).

@MainActor
private func makeSession(
    mode: TestMode = .quickTest,
    audioConfig: SessionAudioConfig = .none,
    onStop: @escaping @MainActor () -> Void = {}
) -> ActiveSessionViewModel {
    ActiveSessionViewModel(mode: mode, audioConfig: audioConfig, onStop: onStop)
}

/// Feeds elapsed ticks the way the recorder does.
private func elapsedStream(_ seconds: [Int]) -> AsyncStream<SessionRecordingEvent> {
    AsyncStream { continuation in
        for second in seconds { continuation.yield(.elapsed(.seconds(second))) }
        continuation.finish()
    }
}

// MARK: - The clock, per mode

@MainActor
@Test func aQuickTestStartsAtTwoMinutes() {
    let model = makeSession(mode: .quickTest)

    #expect(model.total == .seconds(120))
    #expect(model.timerText == "02:00")
    #expect(model.progress == 1)
}

@MainActor
@Test func aFullTestStartsAtSixMinutes() {
    let model = makeSession(mode: .fullTest)

    #expect(model.total == .seconds(360))
    #expect(model.timerText == "06:00")
    #expect(model.progress == 1)
}

@MainActor
@Test func theClockCountsDownFromTheRecordersElapsedEvents() async {
    // The recorder's clock, not a Timer beside it: elapsed comes from sample
    // timestamps on the monotonic timebase (docs/07 §7.4).
    let model = makeSession(mode: .quickTest)

    await model.observe(elapsedStream([1, 30, 61]))

    #expect(model.elapsed == .seconds(61))
    #expect(model.timerText == "00:59")
}

@MainActor
@Test func theClockIsZeroPaddedThroughout() async {
    let model = makeSession(mode: .quickTest)

    await model.observe(elapsedStream([111]))
    #expect(model.timerText == "00:09")

    let full = makeSession(mode: .fullTest)
    await full.observe(elapsedStream([300]))
    #expect(full.timerText == "01:00")
}

@MainActor
@Test func walkingPastTheAdvertisedLengthNeverGoesNegative() async {
    // [PRD OQ-3] The advertised length is not the valid-walking requirement, so
    // a user may well keep walking past it. They are not shown a clock running
    // backwards.
    let model = makeSession(mode: .quickTest)

    await model.observe(elapsedStream([200]))

    #expect(model.remaining == .zero)
    #expect(model.timerText == "00:00")
    #expect(model.progress == 0)
}

// MARK: - The depleting ring

@MainActor
@Test func theRingDepletesFromOneToZeroAcrossTheMode() async {
    let model = makeSession(mode: .quickTest)
    #expect(model.progress == 1)

    await model.observe(elapsedStream([30]))
    #expect(abs(model.progress - 0.75) < 0.0001)

    await model.observe(elapsedStream([60]))
    #expect(abs(model.progress - 0.5) < 0.0001)

    await model.observe(elapsedStream([120]))
    #expect(model.progress == 0)
}

@MainActor
@Test func theRingIsScaledToEachModesOwnLength() async {
    // Sixty seconds is half a Quick Test and a sixth of a Full Test.
    let quick = makeSession(mode: .quickTest)
    let full = makeSession(mode: .fullTest)

    await quick.observe(elapsedStream([60]))
    await full.observe(elapsedStream([60]))

    #expect(abs(quick.progress - 0.5) < 0.0001)
    #expect(abs(full.progress - (5.0 / 6.0)) < 0.0001)
}

@MainActor
@Test func theRingStaysWithinBounds() async {
    let model = makeSession(mode: .quickTest)

    await model.observe(elapsedStream([0, 60, 119, 120, 500]))

    #expect(model.progress >= 0)
    #expect(model.progress <= 1)
}

// MARK: - Stop

@MainActor
@Test func stopFiresOnceAndThenLocksTheButton() {
    let stops = Locked(0)
    let model = makeSession { stops.withLock { $0 += 1 } }

    model.stop()
    model.stop()
    model.stop()

    #expect(stops.withLock { $0 } == 1)
    #expect(model.isStopping)
}

// MARK: - What the cues row says

@MainActor
@Test func theCuesListNamesWhatTheSessionWasStartedWith() {
    #expect(makeSession(audioConfig: .none).isAudioCueOn == false)
    #expect(makeSession(audioConfig: .stepFeedback).isAudioCueOn)
    #expect(makeSession(audioConfig: .stepFeedback).audioCueTitle == "Audio Step Feedback")
    #expect(makeSession(audioConfig: .metronome(cue: .fixture())).audioCueTitle == "Metronome Cue")
}

// MARK: - VoiceOver

@MainActor
@Test func theTimerIsSpokenRatherThanSpelled() async {
    let model = makeSession(mode: .quickTest)
    #expect(model.timerAccessibilityLabel == "2 minutes 0 seconds remaining")

    await model.observe(elapsedStream([59]))
    #expect(model.timerAccessibilityLabel == "1 minute 1 second remaining")
}

// MARK: - The countdown overlay's content

@Test func theOverlayIsHiddenBeforeAnythingStarts() {
    #expect(CountdownOverlayContent.content(for: .idle) == .hidden)
}

@Test func theOverlaySaysItIsGettingReadyWhilePriming() {
    // Not a numeral: priming can take a moment, and counting through it would
    // mean the five seconds were not the user's to get situated in.
    let content = CountdownOverlayContent.content(for: .priming)

    #expect(content == .preparing)
    #expect(content.text == CountdownOverlayContent.preparingText)
    #expect(content.isNumeral == false)
    // Not a tick, so it must not be announced in front of the count.
    #expect(content.announcement == nil)
}

@Test func theOverlayShowsEachNumeralAsItCounts() {
    for remaining in 1...5 {
        let content = CountdownOverlayContent.content(for: .counting(secondsRemaining: remaining))
        #expect(content == .counting("\(remaining)"))
        #expect(content.text == "\(remaining)")
        #expect(content.isNumeral)
        #expect(content.isVisible)
    }
}

@Test func everyNumeralIsAnnouncedForVoiceOver() {
    // The converse channel: a user who has pocketed the phone can neither see
    // the numerals nor necessarily feel the taps [PRD OQ-6].
    let announcements = (1...5)
        .reversed()
        .map { CountdownOverlayContent.content(for: .counting(secondsRemaining: $0)).announcement }

    #expect(announcements == ["5", "4", "3", "2", "1"])
}

@Test func goIsHeldAtT0AndThenTheOverlayClears() {
    let held = CountdownOverlayContent.content(for: .running, isHoldingGo: true)
    #expect(held == .go)
    #expect(held.text == "Go!")
    #expect(held.isNumeral)
    #expect(held.announcement == "Go!")

    // The walk is already recording underneath; the word is on borrowed time.
    #expect(CountdownOverlayContent.content(for: .running, isHoldingGo: false) == .hidden)
}

@Test func theOverlayClearsOnCancelAndOnFailure() {
    // Both land back on the setup screen, so the overlay has nothing to say
    // about either.
    #expect(CountdownOverlayContent.content(for: .cancelled) == .hidden)
    #expect(CountdownOverlayContent.content(for: .failed(.sensor(.primingTimeout))) == .hidden)
    #expect(CountdownOverlayContent.content(for: .cancelled, isHoldingGo: true) == .hidden)
}

@Test func aHiddenOverlaySaysNothing() {
    #expect(CountdownOverlayContent.hidden.text == nil)
    #expect(CountdownOverlayContent.hidden.announcement == nil)
    #expect(CountdownOverlayContent.hidden.isVisible == false)
}

// MARK: - The full progression, as the cover drives it

@Test func theOverlayFollowsTheWholeCountdownThenGetsOutOfTheWay() {
    let states: [CountdownCoordinator.State] = [
        .idle, .priming,
        .counting(secondsRemaining: 5), .counting(secondsRemaining: 4),
        .counting(secondsRemaining: 3), .counting(secondsRemaining: 2),
        .counting(secondsRemaining: 1),
        .running
    ]

    let visible = states.map { CountdownOverlayContent.content(for: $0).isVisible }

    #expect(visible == [false, true, true, true, true, true, true, false])
}

// MARK: - Silencing a cue mid-walk

@MainActor
@Test func aSessionStartedSilentHasNothingToSilence() {
    let model = makeSession(audioConfig: .none)

    #expect(model.hasAudioCue == false)
    #expect(model.canSilenceAudioCue == false)
    #expect(model.isAudioCueOn == false)
}

@MainActor
@Test func silencingTurnsTheCueOffAndTellsTheRecorder() {
    let silenced = Locked(0)
    let model = ActiveSessionViewModel(
        mode: .quickTest,
        audioConfig: .stepFeedback,
        onStop: {},
        onSilenceAudioCue: { silenced.withLock { $0 += 1 } }
    )
    #expect(model.isAudioCueOn)

    model.silenceAudioCue()

    #expect(model.isAudioCueSilenced)
    #expect(model.isAudioCueOn == false)
    #expect(silenced.withLock { $0 } == 1)
}

@MainActor
@Test func silencingIsOneWayAndCannotBeUndone() {
    // A walk that was unpaced and then paced would produce one set of metrics
    // spanning two conditions, compared against a baseline established under
    // one [PRD §5, OQ-5]. There is no path back on.
    let silenced = Locked(0)
    let model = ActiveSessionViewModel(
        mode: .fullTest,
        audioConfig: .metronome(cue: .fixture()),
        onStop: {},
        onSilenceAudioCue: { silenced.withLock { $0 += 1 } }
    )

    model.silenceAudioCue()
    model.silenceAudioCue()
    model.silenceAudioCue()

    // Idempotent: the recorder is told once, not three times.
    #expect(silenced.withLock { $0 } == 1)
    #expect(model.canSilenceAudioCue == false)
    #expect(model.isAudioCueOn == false)
    #expect(model.audioCueStatus == "Silenced for this walk")
}

@MainActor
@Test func theRowExplainsItselfOnlyOnceSilenced() {
    let model = makeSession(audioConfig: .stepFeedback)
    #expect(model.audioCueStatus == nil)

    model.silenceAudioCue()
    #expect(model.audioCueStatus?.isEmpty == false)
}

@MainActor
@Test func hapticsToggleFreelyInBothDirections() {
    // They fire at T-0 and at Stop, so changing one mid-walk cannot touch the
    // measurement [PRD OQ-6].
    let model = makeSession()
    #expect(model.isHapticsOn)

    model.isHapticsOn = false
    #expect(model.isHapticsOn == false)
    model.isHapticsOn = true
    #expect(model.isHapticsOn)
}

@MainActor
@Test func aStoppedWalkCannotStillBeSilenced() {
    let model = makeSession(audioConfig: .stepFeedback)
    model.stop()

    #expect(model.canSilenceAudioCue == false)
}

// MARK: - What the session records about it

@Test func aBufferThatWasNeverSilencedSaysSo() {
    let anchor = TimeAnchor(wallClock: Date(timeIntervalSince1970: 1_700_000_000), uptime: 1_000)
    let buffer = RawSessionBuffer(
        mode: .quickTest,
        audioConfig: .stepFeedback,
        anchor: anchor,
        series: AlignedSampleSeries(samples: [], gaps: []),
        pedometerEvents: [],
        startedAt: anchor.wallClock,
        endedAt: anchor.wallClock,
        advertisedClockElapsed: .seconds(120),
        interruptionCount: 0,
        pedometerAvailable: true
    )

    #expect(buffer.audioSilencedAt == nil)
}

@Test func aSessionKeepsTheConfigItStartedWithAndWhenItWentQuiet() {
    // The stored row describes what actually happened: it started with a cue,
    // and the rest of the walk was silent. Not one state claimed for a walk
    // that had two.
    let session = GaitSession.invalid(
        id: UUID(),
        mode: .quickTest,
        reason: .insufficientValidWalking,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        endedAt: Date(timeIntervalSince1970: 1_700_000_120),
        advertisedClockElapsed: .seconds(120),
        validWalkingDuration: .seconds(40),
        audioConfig: .stepFeedback,
        audioSilencedAt: .seconds(45),
        algorithmVersion: "1",
        appVersion: "1",
        deviceModel: "test"
    )

    #expect(session.audioConfig == .stepFeedback)
    #expect(session.audioSilencedAt == .seconds(45))
}

// MARK: - The two ways a walk ends

@MainActor
@Test func reachingZeroEndsTheWalkWithoutATap() async {
    // The user asked for two minutes, so two minutes is what the app takes.
    // Leaving them walking past a clock reading 00:00, waiting to be told they
    // may stop, would be the app failing to finish what it started.
    let stops = Locked(0)
    let model = makeSession(mode: .quickTest) { stops.withLock { $0 += 1 } }

    await model.observe(elapsedStream([60, 119, 120]))

    #expect(model.timerText == "00:00")
    #expect(stops.withLock { $0 } == 1)
    #expect(model.isStopping)
}

@MainActor
@Test func theClockDoesNotEndTheWalkEarly() async {
    let stops = Locked(0)
    let model = makeSession(mode: .fullTest) { stops.withLock { $0 += 1 } }

    // Two minutes into a six-minute walk.
    await model.observe(elapsedStream([60, 120]))

    #expect(stops.withLock { $0 } == 0)
    #expect(model.isStopping == false)
}

@MainActor
@Test func aTappedStopAndAnElapsedOneAreTheSameEnding() async {
    // Both go through `stop()`, so neither can fire twice and a tap landing on
    // the last second cannot end the walk twice over.
    let stops = Locked(0)
    let model = makeSession(mode: .quickTest) { stops.withLock { $0 += 1 } }

    model.stop()
    await model.observe(elapsedStream([120, 121]))

    #expect(stops.withLock { $0 } == 1)
}

@MainActor
@Test func walkingPastTheEndDoesNotKeepEndingTheWalk() async {
    let stops = Locked(0)
    let model = makeSession(mode: .quickTest) { stops.withLock { $0 += 1 } }

    await model.observe(elapsedStream([120, 130, 140, 200]))

    #expect(stops.withLock { $0 } == 1)
}
