import Foundation
import Testing
@testable import Stabilyz

private let anchor = TimeAnchor(wallClock: Date(timeIntervalSince1970: 1_700_000_000), uptime: 0)

private func sample(t: TimeInterval, magnitude: Double) -> SensorSample {
    // Magnitude along one axis, since the detector is orientation-independent.
    SensorSample(deviceTimestamp: t, anchor: anchor, acceleration: Vector3(x: 0, y: 0, z: magnitude))
}

/// A synthetic footfall signal: a quiet baseline with periodic sharp peaks
/// (docs/07 §7.9).
private func footfalls(
    stepsPerSecond: Double,
    seconds: Double,
    sampleRateHz: Double = 100,
    peak: Double = 3,
    baseline: Double = 1
) -> [SensorSample] {
    let count = Int(seconds * sampleRateHz)
    let period = sampleRateHz / stepsPerSecond

    return (0..<count).map { index in
        let phase = Double(index).truncatingRemainder(dividingBy: period)
        // A narrow spike at the start of each step period.
        let magnitude = phase < 2 ? peak : baseline
        return sample(t: Double(index) / sampleRateHz, magnitude: magnitude)
    }
}

private func detect(
    _ samples: [SensorSample],
    policy: LiveStepDetectionPolicy = .provisional
) -> [LiveStepEvent] {
    var detector = LiveStepDetector(policy: policy)
    return samples.compactMap { detector.process($0) }
}

// MARK: - Detection

@Test func steadyFootfallsAreDetectedAtRoughlyTheRightRate() {
    // 2 steps/sec for 4 seconds. Detection is approximate by design — this is
    // audio feedback, not the batch step detection of Task 5.2.4.
    let events = detect(footfalls(stepsPerSecond: 2, seconds: 4))

    #expect(events.count >= 5)
    #expect(events.count <= 9)
    #expect(events.allSatisfy { $0.confidence >= LiveStepDetectionPolicy.provisional.confidenceThreshold })
}

@Test func aFlatSignalProducesNoSteps() {
    // Standing still must not tick.
    let flat = (0..<200).map { sample(t: Double($0) / 100, magnitude: 1) }
    #expect(detect(flat).isEmpty)
}

@Test func detectedTimestampsAreMonotonic() {
    let events = detect(footfalls(stepsPerSecond: 2, seconds: 4))
    #expect(events.map(\.deviceTimestamp) == events.map(\.deviceTimestamp).sorted())
}

// MARK: - Refractory gate (docs/10 §10.3)

@Test func oneFootfallCannotProduceTwoTicks() {
    // A doubled peak inside the refractory window must yield a single event.
    var samples: [SensorSample] = []
    for index in 0..<200 {
        let t = Double(index) / 100
        // Two spikes 30 ms apart, then quiet.
        let magnitude: Double = (index == 50 || index == 53) ? 4 : 1
        samples.append(sample(t: t, magnitude: magnitude))
    }

    let events = detect(samples)
    #expect(events.count == 1)
}

@Test func theRefractoryWindowIsConfigurable() {
    // The value is [OPEN]; a shorter window must let closer steps through.
    var samples: [SensorSample] = []
    for index in 0..<200 {
        let magnitude: Double = (index == 50 || index == 60) ? 4 : 1
        samples.append(sample(t: Double(index) / 100, magnitude: magnitude))
    }

    let strict = detect(samples, policy: .provisional)
    let permissive = detect(
        samples,
        policy: LiveStepDetectionPolicy(confidenceThreshold: 0.5, refractory: .milliseconds(50))
    )

    #expect(strict.count == 1)
    #expect(permissive.count == 2)
}

// MARK: - Confidence gate (docs/10 §10.3)

@Test func lowConfidencePeaksDoNotFire() {
    // Raw noise must never create an accidental rhythm [PRD §6, OQ-4].
    var samples: [SensorSample] = []
    for index in 0..<300 {
        // Small irregular wobble, nothing resembling a footfall.
        let magnitude = 1 + (index % 3 == 0 ? 0.02 : 0)
        samples.append(sample(t: Double(index) / 100, magnitude: magnitude))
    }

    let events = detect(samples, policy: LiveStepDetectionPolicy(confidenceThreshold: 0.9, refractory: .milliseconds(300)))
    #expect(events.isEmpty)
}

@Test func raisingTheThresholdFiresLessOften() {
    let samples = footfalls(stepsPerSecond: 2, seconds: 4, peak: 2.2)

    let lenient = detect(samples, policy: LiveStepDetectionPolicy(confidenceThreshold: 0.1, refractory: .milliseconds(300)))
    let strict = detect(samples, policy: LiveStepDetectionPolicy(confidenceThreshold: 0.95, refractory: .milliseconds(300)))

    #expect(strict.count <= lenient.count)
}

@Test func confidenceIsBoundedToTheUnitRange() {
    let events = detect(footfalls(stepsPerSecond: 2, seconds: 4, peak: 50))
    #expect(events.allSatisfy { $0.confidence >= 0 && $0.confidence <= 1 })
}

// MARK: - Reuse

@Test func resettingClearsAdaptationBetweenSessions() {
    var detector = LiveStepDetector()
    for sample in footfalls(stepsPerSecond: 2, seconds: 2) { _ = detector.process(sample) }

    detector.reset()

    // After a reset the very first samples cannot be judged against stale
    // statistics, so nothing fires immediately.
    let flat = (0..<5).map { sample(t: Double($0) / 100, magnitude: 1) }
    #expect(flat.compactMap { detector.process($0) }.isEmpty)
}

// MARK: - Recorder integration

@Test func theRecorderEmitsStepEventsOnlyWhenStepFeedbackIsOn() async throws {
    // Detection is skipped entirely otherwise, so a session that cannot use the
    // ticks pays nothing per sample.
    let clock = StepClock()
    let fixture = GaitFixture.makeWalk(name: "steps", cadenceBPM: 108, seconds: 3)

    let withFeedback = makeStepRecorder(fixture: fixture, clock: clock)
    let collector = Task { await firstStepEvent(withFeedback.stepEvents) }
    _ = try await withFeedback.begin(mode: .quickTest, audioConfig: .stepFeedback)
    _ = try await withFeedback.stop()
    #expect(await collector.value != nil)

    let withoutFeedback = makeStepRecorder(fixture: fixture, clock: clock)
    _ = try await withoutFeedback.begin(mode: .quickTest, audioConfig: .none)
    _ = try await withoutFeedback.stop()
    // The stream stays open across sessions; nothing was yielded into it.
    #expect(await firstStepEventOrNil(withoutFeedback.stepEvents) == nil)
}

private struct StepClock: Clock {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let uptime: TimeInterval = 0
}

private func makeStepRecorder(fixture: GaitFixture, clock: Clock) -> SessionRecorder {
    SessionRecorder(
        motionSensor: FixtureSensorService(fixture: fixture, clock: clock),
        pedometer: FixturePedometerService(fixture: fixture, clock: clock),
        audioFeedback: SilentAudioFeedbackService(),
        interruptionObserver: SystemSessionInterruptionObserver(audioFeedback: SilentAudioFeedbackService()),
        screenSleep: SystemScreenSleepController(),
        clock: clock,
        logService: OSLogService(subsystem: "com.stabilyz.tests"),
        fileIO: FileManagerFileIO()
    )
}

private func firstStepEvent(_ stream: AsyncStream<LiveStepEvent>) async -> LiveStepEvent? {
    for await event in stream { return event }
    return nil
}

/// Returns nil promptly when nothing was emitted, rather than waiting forever.
private func firstStepEventOrNil(_ stream: AsyncStream<LiveStepEvent>) async -> LiveStepEvent? {
    await withTaskGroup(of: LiveStepEvent?.self) { group in
        group.addTask { await firstStepEvent(stream) }
        group.addTask {
            try? await Task.sleep(for: .milliseconds(200))
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}
