import Foundation
import Testing
@testable import Stabilyz

// Minimal in-memory conformances. These exist to prove the Task 1.2.1 protocol
// surface is expressible and usable; the real test doubles arrive with the
// implementations (docs/12 §12.2).

private struct FixtureMotionSensorService: MotionSensorService {
    let samples: [SensorSample]
    var isAvailable: Bool { true }
    var authorizationStatus: MotionAuthorizationStatus { get async { .authorized } }

    func requestAuthorization() async -> MotionAuthorizationStatus { .authorized }

    func start(policy: MotionAcquisitionPolicy) async throws -> AsyncStream<SensorSample> {
        AsyncStream { continuation in
            for sample in samples { continuation.yield(sample) }
            continuation.finish()
        }
    }

    func stop() async {}
}

private struct ScriptedPedometerService: PedometerService {
    let scripted: [PedometerEvent]
    var isAvailable: Bool { true }

    func start() async throws -> AsyncStream<PedometerEvent> {
        AsyncStream { continuation in
            for event in scripted { continuation.yield(event) }
            continuation.finish()
        }
    }

    func stop() async {}

    func events(from start: Date, to end: Date) async throws -> PedometerEvent? {
        scripted.last { $0.timestamp >= start && $0.timestamp <= end }
    }
}

private actor SpyAudioFeedbackService: AudioFeedbackService {
    private(set) var calls: [String] = []
    private let continuation: AsyncStream<AudioFeedbackEvent>.Continuation
    nonisolated let events: AsyncStream<AudioFeedbackEvent>

    init() {
        var captured: AsyncStream<AudioFeedbackEvent>.Continuation!
        events = AsyncStream { captured = $0 }
        continuation = captured
    }

    func playStartTone() async { calls.append("start") }
    func playStopTone() async { calls.append("stop") }
    func playStepTick() async { calls.append("tick") }
    func startMetronome(bpm: Double) async { calls.append("metronome:\(bpm)") }
    func stopMetronome() async { calls.append("metronomeOff") }
    func suspend() async { calls.append("suspend") }
    func resume() async { calls.append("resume") }

    /// Lets a test inject a route change the way the real service reports one.
    nonisolated func emit(_ event: AudioFeedbackEvent) { continuation.yield(event) }
}

private struct FixedClock: Clock {
    let now: Date
    let uptime: TimeInterval
}

private struct CountingRandomSource: RandomSource {
    func bytes(count: Int) throws -> [UInt8] { (0..<count).map { UInt8($0 % 256) } }
}

private actor InMemoryBaselineRepository: BaselineRepository {
    private var storage: [TestMode: Baseline] = [:]

    struct DuplicateBaseline: Error {}

    func baseline(mode: TestMode) async throws -> Baseline? { storage[mode] }

    func save(_ baseline: Baseline) async throws {
        guard storage[baseline.mode] == nil else { throw DuplicateBaseline() }
        storage[baseline.mode] = baseline
    }

    func allBaselines() async throws -> [Baseline] {
        TestMode.allCases.compactMap { storage[$0] }
    }
}

// MARK: - Tests

@Test func motionServiceStreamsSamples() async throws {
    let anchor = TimeAnchor(wallClock: Date(timeIntervalSince1970: 1_000), uptime: 500)
    let service = FixtureMotionSensorService(samples: [
        SensorSample(deviceTimestamp: 0.00, anchor: anchor, acceleration: Vector3(x: 0, y: 0, z: -1)),
        SensorSample(deviceTimestamp: 0.01, anchor: anchor, acceleration: Vector3(x: 0, y: 0, z: -1))
    ])

    var received: [SensorSample] = []
    for await sample in try await service.start(policy: .recommendedDefault) {
        received.append(sample)
    }

    #expect(received.count == 2)
    #expect(received.first?.deviceTimestamp == 0.00)
    #expect(received.first?.gravity == nil)
}

@Test func pedometerHistoricalQueryFindsEventInWindow() async throws {
    let base = Date(timeIntervalSince1970: 1_000)
    let service = ScriptedPedometerService(scripted: [
        PedometerEvent(steps: 10, timestamp: base),
        PedometerEvent(steps: 25, timestamp: base.addingTimeInterval(60))
    ])

    let inWindow = try await service.events(from: base, to: base.addingTimeInterval(30))
    #expect(inWindow?.steps == 10)

    let outsideWindow = try await service.events(from: base.addingTimeInterval(120), to: base.addingTimeInterval(180))
    #expect(outsideWindow == nil)
}

@Test func audioServiceRecordsCallsAndReportsRouteEvents() async throws {
    let service = SpyAudioFeedbackService()
    await service.playStartTone()
    await service.startMetronome(bpm: 108)
    await service.playStopTone()

    #expect(await service.calls == ["start", "metronome:108.0", "stop"])

    service.emit(.routeChanged)
    var iterator = service.events.makeAsyncIterator()
    #expect(await iterator.next() == .routeChanged)
}

@Test func fixedClockIsDeterministic() {
    let clock = FixedClock(now: Date(timeIntervalSince1970: 1_000), uptime: 42)
    #expect(clock.now == Date(timeIntervalSince1970: 1_000))
    #expect(clock.uptime == 42)
}

@Test func randomSourceReturnsRequestedByteCount() throws {
    let source = CountingRandomSource()
    // 16-byte salt and 12-byte nonce are the sizes docs/13 §13.1 requires.
    #expect(try source.bytes(count: 16).count == 16)
    #expect(try source.bytes(count: 12).count == 12)
}

@Test func baselineRepositoryEnforcesOneBaselinePerMode() async throws {
    let repository = InMemoryBaselineRepository()
    let quick = Baseline.fixture(mode: .quickTest)
    try await repository.save(quick)

    await #expect(throws: InMemoryBaselineRepository.DuplicateBaseline.self) {
        try await repository.save(Baseline.fixture(mode: .quickTest))
    }

    // Modes are segregated: a fullTest baseline is unaffected [PRD OQ-5].
    try await repository.save(Baseline.fixture(mode: .fullTest))
    #expect(try await repository.allBaselines().count == 2)
    #expect(try await repository.baseline(mode: .quickTest)?.id == quick.id)
}
