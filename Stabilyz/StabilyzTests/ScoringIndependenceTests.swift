import Foundation
import Testing
@testable import Stabilyz

/// Task 7.2.3 — the audio epic's PRD-critical AC (docs/10 §10.4).
///
/// Audio is allowed to influence the *user*: the metronome paces the walk, and
/// that influence is sanctioned and recorded [PRD OQ-4]. What it must never
/// influence is the *measurement*. These tests hold the line in three forms:
///
/// 1. The same session under every audio config yields byte-identical results.
/// 2. Stop never waits on the feedback engines.
/// 3. Audio failure never fails a session.
///
/// Byte-identical, not "close enough": the snapshot is encoded with sorted keys
/// and compared as `Data`, so a difference in the last bit of one Double fails
/// the test. That is the standard the claim deserves — "the metronome shifted
/// your score by a hundredth" is exactly the defect that would otherwise ship
/// unnoticed.

// MARK: - Snapshot

/// Everything the batch concluded, in a canonical, comparable form.
private struct OutcomeSnapshot: Codable, Equatable {
    var isValid: Bool
    var invalidReason: String?
    var validWalkingSeconds: Double
    var metrics: GaitMetrics?
    var relativeIndex: Int?
    var compositeZ: Double?
    var scoreAlgorithmVersion: String?
    var breakdown: [MetricBreakdown]?
    var algorithmVersion: String

    init(_ result: SessionAnalysisResult) {
        algorithmVersion = result.algorithmVersion
        isValid = result.outcome.isValid
        validWalkingSeconds = Self.seconds(result.outcome.validWalkingDuration)

        switch result.outcome {
        case .valid(let metrics, _, let score):
            self.metrics = metrics
            relativeIndex = score?.relativeIndex
            compositeZ = score?.compositeZ
            scoreAlgorithmVersion = score?.algorithmVersion
            breakdown = score?.breakdown
        case .invalid(let reason, _):
            invalidReason = reason.rawValue
        }
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Sorted keys, so the bytes depend on the values and nothing else.
    func canonicalBytes() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

private func snapshotBytes(_ result: SessionAnalysisResult) throws -> Data {
    try OutcomeSnapshot(result).canonicalBytes()
}

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

// MARK: - Doubles

private final class IndependenceLog: LogService, @unchecked Sendable {
    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {}
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

/// Ordinary audio: does nothing audible, records that it was asked.
private actor CountingAudio: AudioFeedbackService {
    nonisolated var events: AsyncStream<AudioFeedbackEvent> { AsyncStream { $0.finish() } }

    private(set) var stepTicks = 0
    private(set) var metronomeStarts = 0

    func playStartTone() async {}
    func playStopTone() async {}
    func playStepTick() async { stepTicks += 1 }
    func startMetronome(bpm: Double) async { metronomeStarts += 1 }
    func stopMetronome() async {}
    func suspend() async {}
    func resume() async {}
}

/// Audio where **every** call stalls — the dead or wedged layer the data path
/// must be independent of (ledger entry 25).
///
/// Nothing here is exempt: the start tone, the stop tone, the metronome start
/// and stop, and every tick all hang for thirty seconds. `started` and
/// `finished` are counted separately, so "the session did not wait" is a fact
/// about the two counts rather than a stopwatch reading.
private actor WedgedAudio: AudioFeedbackService {
    nonisolated var events: AsyncStream<AudioFeedbackEvent> { AsyncStream { $0.finish() } }

    private(set) var started = 0
    private(set) var finished = 0
    private(set) var startedTicks = 0

    private func stall() async {
        started += 1
        try? await Task.sleep(for: .seconds(30))
        finished += 1
    }

    func playStartTone() async { await stall() }
    func playStopTone() async { await stall() }
    func playStepTick() async {
        startedTicks += 1
        await stall()
    }
    func startMetronome(bpm: Double) async { await stall() }
    func stopMetronome() async { await stall() }
    func suspend() async { await stall() }
    func resume() async { await stall() }
}

/// Audio that has already failed: silent, degraded, and saying so.
private actor FailedAudio: AudioFeedbackService {
    nonisolated var events: AsyncStream<AudioFeedbackEvent> {
        AsyncStream { continuation in
            continuation.yield(.degraded)
            continuation.finish()
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

private struct IndependenceClock: Clock {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let uptime: TimeInterval = 0
}

/// Every audio config a session can be recorded under.
private let everyAudioConfig: [SessionAudioConfig] = [.none, .stepFeedback, .metronome(cue: .fixture(bpm: 104))]

// MARK: - Byte-identical results, scored path

@Test func aScoredSessionIsByteIdenticalUnderEveryAudioConfig() async throws {
    // The strongest form of the claim: a fully scored session — metrics,
    // composite, relative index, per-signal breakdown — recomputed under each
    // audio config against the same baseline.
    let configuration = AlgorithmConfiguration.v1
    let pipeline = GaitAnalysisPipeline(configuration: configuration)
    let golden = try GoldenStore.load("scored-sixth-session-quick")
    let calibration = try #require(golden.calibration)
    let profile = golden.profile.profile

    let baseline = try await GoldenSignal.baseline(
        from: calibration, mode: golden.testMode, profile: profile, configuration: configuration
    )

    var snapshots: [(SessionAudioConfig, Data)] = []
    for config in everyAudioConfig {
        let outcome = try await pipeline.analyze(
            buffer: GoldenSignal.buffer(for: golden.signal, mode: golden.testMode, audioConfig: config),
            baseline: baseline,
            profile: profile,
            progress: { _ in }
        )
        snapshots.append((config, try snapshotBytes(SessionAnalysisResult(outcome: outcome, algorithmVersion: configuration.version))))
    }

    let reference = try #require(snapshots.first)
    for (config, bytes) in snapshots.dropFirst() {
        #expect(bytes == reference.1, "\(config) changed the result:\n\(text(bytes))\nvs\n\(text(reference.1))")
    }

    // And the comparison is not vacuous: this session really was scored.
    let snapshot = try JSONDecoder().decode(OutcomeSnapshot.self, from: reference.1)
    #expect(snapshot.isValid)
    #expect(snapshot.relativeIndex != nil)
    #expect(snapshot.breakdown?.isEmpty == false)
}

@Test func anInvalidSessionIsJudgedIdenticallyUnderEveryAudioConfig() async throws {
    // Independence has to hold on the noisy path too, or the metronome could
    // decide whether a walk counted.
    let configuration = AlgorithmConfiguration.v1
    let pipeline = GaitAnalysisPipeline(configuration: configuration)
    // Far too short for a Quick Test [PRD OQ-3].
    let spec = GoldenSignalSpec(seconds: 20)

    var snapshots: [Data] = []
    for config in everyAudioConfig {
        let outcome = try await pipeline.analyze(
            buffer: GoldenSignal.buffer(for: spec, mode: .quickTest, audioConfig: config),
            baseline: nil, profile: nil, progress: { _ in }
        )
        snapshots.append(try snapshotBytes(SessionAnalysisResult(outcome: outcome, algorithmVersion: configuration.version)))
    }

    #expect(Set(snapshots).count == 1, "the audio config changed the validity verdict")
    let snapshot = try JSONDecoder().decode(OutcomeSnapshot.self, from: try #require(snapshots.first))
    #expect(snapshot.isValid == false)
    #expect(snapshot.invalidReason != nil)
}

@Test func aPreBaselineSessionIsByteIdenticalUnderEveryAudioConfig() async throws {
    // Sessions 1–5 carry metrics and no score; those metrics feed the baseline,
    // so audio leaking in here would corrupt every later comparison.
    let configuration = AlgorithmConfiguration.v1
    let pipeline = GaitAnalysisPipeline(configuration: configuration)
    let spec = GoldenSignalSpec(seconds: 130)

    var snapshots: [Data] = []
    for config in everyAudioConfig {
        let outcome = try await pipeline.analyze(
            buffer: GoldenSignal.buffer(for: spec, mode: .quickTest, audioConfig: config),
            baseline: nil, profile: nil, progress: { _ in }
        )
        snapshots.append(try snapshotBytes(SessionAnalysisResult(outcome: outcome, algorithmVersion: configuration.version)))
    }

    #expect(Set(snapshots).count == 1)
    let snapshot = try JSONDecoder().decode(OutcomeSnapshot.self, from: try #require(snapshots.first))
    #expect(snapshot.isValid)
    #expect(snapshot.metrics != nil)
    #expect(snapshot.relativeIndex == nil)
}

// MARK: - Byte-identical results, recorded end to end

@Test func recordingTheSameWalkUnderEveryAudioConfigProducesTheSameData() async throws {
    // Not just the same scoring of the same buffer: the same *recording*. The
    // step detector runs per sample under .stepFeedback and the metronome is
    // started under .metronome; neither may leave a trace in the samples.
    let fixture = try goldenFixture(GoldenSignalSpec(seconds: 130), name: "independence")

    var recordings: [(config: SessionAudioConfig, buffer: RawSessionBuffer)] = []
    for config in everyAudioConfig {
        let recorder = makeRecorder(fixture: fixture, audio: CountingAudio())
        _ = try await recorder.begin(mode: .quickTest, audioConfig: config)
        recordings.append((config, try await recorder.stop()))
    }

    let reference = try #require(recordings.first)
    #expect(reference.config == SessionAudioConfig.none)

    for recording in recordings.dropFirst() {
        #expect(recording.buffer.series == reference.buffer.series, "\(recording.config) changed the recorded samples")
        #expect(recording.buffer.startedAt == reference.buffer.startedAt)
        #expect(recording.buffer.endedAt == reference.buffer.endedAt)
        #expect(recording.buffer.interruptionCount == reference.buffer.interruptionCount)
        // The one field that is *meant* to differ, and the only one.
        #expect(recording.buffer.audioConfig == recording.config)
    }

    // Then through the pipeline: same bytes out.
    let configuration = AlgorithmConfiguration.v1
    let pipeline = GaitAnalysisPipeline(configuration: configuration)
    var snapshots: [Data] = []
    for recording in recordings {
        let outcome = try await pipeline.analyze(
            buffer: recording.buffer, baseline: nil, profile: nil, progress: { _ in }
        )
        snapshots.append(try snapshotBytes(SessionAnalysisResult(outcome: outcome, algorithmVersion: configuration.version)))
    }

    #expect(Set(snapshots).count == 1, "the audio config changed the recorded session's result")
}

// MARK: - Stop never waits on the feedback engines

@Test func aWedgedAudioLayerNeitherDelaysStopNorChangesTheResult() async throws {
    // docs/10 §10.4: neither Step Feedback nor the Metronome may block or delay
    // the batch at Stop. Shown without a stopwatch — the session finishes and is
    // scored while the audio layer is still inside its first tick.
    let fixture = try goldenFixture(GoldenSignalSpec(seconds: 130), name: "wedged")
    let configuration = AlgorithmConfiguration.v1
    let pipeline = GaitAnalysisPipeline(configuration: configuration)

    let clean = makeRecorder(fixture: fixture, audio: CountingAudio())
    _ = try await clean.begin(mode: .quickTest, audioConfig: .none)
    let cleanBuffer = try await clean.stop()

    let wedged = WedgedAudio()
    let recorder = makeRecorder(fixture: fixture, audio: wedged)
    _ = try await recorder.begin(mode: .quickTest, audioConfig: .stepFeedback)
    #expect(await eventuallyStalled(wedged), "no tick was requested, so nothing was stalled")
    let wedgedBuffer = try await recorder.stop()

    #expect(await wedged.finished == 0, "the recording waited for the audio layer")
    #expect(wedgedBuffer.series == cleanBuffer.series)

    let cleanResult = try await pipeline.analyze(buffer: cleanBuffer, baseline: nil, profile: nil, progress: { _ in })
    let wedgedResult = try await pipeline.analyze(buffer: wedgedBuffer, baseline: nil, profile: nil, progress: { _ in })

    // Still stuck, and the batch is already done.
    #expect(await wedged.finished == 0)
    #expect(
        try snapshotBytes(SessionAnalysisResult(outcome: wedgedResult, algorithmVersion: configuration.version))
            == snapshotBytes(SessionAnalysisResult(outcome: cleanResult, algorithmVersion: configuration.version))
    )
}

// MARK: - Audio failure never fails a session

@Test func aSessionRecordedWithFailedAudioIsStillValidAndIdentical() async throws {
    // A walk is measured perfectly well in silence (docs/10 §10.4).
    let fixture = try goldenFixture(GoldenSignalSpec(seconds: 130), name: "failed-audio")
    let configuration = AlgorithmConfiguration.v1
    let pipeline = GaitAnalysisPipeline(configuration: configuration)

    let clean = makeRecorder(fixture: fixture, audio: CountingAudio())
    _ = try await clean.begin(mode: .quickTest, audioConfig: .none)
    let cleanBuffer = try await clean.stop()

    // Every config, against a service that has already given up.
    for config in everyAudioConfig {
        let recorder = makeRecorder(fixture: fixture, audio: FailedAudio())
        _ = try await recorder.begin(mode: .quickTest, audioConfig: config)
        let buffer = try await recorder.stop()

        let result = try await pipeline.analyze(buffer: buffer, baseline: nil, profile: nil, progress: { _ in })
        let reference = try await pipeline.analyze(buffer: cleanBuffer, baseline: nil, profile: nil, progress: { _ in })

        #expect(result.isValid, "\(config): audio failure invalidated the session")
        #expect(
            try snapshotBytes(SessionAnalysisResult(outcome: result, algorithmVersion: configuration.version))
                == snapshotBytes(SessionAnalysisResult(outcome: reference, algorithmVersion: configuration.version)),
            "\(config): audio failure changed the result"
        )
    }
}

@Test func audioTroubleDuringASessionChangesNeitherTheCountNorTheOutcome() async throws {
    // Interruptions and route changes arrive mid-walk. They are feedback-only
    // degradation: they must not count as recording interruptions (Task 4.2.3)
    // and must not move the result.
    let fixture = try goldenFixture(GoldenSignalSpec(seconds: 130), name: "audio-trouble")
    let configuration = AlgorithmConfiguration.v1
    let pipeline = GaitAnalysisPipeline(configuration: configuration)

    let clean = makeRecorder(fixture: fixture, audio: CountingAudio())
    _ = try await clean.begin(mode: .quickTest, audioConfig: .none)
    let cleanBuffer = try await clean.stop()

    let observer = ScriptedAudioTrouble()
    let recorder = SessionRecorder(
        motionSensor: FixtureSensorService(fixture: fixture, clock: IndependenceClock()),
        pedometer: FixturePedometerService(fixture: fixture, clock: IndependenceClock()),
        audioFeedback: CountingAudio(),
        interruptionObserver: observer,
        screenSleep: SystemScreenSleepController(),
        clock: IndependenceClock(),
        logService: IndependenceLog(),
        fileIO: FileManagerFileIO()
    )

    _ = try await recorder.begin(mode: .quickTest, audioConfig: .stepFeedback)
    await observer.send(.audioInterrupted)
    await observer.send(.audioRouteChanged)
    await observer.send(.audioInterrupted)
    let buffer = try await recorder.stop()

    #expect(buffer.interruptionCount == 0, "audio trouble was counted as a recording interruption")
    #expect(buffer.series == cleanBuffer.series)

    let troubled = try await pipeline.analyze(buffer: buffer, baseline: nil, profile: nil, progress: { _ in })
    let reference = try await pipeline.analyze(buffer: cleanBuffer, baseline: nil, profile: nil, progress: { _ in })

    #expect(
        try snapshotBytes(SessionAnalysisResult(outcome: troubled, algorithmVersion: configuration.version))
            == snapshotBytes(SessionAnalysisResult(outcome: reference, algorithmVersion: configuration.version))
    )
}

// MARK: - The data path never awaits audio (ledger entry 25)

@Test func theDataPathNeverAwaitsAudio() async throws {
    // Every audio call stalls for thirty seconds — start tone, stop tone,
    // metronome start and stop, every tick. The session must still record,
    // freeze, hand off and score, and produce the same bytes as a silent run.
    let fixture = try goldenFixture(GoldenSignalSpec(seconds: 130), name: "wedged-everything")
    let configuration = AlgorithmConfiguration.v1
    let pipeline = GaitAnalysisPipeline(configuration: configuration)

    let clean = makeRecorder(fixture: fixture, audio: CountingAudio())
    _ = try await clean.begin(mode: .quickTest, audioConfig: .none)
    let cleanBuffer = try await clean.stop()

    let wedged = WedgedAudio()
    let recorder = makeRecorder(fixture: fixture, audio: wedged)

    // A metronome session, so stopMetronome is on the wedged list too.
    let began = await bounded { try await recorder.begin(mode: .quickTest, audioConfig: .metronome(cue: .fixture(bpm: 104))) }
    #expect(began != nil, "begin waited on the audio layer")

    let buffer = await bounded { try await recorder.stop() }
    let frozen = try #require(buffer, "stop waited on the audio layer")

    // Froze everything, and did not wait for a single audio call to return.
    #expect(frozen.series == cleanBuffer.series)
    #expect(await wedged.started > 0, "no audio was requested, so nothing was stalled")
    #expect(await wedged.finished == 0, "an audio call returned; the test proved nothing")

    // And it still scores, identically.
    let result = try await pipeline.analyze(buffer: frozen, baseline: nil, profile: nil, progress: { _ in })
    let reference = try await pipeline.analyze(buffer: cleanBuffer, baseline: nil, profile: nil, progress: { _ in })

    #expect(result.isValid)
    #expect(await wedged.finished == 0)
    #expect(
        try snapshotBytes(SessionAnalysisResult(outcome: result, algorithmVersion: configuration.version))
            == snapshotBytes(SessionAnalysisResult(outcome: reference, algorithmVersion: configuration.version))
    )
}

// MARK: - Helpers

/// Lets a test push audio trouble at the recorder as the real observer would.
private actor ScriptedAudioTrouble: SessionInterruptionObserver {
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

/// A replayable capture of the golden signal, so the recorder and the pipeline
/// are exercised on the same waveform the goldens use.
private func goldenFixture(_ spec: GoldenSignalSpec, name: String) throws -> GaitFixture {
    let samples = GoldenSignal.samples(for: spec).map { sample in
        GaitFixture.Sample(
            t: sample.deviceTimestamp,
            ax: sample.acceleration.x, ay: sample.acceleration.y, az: sample.acceleration.z,
            gx: sample.gravity?.x, gy: sample.gravity?.y, gz: sample.gravity?.z
        )
    }

    return GaitFixture(
        metadata: .init(
            name: name,
            sampleRateHz: GoldenSignal.sampleRate,
            deviceMotionIncluded: samples.first?.gx != nil
        ),
        samples: samples
    )
}

private func makeRecorder(fixture: GaitFixture, audio: AudioFeedbackService) -> SessionRecorder {
    let clock = IndependenceClock()
    return SessionRecorder(
        motionSensor: FixtureSensorService(fixture: fixture, clock: clock),
        pedometer: FixturePedometerService(fixture: fixture, clock: clock),
        audioFeedback: audio,
        interruptionObserver: SystemSessionInterruptionObserver(audioFeedback: SilentAudioFeedbackService()),
        screenSleep: SystemScreenSleepController(),
        clock: clock,
        logService: IndependenceLog(),
        fileIO: FileManagerFileIO()
    )
}

private func eventuallyStalled(_ audio: WedgedAudio) async -> Bool {
    for _ in 0..<100 {
        if await audio.startedTicks > 0 { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

/// Runs `work`, giving up after `seconds`.
///
/// A regression here would otherwise hang the suite rather than fail it: the
/// point of these tests is that a call *returns*, and the only way to assert
/// that is to bound the wait and treat the bound as a failure.
private func bounded<T: Sendable>(
    _ seconds: Double = 10,
    _ work: @escaping @Sendable () async throws -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { try? await work() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
