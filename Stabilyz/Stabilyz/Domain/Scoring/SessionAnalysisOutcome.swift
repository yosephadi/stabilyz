import Foundation

/// Which pipeline stage is running, for progress reporting (docs/08, docs/14 §14.3).
///
/// Named after the docs/08 stages so a signpost trace lines up with the design.
enum ProcessingStage: String, Sendable, CaseIterable {
    case ingestion
    case preprocessing
    case segmentation
    case quality
    case features
    case metrics
    case normalization
    case scoring
}

/// A chunked progress update for the Processing screen (docs/14 §14.3).
///
/// The heaviest work in the app is autocorrelation over lags × windows, so the
/// pipeline reports as it goes rather than blocking on a single opaque call.
struct ProcessingProgress: Sendable, Equatable {
    let stage: ProcessingStage
    /// Overall completion, 0...1.
    let fraction: Double

    init(stage: ProcessingStage, fraction: Double) {
        self.stage = stage
        self.fraction = min(max(fraction, 0), 1)
    }
}

/// What the pipeline concluded about a session (docs/08).
///
/// One or the other — never both, never neither (docs/11 §11.3). Both carry the
/// valid walking duration, because the session record stores it either way and
/// the noisy screen explains itself with it.
enum SessionAnalysisOutcome: Sendable, Equatable {
    /// Scoreable. `score` is present only when a same-mode baseline existed
    /// [PRD §7]; stages 7-8 skip when it did not. It is **partial** — the
    /// commit step completes it with a summary line (entry 20).
    ///
    /// `provisional` is the other scale, and the two are independent: it is
    /// computed from raw metrics alone, so it is present whenever the metrics
    /// are readable, baseline or no baseline. It is what sessions 1-5 show, and
    /// it never becomes a comparison — see `ProvisionalStabilityScore`.
    case valid(
        metrics: GaitMetrics,
        validWalkingDuration: Duration,
        score: PartialSessionScore?,
        provisional: ProvisionalStabilityScore?
    )
    /// Not scoreable, and never scored [PRD AC].
    case invalid(reason: InvalidReason, validWalkingDuration: Duration)

    var isValid: Bool {
        switch self {
        case .valid: true
        case .invalid: false
        }
    }

    var validWalkingDuration: Duration {
        switch self {
        case .valid(_, let duration, _, _): duration
        case .invalid(_, let duration): duration
        }
    }
}

/// An analysis stamped with the algorithm that produced it.
///
/// The version travels with every result because a baseline is only comparable
/// under the version it was computed with (docs/09 §9.6), and [PRD] requires the
/// algorithm version in the export.
struct SessionAnalysisResult: Sendable, Equatable {
    let outcome: SessionAnalysisOutcome
    let algorithmVersion: String
}
