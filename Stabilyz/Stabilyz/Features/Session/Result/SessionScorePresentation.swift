import Foundation

/// Everything the Score screen draws, derived from one committed session
/// (Figma node 150:3209, docs/04 §4.9, [PRD §5, §7]).
///
/// A pure value so the screen's rules — when a number may appear, what a signal
/// may claim, what the cue line says — are testable without rendering
/// (docs/11 §11.5). It is also where the screen's honesty is enforced:
///
/// - **A score appears only when one was stored.** `SessionScore` exists from
///   the sixth valid session of a mode onward; before that the screen shows
///   "Session X of 5" and no index [PRD §7, docs/09 §9.5]. There is no
///   fallback that computes one here.
/// - **No signal is rendered as better or worse without a direction.** Cadence
///   and step-time asymmetry carry none by configuration, so they are shown as
///   measurements and never as progress (docs/decisions.md entry 3).
/// - **Nothing is invented.** The per-signal "x / 100" sub-scores the node
///   draws have no source: docs/08 §8.2 leaves the composite formula and index
///   scaling `[OPEN]`, and there is no per-signal index at any layer. The rows
///   therefore carry the comparison that was actually made.
struct SessionScorePresentation: Equatable {

    // MARK: - The headline

    /// The one number, or the reason there is not one yet.
    enum Progress: Equatable {
        /// A relative index against the user's own baseline for this mode.
        /// `delta` is signed against the baseline's 100 [PRD §7].
        case scored(index: Int, delta: Int)
        /// Calibration. No index, by design — five valid sessions build the
        /// baseline and the fifth carries no score itself.
        case building(validCount: Int, required: Int)
        /// The baseline exists and the walk was measured, but no score was
        /// stored: the commit could not complete one (docs/09 §9.5). Rare, and
        /// said plainly rather than shown as a sixth calibration session.
        case notComparable
    }

    /// Which way a signal moved, when it is allowed to have moved at all.
    enum Direction: Equatable {
        case better
        case worse

        /// ↑/↓ rather than colour: §2.4 forbids encoding direction by hue, and
        /// §9 forbids encoding anything by colour alone.
        var glyph: String {
            switch self {
            case .better: "arrow.up"
            case .worse: "arrow.down"
            }
        }
    }

    /// One row of Calculation Details.
    struct SignalRow: Equatable, Identifiable {
        let signal: SignalID
        let label: String
        /// What this session's comparison supports, in plain language.
        let detail: String
        /// Nil whenever the signal may not be shown as better or worse.
        let direction: Direction?

        var id: SignalID { signal }
    }

    /// The cue the walk actually ran with, and where it stopped.
    struct CueNote: Equatable {
        let glyph: String
        let text: String
    }

    let mode: TestMode
    let completedAt: Date
    let progress: Progress
    /// The generated summary line, present only with a score — it is generated
    /// at commit from real same-mode comparisons and frozen there.
    let highlight: String?
    /// What just happened to the baseline, when that is worth saying.
    let note: String?
    let signals: [SignalRow]
    /// What this walk measured, shown when there is no score to show instead.
    ///
    /// §4.9's "raw metrics, reference only" for the pre-baseline screen. It is
    /// the evidence the walk was recorded and analysed — without it, a
    /// calibration session reads as a screen where nothing happened.
    let measurements: [SignalRow]
    /// The calibration line under the ring, when the screen is counting toward
    /// a baseline. Nil once there is a score, and nil when `note` is carrying
    /// the same news in more words.
    let subtitle: String?
    /// Nil when the walk ran with no cue; a row saying "no cue" would be noise.
    let cue: CueNote?

    // MARK: - Building it

    /// - Parameter baselineIndex: what a baseline scores by construction
    ///   [PRD §7]. Passed in rather than typed as 100 so the screen follows the
    ///   configuration the score was computed under.
    init(result: SessionCommitResult, baselineIndex: Int) {
        let session = result.session
        self.mode = session.mode
        self.completedAt = session.endedAt
        self.cue = Self.cueNote(for: session)

        let note = Self.note(for: result.baselineOutcome, mode: session.mode)
        self.note = note

        switch (session.score, result.state.isEstablished) {
        case (.some(let score), _):
            self.progress = .scored(
                index: score.relativeIndex,
                delta: score.relativeIndex - baselineIndex
            )
            self.highlight = score.summaryLine
            self.signals = Self.rows(from: score.breakdown)
            // The breakdown already carries every measurement, in context.
            self.measurements = []
            self.subtitle = nil

        case (nil, true):
            // Measured, comparable in principle, and yet no score was stored.
            // Shown as itself rather than as a sixth calibration session.
            self.progress = .notComparable
            self.highlight = nil
            self.signals = []
            self.measurements = Self.measurements(from: session.metrics)
            self.subtitle = nil

        case (nil, false):
            let count = min(result.validSessionCount, Baseline.requiredValidSessionCount)
            self.progress = .building(
                validCount: count,
                required: Baseline.requiredValidSessionCount
            )
            // Before a baseline exists there is nothing to compare against, and
            // a sentence written without a comparison would be the static
            // string [PRD] rules out. What the walk *measured* still stands on
            // its own, and is shown below.
            self.highlight = nil
            self.signals = []
            self.measurements = Self.measurements(from: session.metrics)
            // Suppressed when `note` is already saying it: the session that
            // establishes the baseline would otherwise announce it twice.
            self.subtitle = note == nil
                ? Self.calibrationSubtitle(
                    validCount: count,
                    required: Baseline.requiredValidSessionCount
                )
                : nil
        }
    }

    // MARK: - Calibration copy

    /// The line under the ring while a baseline is being built [PRD §5].
    ///
    /// Says the number of walks left rather than a proportion: "4 more walks"
    /// is something a user can act on this week, and "80%" is not. The word
    /// "unlock" is doing the other half — it names what the walks are *for*, so
    /// five sessions without a score read as progress rather than as five
    /// screens that failed to produce one.
    static func calibrationSubtitle(validCount: Int, required: Int) -> String {
        let remaining = max(0, required - validCount)
        guard remaining > 0 else {
            // Reachable only if a fifth walk lands without establishing the
            // baseline; `note` covers the ordinary case.
            return "Baseline complete. Your next walk gets a Stability Score."
        }
        let walks = remaining == 1 ? "1 more walk" : "\(remaining) more walks"
        return "Baseline in progress. \(walks) needed to unlock your Stability Score."
    }

    // MARK: - Raw measurements

    /// The objective numbers this walk produced, for a screen with no score.
    ///
    /// Cadence, step-time variability and step-time asymmetry: the three that
    /// mean something read on their own, without a baseline to stand them
    /// against. The regularity outputs and the trunk proxy are deliberately
    /// absent — both are dimensionless indices whose only interpretation *is*
    /// the comparison, so printing them here would be a number with nothing
    /// attached to it.
    ///
    /// Asymmetry is omitted entirely when it is nil rather than shown as
    /// unavailable. Nil is the correct value for a bilateral user, for a walk
    /// with no profile, and for one whose peaks were not prominent [PRD §7,
    /// OQ-1] — and a permanently empty row on a secondary metric is noise, not
    /// transparency.
    static func measurements(from metrics: GaitMetrics?) -> [SignalRow] {
        guard let metrics else { return [] }

        var rows: [SignalRow] = [
            measurement(.cadence, .cadenceMean, metrics.cadenceMean),
            measurement(.stepTimeVariability, .stepTimeCV, metrics.stepTimeCV)
        ]
        if let asymmetry = metrics.stepTimeAsymmetry {
            rows.append(measurement(.stepTimeAsymmetry, .stepTimeAsymmetry, asymmetry))
        }
        return rows
    }

    private static func measurement(
        _ signal: SignalID,
        _ metric: MetricID,
        _ value: Double
    ) -> SignalRow {
        SignalRow(
            signal: signal,
            label: label(for: signal),
            detail: format(value, for: metric),
            // Never a direction: there is no baseline to be above or below, and
            // these carry no sign convention of their own even when there is
            // (docs/decisions.md entry 3).
            direction: nil
        )
    }

    static let measurementsTitle = "Measured This Walk"
    static let measurementsCaption = """
        Reference only. These aren't compared against anything until your \
        baseline exists.
        """

    // MARK: - Calibration

    /// What the commit did to this mode's baseline, when the user should hear
    /// about it.
    private static func note(
        for outcome: BaselineCommitOutcome,
        mode: TestMode
    ) -> String? {
        switch outcome {
        case .established:
            return """
            Your \(mode.displayName) baseline is ready. From your next walk on, \
            each session is compared against it.
            """
        case .refused:
            // The walk is kept and the count stands; calibration is not
            // restarted and no substitute baseline is invented
            // (docs/decisions.md entry 17). Saying so is better than a screen
            // that silently stays on "Session 5 of 5" forever.
            return """
            Your \(mode.displayName) walks so far are too alike to compare \
            against. Another walk will give them something to vary from.
            """
        case .notReady, .alreadyEstablished:
            return nil
        }
    }

    // MARK: - Signals

    static func rows(from breakdown: [MetricBreakdown]) -> [SignalRow] {
        breakdown.compactMap(row(for:))
    }

    private static func row(for breakdown: MetricBreakdown) -> SignalRow? {
        guard !breakdown.isEmpty else { return nil }

        let directed = breakdown.components.compactMap(\.directionAdjustedZ)
        if directed.isEmpty {
            // Cadence, asymmetry, and anything the baseline could not compare:
            // shown as what was measured, never as progress.
            return SignalRow(
                signal: breakdown.signal,
                label: label(for: breakdown.signal),
                detail: measurement(of: breakdown),
                direction: nil
            )
        }

        // One signal can rest on two metrics, and the two can disagree. A
        // combined direction would need a weighting, which is exactly the
        // `[OPEN]` composite formula — so agreement is the rule instead, and a
        // disagreement is reported as neither.
        let direction: Direction? = if directed.allSatisfy({ $0 > 0 }) {
            .better
        } else if directed.allSatisfy({ $0 < 0 }) {
            .worse
        } else {
            nil
        }

        return SignalRow(
            signal: breakdown.signal,
            label: label(for: breakdown.signal),
            detail: detail(for: direction),
            direction: direction
        )
    }

    private static func detail(for direction: Direction?) -> String {
        switch direction {
        case .better: "Above your usual"
        case .worse: "Below your usual"
        // Both a measurement sitting on the baseline and two metrics pulling
        // opposite ways are honestly described as "no clear move either way".
        case nil: "In your usual range"
        }
    }

    /// The raw measurement, for a signal that may not claim a direction.
    private static func measurement(of breakdown: MetricBreakdown) -> String {
        let measured = breakdown.components.compactMap { component -> String? in
            guard let value = component.rawValue else { return nil }
            return format(value, for: component.metricID)
        }
        // Every component unmeasured is a fact about the walk, not a blank row.
        return measured.isEmpty ? "Not measured" : measured.joined(separator: " · ")
    }

    /// Units where the metric has one, and a bare number where it does not.
    ///
    /// The autocorrelation outputs and the trunk proxy are dimensionless, and a
    /// unit invented for them would read as a measurement in something.
    private static func format(_ value: Double, for metric: MetricID) -> String {
        switch metric {
        case .cadenceMean:
            return "\(Int(value.rounded())) steps/min"
        case .stepTimeAsymmetry:
            // A ratio of the two half-cycles (docs/decisions.md entry 13),
            // non-negative by construction, so a percentage reads directly.
            return "\(Int((value * 100).rounded()))%"
        case .stepTimeCV:
            // A coefficient of variation is a ratio too, and "4%" is read by
            // more people than "0.04".
            return "\(Int((value * 100).rounded()))%"
        case .stepRegularity, .strideRegularity, .trunkMotionML, .trunkMotionVT:
            return value.formatted(.number.precision(.fractionLength(2)))
        }
    }

    /// The final user-facing signal copy, which docs/05 and `SignalID` both
    /// leave to EPIC 8.
    ///
    /// Figma node 150:3209 names four rows — "Gait consistency", "Step rhythm",
    /// "Trunk movement", "Left-right balance" — against five signals. The first
    /// three are taken as drawn. The fourth is **not**: the asymmetry metric
    /// says how unequal two consecutive half-cycles were, never which limb is
    /// which (docs/decisions.md entry 13), so "left-right" would name a
    /// comparison the app cannot make. Cadence, which the node omits, keeps the
    /// word the metronome already uses on the setup screen.
    static func label(for signal: SignalID) -> String {
        switch signal {
        case .gaitConsistency: "Gait consistency"
        case .stepTimeVariability: "Step rhythm"
        case .trunkMotion: "Trunk movement"
        case .cadence: "Cadence"
        case .stepTimeAsymmetry: "Step-time asymmetry"
        }
    }

    // MARK: - The cue

    /// What the walk ran with, and where the sound stopped.
    ///
    /// The session keeps the config it *started* with; `audioSilencedAt` says
    /// the rest of it was silent. A walk is never part unpaced and part paced,
    /// so one line covers both.
    private static func cueNote(for session: GaitSession) -> CueNote? {
        let glyph: String
        let name: String
        switch session.audioConfig {
        case .none:
            return nil
        case .stepFeedback:
            glyph = "waveform"
            name = "Step Feedback"
        case .metronome:
            glyph = "metronome.fill"
            name = "Metronome Cue"
        }

        guard let silenced = session.audioSilencedAt else {
            return CueNote(glyph: glyph, text: "\(name) was on")
        }
        return CueNote(glyph: glyph, text: "\(name) was on until \(clock(silenced))")
    }

    /// mm:ss from T-0, the same clock the walk itself ran on.
    static func clock(_ duration: Duration) -> String {
        let total = max(0, Int(duration.components.seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - The header

    static let doneLabel = "Done"

    /// "Completed today at 3:48 PM", the way the node words it.
    ///
    /// - Parameters:
    ///   - now: the reference day, injected so the wording is testable rather
    ///     than depending on when the suite runs.
    static func completedText(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) {
            return "Completed today at \(time)"
        }
        // Relative to `now`, not to the day this runs: the reference day is
        // injected precisely so the wording does not depend on the clock.
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Completed yesterday at \(time)"
        }
        return "Completed \(date.formatted(.dateTime.month(.abbreviated).day())) at \(time)"
    }
}
