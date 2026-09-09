import Foundation

/// The production `GaitScoringAlgorithm`: stages 2-6 composed (docs/08 §8.1).
///
/// Pure Swift, no Apple frameworks beyond Foundation. `SessionProcessor` is its
/// only caller, and view models never see the stages [PRD Rule 12].
///
/// Stages 7 and 8 run only when a same-mode baseline exists. Before that, a
/// valid session returns metrics with no score — docs/08 stage 7 skips, and
/// [PRD §7] shows no relative score until the sixth valid session anyway.
struct GaitAnalysisPipeline: GaitScoringAlgorithm {
    let configuration: AlgorithmConfiguration

    init(configuration: AlgorithmConfiguration = .v1) {
        self.configuration = configuration
    }

    var version: String { configuration.version }

    func analyze(
        buffer: RawSessionBuffer,
        baseline: Baseline?,
        profile: UserProfile?,
        progress: @Sendable (ProcessingProgress) -> Void
    ) async throws -> SessionAnalysisOutcome {
        // Stage 1 already ran: the recorder froze an aligned series.
        progress(ProcessingProgress(stage: .ingestion, fraction: 1 / 6))

        let series = Preprocessing.process(buffer.series, configuration: configuration)
        progress(ProcessingProgress(stage: .preprocessing, fraction: 2 / 6))

        let segmentation = WalkingSegmentDetector.detect(
            in: series,
            pedometerEvents: buffer.pedometerEvents,
            configuration: configuration
        )
        progress(ProcessingProgress(stage: .segmentation, fraction: 3 / 6))

        let quality = SignalQualityValidation.validate(
            series: series,
            segmentation: segmentation,
            buffer: buffer,
            configuration: configuration
        )
        progress(ProcessingProgress(stage: .quality, fraction: 4 / 6))

        // The gate. An invalid session is never scored [PRD AC], and the
        // duration it did manage is reported either way so the noisy screen can
        // explain itself.
        if let reason = quality.invalidReason {
            return .invalid(reason: reason, validWalkingDuration: quality.validWalkingDuration)
        }

        let features = FeatureExtraction.extract(
            series: series,
            segmentation: segmentation,
            configuration: configuration
        )
        progress(ProcessingProgress(stage: .features, fraction: 5 / 6))

        // Stride sufficiency is stage 5's own gate: never produce metrics from
        // too little data (docs/08).
        if let reason = FeatureExtraction.strideShortfallReason(features, configuration: configuration) {
            return .invalid(reason: reason, validWalkingDuration: quality.validWalkingDuration)
        }

        guard let metrics = MetricAssembly.assemble(
            features: features,
            segmentation: segmentation,
            buffer: buffer,
            profile: profile,
            configuration: configuration
        ) else {
            return .invalid(reason: .insufficientValidWalking, validWalkingDuration: quality.validWalkingDuration)
        }
        progress(ProcessingProgress(stage: .metrics, fraction: 5 / 6))

        // Stages 7 and 8. Absent a baseline there is nothing to compare
        // against, and inventing a comparison would be worse than showing none.
        let standardization = try BaselineNormalization.standardize(
            metrics: metrics,
            mode: buffer.mode,
            against: baseline,
            configuration: configuration
        )
        progress(ProcessingProgress(stage: .normalization, fraction: 11 / 12))

        var score: PartialSessionScore?
        if let standardization {
            let scored = CompositeScorer.score(
                standardization,
                metrics: metrics,
                sessionAlgorithmVersion: configuration.version,
                configuration: configuration
            )
            score = scored.score
        }
        progress(ProcessingProgress(stage: .scoring, fraction: 1))

        return .valid(
            metrics: metrics,
            validWalkingDuration: quality.validWalkingDuration,
            score: score
        )
    }
}
