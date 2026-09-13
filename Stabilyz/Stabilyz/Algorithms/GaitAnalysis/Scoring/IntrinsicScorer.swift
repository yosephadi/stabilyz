import Foundation

/// Scores one walk on its own, with no baseline to stand it against
/// (`ProvisionalStabilityScore`).
///
/// Pure, and the counterpart to `CompositeScorer`: that one turns *standardized*
/// metrics into a relative index, this one turns *raw* metrics into a 0–100
/// reading against the fixed anchors in `IntrinsicScorePolicy`. They share the
/// weights deliberately, so the same three signals carry the same shares on
/// both scales.
///
/// **The anchors are a labelled `[OPEN]` placeholder**, not a validated scale —
/// see `IntrinsicScorePolicy` and `ProvisionalStabilityScore`. What this type
/// guarantees regardless of what the numbers become: the score is built from
/// the three independent signals [PRD §7] names, never from step-time asymmetry,
/// and never from gait consistency alone.
enum IntrinsicScorer {

    /// The signals that carry the score, in display order, each with the
    /// composite terms whose weight it inherits.
    ///
    /// Gait consistency takes both regularity terms — half the score — and the
    /// other half comes from variability and trunk motion, which is exactly the
    /// split `CompositePolicy` already draws. `cadence` and `stepTimeAsymmetry`
    /// are absent: neither is a composite term, and neither carries a decided
    /// sign convention to be scored on (docs/decisions.md entry 3).
    static let scoringSignals: [(signal: SignalID, terms: [CompositeTerm])] = [
        (.gaitConsistency, [.stepRegularity, .strideRegularity]),
        (.stepTimeVariability, [.stepTimeCV]),
        (.trunkMotion, [.trunkProxy])
    ]

    /// - Returns: nil when any signal's metrics cannot be read against the
    ///   policy — a missing anchor, a missing measurement, a degenerate range.
    ///   **No renormalisation over the surviving signals**, for the same reason
    ///   `CompositeScorer` refuses it: spreading a missing signal's weight
    ///   across the others would silently change what the remaining weights
    ///   mean, and present a two-signal score on a three-signal scale.
    static func score(
        _ metrics: GaitMetrics,
        algorithmVersion: String,
        configuration: AlgorithmConfiguration
    ) -> ProvisionalStabilityScore? {
        var contributions: [ProvisionalStabilityScore.Contribution] = []

        for (signal, terms) in scoringSignals {
            guard let quality = quality(of: signal, metrics: metrics, configuration: configuration) else {
                return nil
            }
            let weight = terms.reduce(0) { $0 + configuration.composite.weight(for: $1) }
            guard weight > 0 else { return nil }

            contributions.append(
                ProvisionalStabilityScore.Contribution(
                    signal: signal,
                    quality: quality,
                    weight: weight
                )
            )
        }

        // The weights sum to 1 (asserted in the configuration tests), so this is
        // a weighted mean of qualities already in 0...1 — the 0-100 scale is the
        // mean scaled, not a second mapping on top of one.
        let weighted = contributions.reduce(0) { $0 + $1.contribution }
        let range = configuration.intrinsic.range
        let clamped = min(max((weighted * 100).rounded(), Double(range.lowerBound)), Double(range.upperBound))

        return ProvisionalStabilityScore(
            value: Int(clamped),
            contributions: contributions,
            algorithmVersion: algorithmVersion
        )
    }

    /// A signal's reading, 0...1. The mean of its metrics' readings — the same
    /// treatment the composite gives the trunk proxy's two axes
    /// (docs/decisions.md entry 1), applied uniformly so no signal is a special
    /// case.
    private static func quality(
        of signal: SignalID,
        metrics: GaitMetrics,
        configuration: AlgorithmConfiguration
    ) -> Double? {
        let readings = signal.metrics.compactMap { metric -> Double? in
            guard let raw = metrics.value(for: metric),
                  let reference = configuration.intrinsic.reference(for: metric)
            else { return nil }
            return reference.quality(of: raw)
        }

        // Every metric of the signal, or none of it: half a trunk proxy is not
        // a trunk proxy.
        guard readings.count == signal.metrics.count, !readings.isEmpty else { return nil }
        return readings.reduce(0, +) / Double(readings.count)
    }
}
