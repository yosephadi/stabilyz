import Foundation

/// Drops the unusable head of a recording — and, after a manual Stop, its tail —
/// before any stage looks at it (docs/08 stage 1 → 2).
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

    /// Drops the first `leadInTrim` of signal and, **only when the session
    /// ended by the user's manual Stop**, the last `manualStopTailTrim` too.
    ///
    /// Head: always. The walk begins at T-0; the user does not.
    ///
    /// Tail: a timer-ended recording is cut mid-walk by the clock, so there is
    /// no stopping behaviour in it and it is kept intact. A manual Stop is the
    /// user slowing and stopping, and Tura et al. (2012) report the last strides
    /// before stopping degrade the regularity estimates — so those are dropped.
    /// The valid-walking floor is evaluated downstream, after this trim, so a
    /// manual Stop pays for the trimmed seconds in valid walking [PRD OQ-3].
    ///
    /// Measured from the first and last samples rather than from the session's
    /// start/end dates, so it is the same number of seconds of *signal* whatever
    /// the recorder was doing before the first sample or after the last.
    ///
    /// Gaps are carried across unchanged. One that fell entirely inside a
    /// trimmed end simply no longer matches a sample boundary, which is the
    /// right outcome: it bounded a run that no longer exists. The session
    /// record's own `gapInfo` is built from the untrimmed buffer and is
    /// unaffected — what is dropped here is signal the analysis ignores, not
    /// history the record forgets.
    ///
    /// A recording shorter than the trim(s) comes back empty, and the quality
    /// stage then reports it as the too-short session it already was rather
    /// than this stage inventing a reason.
    static func trimmed(
        _ series: AlignedSampleSeries,
        endReason: SessionEndReason,
        configuration: AlgorithmConfiguration
    ) -> AlignedSampleSeries {
        guard let first = series.samples.first, let last = series.samples.last else { return series }

        let head = seconds(configuration.preprocessing.leadInTrim)
        let tail = endReason == .manualStop ? seconds(configuration.preprocessing.manualStopTailTrim) : 0
        guard head > 0 || tail > 0 else { return series }

        let startCutoff = first.deviceTimestamp + head
        // A hair of tolerance so a whole-second trim on a 100 Hz grid drops
        // exactly that many samples, not one more or fewer from rounding.
        let endCutoff = last.deviceTimestamp - tail + 1e-9
        return AlignedSampleSeries(
            samples: series.samples.filter {
                (head <= 0 || $0.deviceTimestamp >= startCutoff)
                    && (tail <= 0 || $0.deviceTimestamp <= endCutoff)
            },
            gaps: series.gaps
        )
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
