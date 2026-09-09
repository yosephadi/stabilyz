import Foundation

/// Pipeline stage 8: standardized metrics become one relative index
/// (docs/08, docs/09 §9.5).
///
/// Pure. Every term is direction-adjusted before weighting, so **a higher
/// composite always means more stable** regardless of which way the underlying
/// metric points.
enum CompositeScorer {
    /// Why a valid session carries no score.
    ///
    /// A session without a score is still a valid session with real metrics
    /// [PRD §5 — shown as reference]. These are recorded rather than swallowed.
    enum ScoreUnavailability: String, Sendable, Equatable {
        /// One of the four terms had no standardized value.
        case missingCompositeTerm
        /// The session and the baseline were computed under different algorithm
        /// versions, so the comparison would be meaningless (docs/09 §9.6).
        case algorithmVersionMismatch
    }

    struct ScoringResult: Sendable, Equatable {
        let score: SessionScore?
        let unavailability: ScoreUnavailability?
        /// The four terms that fed the composite, for the breakdown in
        /// Task 6.2.3. Empty when no score was produced.
        let terms: [CompositeTermValue]
    }

    /// One weighted term of the composite.
    struct CompositeTermValue: Sendable, Equatable {
        let term: CompositeTerm
        /// Direction-adjusted, so positive is better.
        let adjustedZ: Double
        let weight: Double
        var contribution: Double { adjustedZ * weight }
    }

    /// - Parameter sessionAlgorithmVersion: the version this session's metrics
    ///   were computed under. Compared against the baseline's.
    static func score(
        _ standardization: SessionStandardization,
        sessionAlgorithmVersion: String,
        configuration: AlgorithmConfiguration
    ) -> ScoringResult {
        // Defensive in v1, which ships one algorithm version. Same class as the
        // baseline's own mixed-version refusal (docs/decisions.md entry 17):
        // comparing across versions would produce a number that looks fine and
        // means nothing.
        guard standardization.algorithmVersion == sessionAlgorithmVersion else {
            return ScoringResult(score: nil, unavailability: .algorithmVersionMismatch, terms: [])
        }

        guard let terms = terms(from: standardization, configuration: configuration) else {
            // No renormalisation over surviving terms. Spreading a missing
            // term's weight across the others would silently change what the
            // remaining weights mean — a three-term score presented on the same
            // scale as a four-term one.
            return ScoringResult(score: nil, unavailability: .missingCompositeTerm, terms: [])
        }

        // Weights sum to 1 (asserted in configuration tests), so this is a
        // weighted mean.
        let composite = terms.reduce(0) { $0 + $1.contribution }

        return ScoringResult(
            score: SessionScore(
                relativeIndex: configuration.composite.relativeIndex(forCompositeZ: composite),
                compositeZ: composite,
                algorithmVersion: standardization.algorithmVersion
            ),
            unavailability: nil,
            terms: terms
        )
    }

    /// The four terms, or nil if any is unavailable.
    ///
    /// `stepTimeAsymmetry` is deliberately not among them: it is computed,
    /// stored and displayed separately, never merged into the composite
    /// (docs/decisions.md entries 2 and 13).
    static func terms(
        from standardization: SessionStandardization,
        configuration: AlgorithmConfiguration
    ) -> [CompositeTermValue]? {
        var values: [CompositeTermValue] = []

        for term in CompositeTerm.allCases {
            guard let adjusted = adjustedZ(for: term, in: standardization) else { return nil }
            values.append(
                CompositeTermValue(
                    term: term,
                    adjustedZ: adjusted,
                    weight: configuration.composite.weight(for: term)
                )
            )
        }
        return values
    }

    private static func adjustedZ(
        for term: CompositeTerm,
        in standardization: SessionStandardization
    ) -> Double? {
        switch term {
        case .stepRegularity:
            return standardization.standardization(for: .stepRegularity)?.directionAdjustedZ
        case .strideRegularity:
            return standardization.standardization(for: .strideRegularity)?.directionAdjustedZ
        case .stepTimeCV:
            return standardization.standardization(for: .stepTimeCV)?.directionAdjustedZ
        case .trunkProxy:
            // One term from two axes: the mean of their adjusted z-scores
            // (docs/decisions.md entry 1). Both are required — half a trunk
            // proxy is not a trunk proxy.
            guard let ml = standardization.standardization(for: .trunkMotionML)?.directionAdjustedZ,
                  let vt = standardization.standardization(for: .trunkMotionVT)?.directionAdjustedZ
            else { return nil }
            return (ml + vt) / 2
        }
    }
}
