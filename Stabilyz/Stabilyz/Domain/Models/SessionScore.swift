import Foundation

/// Everything about a score that the **pure pipeline** can compute.
///
/// Deliberately **not `Codable`**: this type cannot reach the store. The
/// summary line requires recent same-mode history, which a pure, history-free
/// pipeline does not have (docs/decisions.md entry 20), so a score is
/// incomplete until the commit step supplies it.
///
/// Making that structural rather than a convention means a partial score cannot
/// be persisted by accident — there is no encoder for it, and
/// `GaitSession.score` will not accept it.
struct PartialSessionScore: Sendable, Equatable {
    let relativeIndex: Int
    let compositeZ: Double
    /// The **baseline's** version — a comparison is only meaningful within the
    /// version the baseline was built under (docs/09 §9.6).
    let algorithmVersion: String
    /// Per-signal breakdown. Pure: it needs only the standardization and the
    /// session's own metrics, both of which the pipeline has.
    let breakdown: [MetricBreakdown]
    /// Retained so the commit step can generate the summary. Not persisted.
    let standardization: SessionStandardization
}

/// A session's complete, persisted result relative to the user's own baseline
/// for that mode (docs/05 §5.1).
///
/// Present only from the **sixth** valid session of a mode onward: the fifth
/// establishes the baseline and is itself shown as "building" [PRD §7,
/// docs/09 §9.5].
///
/// The only way to make one is to complete a `PartialSessionScore` with a
/// summary line, so a stored score always carries everything the Score screen
/// and the clinician summary need.
struct SessionScore: Sendable, Equatable, Codable {
    /// Baseline performance is 100 by construction; the PRD's worked example is
    /// 112 [PRD §7]. An **index**, not a percentage of anything.
    ///
    /// Persisted as a scalar column, because History and the trend chart query
    /// it (docs/05 §5.2).
    let relativeIndex: Int
    /// The weighted composite the index was mapped from.
    let compositeZ: Double
    let algorithmVersion: String
    /// Per-signal breakdown for the Score screen's tap-to-expand.
    let breakdown: [MetricBreakdown]
    /// Generated at commit from real same-mode comparisons [PRD].
    ///
    /// **Frozen once written.** It records what was true when the session was
    /// committed; regenerating it later against different history would rewrite
    /// the past, the same reasoning that freezes the baseline [PRD §6].
    let summaryLine: String

    init(completing partial: PartialSessionScore, summaryLine: String) {
        self.relativeIndex = partial.relativeIndex
        self.compositeZ = partial.compositeZ
        self.algorithmVersion = partial.algorithmVersion
        self.breakdown = partial.breakdown
        self.summaryLine = summaryLine
    }
}
