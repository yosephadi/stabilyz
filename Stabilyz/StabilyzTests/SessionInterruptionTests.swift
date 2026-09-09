import Foundation
import Testing
@testable import Stabilyz

// MARK: - Interruption classification

@Test func onlyBackgroundingSuspendsSampleDelivery() {
    // CMMotionManager delivers nothing while suspended (docs/07 §7.7). Losing
    // focus or an audio route change does not stop the accelerometer.
    #expect(SessionInterruption.didEnterBackground.suspendsRecording)

    #expect(SessionInterruption.willResignActive.suspendsRecording == false)
    #expect(SessionInterruption.didBecomeActive.suspendsRecording == false)
    #expect(SessionInterruption.audioInterrupted.suspendsRecording == false)
    #expect(SessionInterruption.audioRouteChanged.suspendsRecording == false)
}

// MARK: - Observer wiring

@Test func theSystemObserverTranslatesAudioEventsIntoInterruptions() async {
    // Audio interruptions arrive through the audio service's own stream, so the
    // audio session stays owned by one component (docs/10 §10.2).
    let audio = ReplayAudioService(events: [.interrupted, .routeChanged, .degraded])
    let observer = SystemSessionInterruptionObserver(audioFeedback: audio)

    let stream = await observer.startObserving()
    var received: [SessionInterruption] = []
    for await interruption in stream {
        // The observer also watches real UIApplication lifecycle notifications,
        // which the test host can emit at any moment. This test is about audio
        // translation, so those are environmental noise, not results.
        guard interruption == .audioInterrupted || interruption == .audioRouteChanged else { continue }
        received.append(interruption)
        if received.count == 2 { break }
    }
    await observer.stopObserving()

    #expect(received == [.audioInterrupted, .audioRouteChanged])
}

@Test func stoppingObservationFinishesTheStream() async {
    let observer = SystemSessionInterruptionObserver(audioFeedback: ReplayAudioService(events: []))
    let stream = await observer.startObserving()
    await observer.stopObserving()

    // A stream that never finishes would leak the recorder's observer task.
    // Lifecycle notifications from the host may arrive before it closes; what
    // matters is that it closes at all.
    for await _ in stream {}
}

/// Emits a fixed sequence of audio events, then stays open.
private struct ReplayAudioService: AudioFeedbackService {
    let events: AsyncStream<AudioFeedbackEvent>

    init(events sequence: [AudioFeedbackEvent]) {
        self.events = AsyncStream { continuation in
            for event in sequence { continuation.yield(event) }
        }
    }

    func playStartTone() async {}
    func playStopTone() async {}
    func playStepTick() async {}
    func startMetronome(bpm: Double) async {}
    func stopMetronome() async {}
    func suspend() async {}
    func resume() async {}
}
