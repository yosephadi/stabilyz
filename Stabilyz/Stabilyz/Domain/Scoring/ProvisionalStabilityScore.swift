import Foundation

/// A within-walk stability score, computed **without** a baseline.
///
/// ## Why this type is separate from `SessionScore`
///
/// `SessionScore.relativeIndex` means "against your own baseline, where 100 is
/// your normal". This means something else entirely: a 0–100 reading of one
/// walk against fixed reference anchors, available from the very first session.
/// They are different scales with different referents, so they are different
/// types — History, the trend chart, the clinician summary and the export all
/// read `relativeIndex`, and a number from this scale reaching any of them
/// would put two incompatible units on one axis.
///
/// ## [OPEN] — this scale is a labelled placeholder
///
/// docs/08 §8.2 leaves the composite formula and index scaling deliberately
/// unspecified, and there is no normative distribution for this population in
/// the documents — establishing one per user is what the five calibration walks
/// are *for*. Every anchor this score is built on therefore lives in
/// `IntrinsicScorePolicy`, marked PROVISIONAL and pending device validation
/// (Phase 12), exactly like the composite weights and SD floors beside them.
///
/// Two consequences that are not optional:
///
/// - **It is framed as provisional wherever it is shown** [PRD §7 AC: "scores
///   shown before that point are explicitly framed as provisional/building,
///   not final"].
/// - **It is never presented as a comparison.** No "vs. baseline" delta, no
///   trend line, no place in History's series — those belong to the relative
///   index and begin at the sixth valid session [PRD §7].
///
/// ## What feeds it
///
/// Gait consistency, step-time variability and the trunk-motion proxy — the
/// three independent signals [PRD §7] names, weighted exactly as the composite
/// weights them, so gait consistency can never be the sole basis of this score
/// either. **Step-time asymmetry is not a term.** It is secondary, unilateral
/// only, and never merged into a composite as a hidden term [PRD §7, OQ-1] —
/// folding it in would also make the score mean different things for bilateral
/// and unilateral users.
struct ProvisionalStabilityScore: Sendable, Equatable, Codable {

    /// One signal's contribution.
    struct Contribution: Sendable, Equatable, Codable {
        let signal: SignalID
        /// How this signal read against its reference range, 0...1, oriented so
        /// higher is better.
        let quality: Double
        /// Its share of the score. The shares sum to 1.
        let weight: Double

        var contribution: Double { quality * weight }
    }

    /// 0...100, clamped by `IntrinsicScorePolicy.range`.
    let value: Int
    /// Every signal that fed it, in display order. Never empty.
    let contributions: [Contribution]
    /// The version the anchors and weights came from. A score is only readable
    /// under the configuration that produced it — the same rule that governs a
    /// baseline (docs/09 §9.6), and it matters more here because these anchors
    /// are explicitly expected to move.
    let algorithmVersion: String

    /// The best-reading signal of the walk, and the weakest.
    ///
    /// Nil when there is only one contribution, or when two tie — a claim that
    /// one signal stood out has to rest on one actually standing out.
    var strongest: SignalID? { extremes?.strongest }
    var weakest: SignalID? { extremes?.weakest }

    private var extremes: (strongest: SignalID, weakest: SignalID)? {
        guard contributions.count > 1,
              let best = contributions.max(by: { $0.quality < $1.quality }),
              let worst = contributions.min(by: { $0.quality < $1.quality }),
              best.quality > worst.quality
        else { return nil }
        return (best.signal, worst.signal)
    }
}
