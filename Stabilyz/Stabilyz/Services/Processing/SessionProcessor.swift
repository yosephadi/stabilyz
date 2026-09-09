import Foundation

/// Runs the gait pipeline off the main actor (docs/08, docs/14 §14.2).
///
/// An actor that orchestrates; the computation itself lives behind the
/// `GaitScoringAlgorithm` contract in `Algorithms/GaitAnalysis`. No DSP here
/// and none above it [PRD Rule 12] — the UI thread never executes pipeline work.
///
/// Created once and shared, like the recorder (docs/12 §12.3).
actor SessionProcessor {
    private let algorithm: GaitScoringAlgorithm
    private let logService: LogService

    /// Chunked progress for the Processing screen (docs/14 §14.3).
    ///
    /// Long-lived and shared so the screen subscribes once. Buffers newest: a
    /// slow observer must never hold up the pipeline, and a stale progress
    /// fraction is worthless anyway.
    nonisolated let progressUpdates: AsyncStream<ProcessingProgress>
    private nonisolated let progressContinuation: AsyncStream<ProcessingProgress>.Continuation

    init(algorithm: GaitScoringAlgorithm, logService: LogService) {
        self.algorithm = algorithm
        self.logService = logService

        let (stream, continuation) = AsyncStream<ProcessingProgress>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        progressUpdates = stream
        progressContinuation = continuation
    }

    /// The version every result produced by this processor is stamped with.
    nonisolated var algorithmVersion: String { algorithm.version }

    /// Analyses a frozen recording against its own mode's baseline.
    ///
    /// - Throws: `StabilyzError.processing(.cancelled)` if the run is cancelled.
    ///   docs/14 §14.3 requires a cancelled run to leave an invalid session
    ///   rather than a half-processed one; choosing which `InvalidReason` to
    ///   persist is the session flow's call (Task 8.2.3), so this surfaces the
    ///   cancellation rather than inventing a PRD reason code.
    func process(
        buffer: RawSessionBuffer,
        baseline: Baseline?,
        profile: UserProfile? = nil
    ) async throws -> SessionAnalysisResult {
        // A session is only ever compared with its own mode's baseline
        // [PRD OQ-5]. Checked here because this is the one place the two meet.
        if let baseline, baseline.mode != buffer.mode {
            logService.log(.error, .processing, "refused: baseline mode does not match session mode")
            throw StabilyzError.processing(.baselineModeMismatch)
        }

        // docs/08 stage 1: an empty buffer is a sensor failure, not something
        // to hand to the algorithm.
        guard !buffer.isEmpty else {
            logService.log(.info, .processing, "session invalid: empty buffer")
            return SessionAnalysisResult(
                outcome: .invalid(reason: .sensorFailure, validWalkingDuration: .zero),
                algorithmVersion: algorithm.version
            )
        }

        try checkCancellation()

        let continuation = progressContinuation
        let interval = logService.beginInterval("session-processing", category: .processing)
        defer { logService.endInterval(interval) }

        let outcome = try await algorithm.analyze(
            buffer: buffer,
            baseline: baseline,
            profile: profile,
            progress: { continuation.yield($0) }
        )

        try checkCancellation()

        switch outcome {
        case .valid(_, let duration, let score):
            logService.log(
                .info,
                .processing,
                "session valid: mode=\(buffer.mode.rawValue) validWalking=\(Int(duration.components.seconds))s scored=\(score != nil)"
            )
        case .invalid(let reason, let duration):
            logService.log(
                .info,
                .processing,
                "session invalid: mode=\(buffer.mode.rawValue) reason=\(reason.rawValue) validWalking=\(Int(duration.components.seconds))s"
            )
        }

        return SessionAnalysisResult(outcome: outcome, algorithmVersion: algorithm.version)
    }

    /// A cancelled run must not return a half-processed result (docs/14 §14.3).
    private func checkCancellation() throws {
        if Task.isCancelled {
            logService.log(.warning, .processing, "processing cancelled")
            throw StabilyzError.processing(.cancelled)
        }
    }
}
