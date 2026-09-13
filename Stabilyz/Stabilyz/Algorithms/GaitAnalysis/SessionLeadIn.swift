import Foundation

/// Drops the unusable head of a recording, before any stage looks at it
/// (docs/08 stage 1 → 2).
///
/// The walk begins at T-0. The user does not: the first seconds carry the phone
/// being lowered into a pocket, a hand leaving it, a first step taken from
/// standing. None of that is gait, and all of it is high-amplitude enough to
/// move the trunk proxy and drag the regularity estimates down.
///
/// **Its own stage rather than part of `Preprocessing`.** This is a decision
/// about which part of the session counts as the walk — session framing, the
/// same family as the walking-bout detector. Preprocessing is signal
/// conditioning: resampling, projection, filtering. Folding one into the other
/// would mean every test of a filter had to know about pocketing.
///
/// Running it *before* preprocessing is the point: the orientation estimate
/// reads these samples too, and a phone still being pocketed is exactly the
/// stretch that would bias the gravity direction every later stage projects
/// onto.
enum SessionLeadIn {

    /// Drops the first `leadInTrim` of signal, and **nothing from the end**.
    ///
    /// The tail is kept intact to the moment Stop was triggered. Stop is a
    /// deliberate act with the user walking right up to it, so there is no
    /// artefact there to mirror the one at the start — trimming symmetrically
    /// would discard real gait to guard against nothing.
    ///
    /// Measured from the first sample rather than from the session's start
    /// date, so it is the same three seconds of *signal* whatever the recorder
    /// was doing before the first sample landed.
    ///
    /// Gaps are carried across unchanged. One that fell entirely inside the
    /// trimmed head simply no longer matches a sample boundary, which is the
    /// right outcome: it bounded a run that no longer exists. The session
    /// record's own `gapInfo` is built from the untrimmed buffer and is
    /// unaffected — what is dropped here is signal the analysis ignores, not
    /// history the record forgets.
    ///
    /// A recording shorter than the trim comes back empty, and the quality
    /// stage then reports it as the too-short session it already was rather
    /// than this stage inventing a reason.
    static func trimmed(
        _ series: AlignedSampleSeries,
        configuration: AlgorithmConfiguration
    ) -> AlignedSampleSeries {
        let policy = configuration.preprocessing.leadInTrim
        let trim = Double(policy.components.seconds)
            + Double(policy.components.attoseconds) / 1e18
        guard trim > 0, let first = series.samples.first else { return series }

        let cutoff = first.deviceTimestamp + trim
        return AlignedSampleSeries(
            samples: Array(series.samples.drop { $0.deviceTimestamp < cutoff }),
            gaps: series.gaps
        )
    }
}
