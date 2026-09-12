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

// MARK: - The cues are a record, not a control

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
