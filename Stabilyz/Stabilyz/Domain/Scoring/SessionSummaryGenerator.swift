import Foundation

/// Generates the one-to-two sentence summary shown beside a score
/// (docs/04 §4.9, [PRD AC]).
///
/// **Pure domain engine.** No persistence knowledge, no clock, no randomness —
/// the same inputs always produce the same sentence.
///
/// Every template has a data predicate, and a slot is filled only from a
/// comparison that was actually made. [PRD] requires the summary be "generated
/// from real metric comparisons within the same mode, not a static string", so
/// a claim that could appear without its evidence would be the whole point
/// missed.
///
/// Three rules the copy must never break:
/// - **No percentage claim** [PRD §5, §7]. The composite is not calibrated to
///   support "12% more stable", so the summary never quantifies in percent.
/// - **No improvement claim without an improvement.** Encouraging is not the
///   same as flattering; a user told they improved when they did not cannot
///   trust the one that says they did.
/// - **Nothing implying the baseline is permanent** [PRD §6]. It is a snapshot
///   of five early sessions, not a verdict.
enum SessionSummaryGenerator {
    /// What the summary was able to say, kept separate from the sentence so
    /// tests can assert the *decision* rather than string-matching copy.
    enum Claim: String, Sendable, Equatable {
        /// Above baseline and a signal measurably improved.
        case aboveBaselineWithImprovement
        /// A signal measurably improved, but the index did not rise.
        case improvementOnly
        /// Above baseline with no single signal standing out.
        case aboveBaseline
        /// Within the margin either side of baseline.
        case aroundUsual
        /// Below baseline, stated plainly.
        case belowBaseline
        /// Nothing comparable — the honest neutral line.
        case neutral
    }

    struct Summary: Sendable, Equatable {
        let text: String
        let claim: Claim
        /// The signal an improvement claim rests on, when there is one.
        let signal: SignalID?
    }

    /// - Parameters:
    ///   - recentSessions: history in any order. Filtered here to **valid
    ///     same-mode** sessions, so a caller cannot accidentally compare across
    ///     modes [PRD OQ-5].
    /// - Returns: nil before a baseline exists. The pre-baseline Score screen
    ///   shows "Session X of 5" and no score (docs/04 §4.9); a summary with
    ///   nothing to compare against would be a static string, which is what
    ///   [PRD] rules out.
    static func summary(
        mode: TestMode,
        metrics: GaitMetrics,
        standardization: SessionStandardization?,
        score: SessionScore?,
        recentSessions: [GaitSession],
        configuration: AlgorithmConfiguration
    ) -> Summary? {
        guard let standardization, let score else { return nil }

        let recent = recentSameModeMetrics(
            from: recentSessions, mode: mode, configuration: configuration
        )
        let improvement = strongestImprovement(
            standardization: standardization,
            recent: recent,
            configuration: configuration
        )

        let margin = configuration.summary.aroundBaselineIndexMargin
        let centre = Int(configuration.composite.indexCenter)
        let isAbove = score.relativeIndex > centre + margin
        let isBelow = score.relativeIndex < centre - margin

        // Strongest true claim wins, and every branch below is reachable only
        // when its evidence exists.
        if isAbove, let improvement {
            return Summary(
                text: "That was a steadier walk than usual for you, and your \(phrase(improvement)) held together better than your recent \(mode.displayName) sessions.",
                claim: .aboveBaselineWithImprovement,
                signal: improvement
            )
        }
        if let improvement {
            return Summary(
                text: "Your \(phrase(improvement)) was steadier than your recent \(mode.displayName) sessions.",
                claim: .improvementOnly,
                signal: improvement
            )
        }
        if isAbove {
            return Summary(
                text: "This \(mode.displayName) came in above your usual range.",
                claim: .aboveBaseline,
                signal: nil
            )
        }
        if isBelow {
            return Summary(
                text: "This \(mode.displayName) sat below your usual range. Walking varies day to day, so one session on its own says little.",
                claim: .belowBaseline,
                signal: nil
            )
        }
        if !recent.isEmpty {
            return Summary(
                text: "This \(mode.displayName) was about usual for you, in line with your recent sessions.",
                claim: .aroundUsual,
                signal: nil
            )
        }
        // Nothing to compare against yet beyond the baseline itself.
        return Summary(
            text: "This \(mode.displayName) was about usual for you.",
            claim: .neutral,
            signal: nil
        )
    }

    // MARK: - Comparisons

    /// Valid same-mode metrics, newest first, capped at the configured N.
    ///
    /// Other modes are dropped here rather than trusted to the caller: a
    /// comparison that reached across modes would be exactly the mixing
    /// [PRD OQ-5] forbids.
    static func recentSameModeMetrics(
        from sessions: [GaitSession],
        mode: TestMode,
        configuration: AlgorithmConfiguration
    ) -> [GaitMetrics] {
        sessions
            .filter { $0.mode == mode && $0.isValid }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(configuration.summary.recentSessionCount)
            .compactMap(\.metrics)
    }

    /// The signal that improved most against recent sessions, if any did
    /// measurably.
    ///
    /// Only signals with a **decided direction** can qualify: cadence and
    /// asymmetry have none (entry 3), so neither can ever produce an
    /// improvement claim.
    static func strongestImprovement(
        standardization: SessionStandardization,
        recent: [GaitMetrics],
        configuration: AlgorithmConfiguration
    ) -> SignalID? {
        guard !recent.isEmpty else { return nil }

        var best: (signal: SignalID, change: Double)?

        for signal in SignalID.allCases {
            var changes: [Double] = []

            for metric in signal.metrics {
                guard let current = standardization.standardization(for: metric),
                      let direction = current.direction,
                      current.baselineSD > 0 else { continue }

                let previous = recent.compactMap { $0.value(for: metric) }
                guard previous.count == recent.count else { continue }

                let previousMean = previous.reduce(0, +) / Double(previous.count)
                // In baseline SDs, so the threshold means the same thing for
                // metrics of very different magnitudes.
                let raw = (current.rawValue - previousMean) / current.baselineSD
                changes.append(BaselineNormalization.adjust(raw, for: direction))
            }

            // Every metric behind the signal must agree it improved; one axis
            // of the trunk proxy improving while the other worsens is not the
            // signal improving.
            guard !changes.isEmpty,
                  changes.allSatisfy({ $0 >= configuration.summary.minimumNoticeableChange })
            else { continue }

            let change = changes.reduce(0, +) / Double(changes.count)
            if best == nil || change > best!.change {
                best = (signal, change)
            }
        }

        return best?.signal
    }

    /// Provisional wording for a signal inside a sentence. **EPIC 8 owns final
    /// copy.** Never "symmetry" for the autocorrelation output [PRD OQ-1].
    private static func phrase(_ signal: SignalID) -> String {
        switch signal {
        case .gaitConsistency: "gait consistency"
        case .stepTimeVariability: "step timing"
        case .trunkMotion: "trunk movement"
        case .cadence: "cadence"
        case .stepTimeAsymmetry: "step-time asymmetry"
        }
    }
}
