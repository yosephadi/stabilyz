import Foundation
import Testing
@testable import Stabilyz

// MARK: - Doubles

private final class ProcessorLog: LogService, @unchecked Sendable {
    let entries = Locked<[String]>([])
    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        entries.withLock { $0.append(message) }
    }
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 1)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

/// The deterministic stub from docs/12 §12.2: fixed outputs, no computation.
private struct StubAlgorithm: GaitScoringAlgorithm {
    var version = "test-1.0.0"
    var outcome: SessionAnalysisOutcome = .valid(
        metrics: .fixture(),
        validWalkingDuration: .seconds(95),
        score: nil
    )
    var error: (any Error)?
    var reportedStages: [ProcessingStage] = []
    /// Holds the run open so a test can cancel while it is genuinely in flight.
    var delay: Duration?
    /// Records what the algorithm was handed, so the contract can be asserted.
    let received = Locked<(buffer: RawSessionBuffer?, baseline: Baseline?)>((nil, nil))

    func analyze(
        buffer: RawSessionBuffer,
        baseline: Baseline?,
        progress: @Sendable (ProcessingProgress) -> Void
    ) async throws -> SessionAnalysisOutcome {
        received.withLock { $0 = (buffer, baseline) }
        if let delay {
            // try? so cancellation does not surface as CancellationError here:
            // the point is that the *processor* notices and reports it.
            try? await Task.sleep(for: delay)
        }
        for (index, stage) in reportedStages.enumerated() {
            progress(ProcessingProgress(stage: stage, fraction: Double(index + 1) / Double(reportedStages.count)))
        }
        if let error { throw error }
        return outcome
    }
}

private let anchor = TimeAnchor(wallClock: Date(timeIntervalSince1970: 1_700_000_000), uptime: 1_000)

private func sample(_ offset: Double) -> SensorSample {
    SensorSample(
        deviceTimestamp: anchor.uptime + offset,
        anchor: anchor,
        acceleration: Vector3(x: 0, y: 0, z: 1)
    )
}

private func makeBuffer(mode: TestMode = .quickTest, sampleCount: Int = 100) -> RawSessionBuffer {
    let samples = (0..<sampleCount).map { sample(Double($0) / 100) }
    return RawSessionBuffer(
        mode: mode,
        audioConfig: .none,
        anchor: anchor,
        series: SampleIngestion.align(samples, sampleRateHz: 100, policy: AlgorithmConfiguration.v1.gapDetection),
        pedometerEvents: [],
        startedAt: anchor.wallClock,
        endedAt: anchor.wallClock.addingTimeInterval(120),
        advertisedClockElapsed: .seconds(120),
        interruptionCount: 0,
        pedometerAvailable: true
    )
}

// MARK: - Version stamping

@Test func everyResultCarriesTheAlgorithmVersion() async throws {
    // [PRD] the export requires it, and a baseline is only comparable under the
    // version it was computed with (docs/09 §9.6).
    let processor = SessionProcessor(algorithm: StubAlgorithm(version: "2.1.0"), logService: ProcessorLog())

    let result = try await processor.process(buffer: makeBuffer(), baseline: nil)

    #expect(result.algorithmVersion == "2.1.0")
    #expect(processor.algorithmVersion == "2.1.0")
}

@Test func anInvalidOutcomeIsStampedToo() async throws {
    let algorithm = StubAlgorithm(
        version: "2.1.0",
        outcome: .invalid(reason: .excessiveNoise, validWalkingDuration: .seconds(40))
    )
    let processor = SessionProcessor(algorithm: algorithm, logService: ProcessorLog())

    let result = try await processor.process(buffer: makeBuffer(), baseline: nil)

    #expect(result.algorithmVersion == "2.1.0")
    #expect(result.outcome == .invalid(reason: .excessiveNoise, validWalkingDuration: .seconds(40)))
}

// MARK: - Mode segregation [PRD OQ-5]

@Test func aBaselineFromAnotherModeNeverReachesTheAlgorithm() async {
    let algorithm = StubAlgorithm()
    let processor = SessionProcessor(algorithm: algorithm, logService: ProcessorLog())

    await #expect(throws: StabilyzError.processing(.baselineModeMismatch)) {
        _ = try await processor.process(
            buffer: makeBuffer(mode: .quickTest),
            baseline: .fixture(mode: .fullTest)
        )
    }

    // The algorithm was never called, so no cross-mode comparison could occur.
    #expect(algorithm.received.withLock { $0.buffer } == nil)
}

@Test func aMatchingBaselineIsPassedThrough() async throws {
    let algorithm = StubAlgorithm()
    let processor = SessionProcessor(algorithm: algorithm, logService: ProcessorLog())
    let baseline = Baseline.fixture(mode: .fullTest)

    _ = try await processor.process(buffer: makeBuffer(mode: .fullTest), baseline: baseline)

    #expect(algorithm.received.withLock { $0.baseline } == baseline)
}

@Test func aMissingBaselineIsPassedThroughAsNil() async throws {
    // Pre-baseline sessions still produce metrics; stages 7-8 are skipped
    // (docs/08 stage 7).
    let algorithm = StubAlgorithm()
    let processor = SessionProcessor(algorithm: algorithm, logService: ProcessorLog())

    let result = try await processor.process(buffer: makeBuffer(), baseline: nil)

    #expect(algorithm.received.withLock { $0.baseline } == nil)
    #expect(result.outcome.isValid)
}

// MARK: - Empty buffer (docs/08 stage 1)

@Test func anEmptyBufferIsASensorFailureAndSkipsTheAlgorithm() async throws {
    let algorithm = StubAlgorithm()
    let processor = SessionProcessor(algorithm: algorithm, logService: ProcessorLog())

    let result = try await processor.process(buffer: makeBuffer(sampleCount: 0), baseline: nil)

    #expect(result.outcome == .invalid(reason: .sensorFailure, validWalkingDuration: .zero))
    #expect(result.algorithmVersion == "test-1.0.0")
    #expect(algorithm.received.withLock { $0.buffer } == nil)
}

// MARK: - Progress (docs/14 §14.3)

@Test func progressIsReportedAsStagesComplete() async throws {
    let algorithm = StubAlgorithm(reportedStages: [.preprocessing, .segmentation, .quality, .features])
    let processor = SessionProcessor(algorithm: algorithm, logService: ProcessorLog())

    let collector = Task {
        var seen: [ProcessingProgress] = []
        for await update in processor.progressUpdates {
            seen.append(update)
            if update.fraction >= 1 { break }
        }
        return seen
    }

    _ = try await processor.process(buffer: makeBuffer(), baseline: nil)
    let seen = await collector.value

    #expect(seen.isEmpty == false)
    #expect(seen.last?.fraction == 1)
    #expect(seen.map(\.fraction) == seen.map(\.fraction).sorted())
}

@Test func progressFractionIsClampedToTheUnitRange() {
    #expect(ProcessingProgress(stage: .scoring, fraction: 1.5).fraction == 1)
    #expect(ProcessingProgress(stage: .scoring, fraction: -0.2).fraction == 0)
}

@Test func stagesCoverTheDocumentedPipeline() {
    // docs/08 lists eight stages; a missing one means an unreportable step.
    #expect(Set(ProcessingStage.allCases.map(\.rawValue)) == [
        "ingestion", "preprocessing", "segmentation", "quality",
        "features", "metrics", "normalization", "scoring"
    ])
}

// MARK: - Failure propagation

@Test func anAlgorithmFailurePropagatesRatherThanBecomingAFakeResult() async {
    let algorithm = StubAlgorithm(error: StabilyzError.processing(.tooFewStrides))
    let processor = SessionProcessor(algorithm: algorithm, logService: ProcessorLog())

    await #expect(throws: StabilyzError.processing(.tooFewStrides)) {
        _ = try await processor.process(buffer: makeBuffer(), baseline: nil)
    }
}

@Test func aCancelledRunThrowsRatherThanReturningHalfProcessedWork() async throws {
    // docs/14 §14.3: never a half-processed result. The algorithm is held open
    // so the cancellation lands mid-run rather than racing the stub.
    let processor = SessionProcessor(
        algorithm: StubAlgorithm(delay: .milliseconds(500)),
        logService: ProcessorLog()
    )
    let buffer = makeBuffer()

    let task = Task {
        try await processor.process(buffer: buffer, baseline: nil)
    }
    try await Task.sleep(for: .milliseconds(50))
    task.cancel()

    await #expect(throws: StabilyzError.processing(.cancelled)) {
        _ = try await task.value
    }
}

@Test func anUncancelledRunCompletesNormally() async throws {
    // Guards the test above: the delay alone must not produce a cancellation.
    let processor = SessionProcessor(
        algorithm: StubAlgorithm(delay: .milliseconds(20)),
        logService: ProcessorLog()
    )

    let result = try await processor.process(buffer: makeBuffer(), baseline: nil)
    #expect(result.outcome.isValid)
}

// MARK: - Outcome shape

@Test func anOutcomeIsValidOrInvalidNeverBoth() {
    // docs/11 §11.3: routes to Score or Noisy, never both, never neither.
    let valid = SessionAnalysisOutcome.valid(metrics: .fixture(), validWalkingDuration: .seconds(95), score: nil)
    let invalid = SessionAnalysisOutcome.invalid(reason: .excessiveNoise, validWalkingDuration: .seconds(30))

    #expect(valid.isValid)
    #expect(invalid.isValid == false)
    #expect(valid.validWalkingDuration == .seconds(95))
    #expect(invalid.validWalkingDuration == .seconds(30))
}
