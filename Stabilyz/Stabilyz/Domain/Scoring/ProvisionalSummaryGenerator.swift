import Foundation

/// The one-line summary beside a **pre-baseline** score.
///
/// `SessionSummaryGenerator` is the post-baseline one and returns nil here on
/// purpose: its whole contract is comparison, and before a baseline exists
/// there is nothing to compare against. This says something different — what
/// *this walk* was like, from the signals that were actually measured.
///
/// The three rules that govern the other generator govern this one, and one is
/// sharper here:
///
/// - **No percentage claim** [PRD §5, §7]. The score is on an unvalidated
///   0–100 placeholder scale; describing it in percent would be a real-world
///   claim twice over.
/// - **No improvement claim.** There is no history to have improved from. This
///   describes a single walk and nothing else.
/// - **Nothing implying the baseline is permanent or already here** [PRD §6].
///   The copy names the baseline as something still being built.
enum ProvisionalSummaryGenerator {

    /// What the line was able to say, kept separate from the words so tests can
    /// assert the decision rather than string-matching copy.
    enum Claim: String, Sendable, Equatable {
        /// One signal read clearly best and another clearly worst.
        case contrast
        /// Nothing stood out — every signal read alike.
        case even
    }

    struct Summary: Sendable, Equatable {
        let text: String
        let claim: Claim
        /// The signals the line rests on, when it names any.
        let strongest: SignalID?
        let weakest: SignalID?
    }

    /// - Parameter score: the walk's provisional score. Its contributions are
    ///   the evidence — a line that named a signal the score was not built from
    ///   would be the static string [PRD] rules out.
    static func summary(mode: TestMode, score: ProvisionalStabilityScore) -> Summary {
        guard let strongest = score.strongest,
              let weakest = score.weakest,
              let strongestLabel = label(strongest),
              let weakestLabel = label(weakest)
        else {
            return Summary(
                text: """
                Your \(mode.displayName) measured evenly across every signal. \
                Four more walks like it and your personal baseline is ready.
                """,
                claim: .even,
                strongest: nil,
                weakest: nil
            )
        }

        return Summary(
            // Descriptive, not evaluative: "steadiest" and "varied most" are
            // statements about this walk's own readings, where "best" and
            // "worst" would imply a standard the score does not have.
            text: """
            \(strongestLabel.capitalizedFirst) was the steadiest part of this \
            walk; \(weakestLabel) varied the most.
            """,
            claim: .contrast,
            strongest: strongest,
            weakest: weakest
        )
    }

    /// The user-facing signal names, which are the Score screen's [PRD OQ-1]
    /// vocabulary — "gait consistency", never "symmetry".
    ///
    /// Nil for the two signals that carry no score. Neither can reach here —
    /// `IntrinsicScorer.scoringSignals` excludes both, so no contribution ever
    /// names them — and nil rather than a label is what keeps the reserved term
    /// out of this file altogether. A line that could not name its signals
    /// falls back to the even one rather than inventing a way to say it.
    private static func label(_ signal: SignalID) -> String? {
        switch signal {
        case .gaitConsistency: "your gait consistency"
        case .stepTimeVariability: "your step rhythm"
        case .trunkMotion: "your trunk movement"
        case .cadence, .stepTimeAsymmetry: nil
        }
    }
}

private extension String {
    /// Sentence case without touching the rest of the string — the labels are
    /// already correctly cased and `capitalized` would retitle them.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
