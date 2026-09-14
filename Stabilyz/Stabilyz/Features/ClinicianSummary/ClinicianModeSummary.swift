import Foundation

/// One mode's section of the Clinician Summary (docs/04 §4.14, [PRD §5, §7],
/// Task 9.2.1).
///
/// A pure value, so what the screen may show is testable without rendering
/// (docs/11 §11.5). Objective by decision (2026-09-14):
///
/// - **Dates, relative indices and measured values only.** No provisional
///   scores — calibration shows its progress instead — and no user-facing
///   summary lines. There is no property here that could carry either.
/// - **No better/worse.** Metric sign conventions are `[OPEN]`
///   (`MetricDirections`), so a baseline parameter is a mean and a spread,
///   never a verdict. A session's delta is a signed number, not an arrow.
/// - **One mode.** Built for a `TestMode`, from that mode's state and sessions,
///   and filtered to it again regardless [PRD OQ-5].
struct ClinicianModeSummary: Equatable {

    enum Status: Equatable {
        case notStarted
        case calibrating(completed: Int, required: Int)
        case baselineRefused
        case established
    }

    /// One baseline parameter: μ ± σ for a metric with a physical unit.
    struct Parameter: Equatable, Identifiable {
        let metric: MetricID
        /// Nil when the baseline carries no stat for the metric — asymmetry
        /// measured in too few calibration walks, or not at all for a
        /// bilateral user [PRD §7, OQ-1].
        let stat: BaselineMetricStat?

        var id: MetricID { metric }
        var label: String { ClinicianModeSummary.label(for: metric) }

        func displayValue(locale: Locale = .current) -> String {
            stat.map { ClinicianModeSummary.meanAndSD($0, locale: locale) } ?? ClinicianModeSummary.notEstablishedValue
        }

        var sampleSize: String? { stat.map { "n = \($0.n)" } }
    }

    struct BaselineParameters: Equatable {
        let establishedAt: Date
        let sourceWalkCount: Int
        let parameters: [Parameter]

        var anyFloorApplied: Bool { parameters.contains { $0.stat?.sdFloorApplied == true } }
    }

    /// One measured value on a recent session.
    struct Measurement: Equatable, Identifiable {
        let metric: MetricID
        /// Nil when the walk did not measure it — a real result for asymmetry,
        /// never shown as zero.
        let value: Double?

        var id: MetricID { metric }
        var label: String { ClinicianModeSummary.label(for: metric) }

        func displayValue(locale: Locale = .current) -> String {
            value.map { ClinicianModeSummary.value($0, for: metric, locale: locale) }
                ?? ClinicianModeSummary.notDetectedValue
        }
    }

    struct RecentSession: Equatable, Identifiable {
        let id: UUID
        let startedAt: Date
        let index: Int
        /// Signed against the baseline's reference index [PRD §7].
        let delta: Int
        let measurements: [Measurement]

        /// "20 Jan 2027 · 08:00".
        func title(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
            var day = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
            day.locale = locale
            day.timeZone = timeZone
            var time = Date.FormatStyle(date: .omitted, time: .shortened)
            time.locale = locale
            time.timeZone = timeZone
            return "\(startedAt.formatted(day)) · \(startedAt.formatted(time))"
        }

        /// "+8", "-6", "0": the number, not a direction glyph.
        var deltaText: String { delta > 0 ? "+\(delta)" : "\(delta)" }

        func accessibilityLabel(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
            let values = measurements
                .map { "\($0.label) \($0.displayValue(locale: locale))." }
                .joined(separator: " ")
            return "\(title(locale: locale, timeZone: timeZone)). "
                + "\(StabilityTrend.scoreSentence(index: index, delta: delta)) \(values)"
        }
    }

    let mode: TestMode
    let status: Status
    /// Present once established.
    let baseline: BaselineParameters?
    /// The newest scored walks, newest first, at most `recentCount`.
    let recent: [RecentSession]
    let recentCount: Int
    /// Every scored walk of the mode, as the Result tab plots it. Present once
    /// established.
    let trend: StabilityTrend?

    /// The metrics with a physical unit, in display order. The regularity
    /// outputs and the trunk proxy are dimensionless indices whose only
    /// reading is a comparison, so they are not listed as values.
    static let displayedMetrics: [MetricID] = [.cadenceMean, .stepTimeCV, .stepTimeAsymmetry]

    /// - Parameters:
    ///   - state: this mode's `BaselineState`, from the shared derivation.
    ///   - sessions: this mode's stored sessions. Filtered to `mode` and to
    ///     valid sessions again here.
    init(
        mode: TestMode,
        state: BaselineState,
        sessions: [GaitSession],
        baselineIndex: Int,
        recentCount: Int = ClinicianSummaryPolicy.recentScoredSessionCount
    ) {
        self.mode = mode
        self.recentCount = recentCount

        // Invalid sessions are never shown [PRD §5, §6].
        let visible = sessions.filter { $0.mode == mode && $0.isUserVisible }

        switch state {
        case .notStarted:
            status = .notStarted
        case .building(let count):
            status = .calibrating(completed: count, required: Baseline.requiredValidSessionCount)
        case .baselineRefused:
            status = .baselineRefused
        case .established:
            status = .established
        }

        baseline = state.baseline.flatMap { baseline in
            guard baseline.mode == mode else { return nil }
            return BaselineParameters(
                establishedAt: baseline.establishedAt,
                sourceWalkCount: baseline.sourceSessionIDs.count,
                parameters: Self.displayedMetrics.map { Parameter(metric: $0, stat: baseline.stat(for: $0)) }
            )
        }

        // Scored walks only: a calibration walk has no relative index, and its
        // provisional score is a different scale (`ProvisionalStabilityScore`).
        let scoredNewestFirst = visible
            .compactMap { session -> (session: GaitSession, score: SessionScore)? in
                session.score.map { (session, $0) }
            }
            .sorted { lhs, rhs in
                lhs.session.startedAt != rhs.session.startedAt
                    ? lhs.session.startedAt > rhs.session.startedAt
                    : lhs.session.id.uuidString < rhs.session.id.uuidString
            }

        recent = scoredNewestFirst.prefix(max(recentCount, 0)).map { pair in
            RecentSession(
                id: pair.session.id,
                startedAt: pair.session.startedAt,
                index: pair.score.relativeIndex,
                delta: pair.score.relativeIndex - baselineIndex,
                measurements: Self.displayedMetrics.map {
                    Measurement(metric: $0, value: pair.session.metrics?.value(for: $0))
                }
            )
        }

        trend = status == .established
            ? StabilityTrend(
                mode: mode,
                rows: SessionHistoryRow.rows(from: visible, baselineIndex: baselineIndex),
                baselineIndex: baselineIndex
            )
            : nil
    }

    // MARK: - Copy

    var baselineTitle: String { "\(mode.displayName) Baseline" }

    /// The mode's state in one objective line.
    func statusText(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        switch status {
        case .notStarted:
            return "No \(mode.displayName)s recorded."
        case .calibrating(let completed, let required):
            return "Calibrating: \(completed) of \(required) walks completed"
        case .baselineRefused:
            return Self.refusedText
        case .established:
            guard let baseline else { return "" }
            var style = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
            style.locale = locale
            style.timeZone = timeZone
            return "Established \(baseline.establishedAt.formatted(style)) · from \(baseline.sourceWalkCount) calibration walks"
        }
    }

    /// Cause-neutral (decided 2026-09-14): nothing stored can confirm why a
    /// baseline was not established, and no refusal path in the app is about
    /// variance (docs/decisions.md entry 17).
    static let refusedText =
        "Baseline could not be established from the first \(Baseline.requiredValidSessionCount) calibration walks."

    static let parametersTitle = "Baseline Parameters"
    static let parametersCaption = "Mean ± SD across the calibration walks."
    static let floorMarker = "*"
    static let floorFootnote = "* SD raised to the configured minimum spread."
    static let notEstablishedValue = "Not established"
    static let notDetectedValue = SessionScorePresentation.undetectedMeasurement

    var recentTitle: String { "Last \(recentCount) Sessions" }
    static let recentCaption = "Scored walks only, newest first."
    static let noScoredWalks = "No scored walks yet."

    /// Clinical names. Only `displayedMetrics` are ever labelled; the rest
    /// return nothing rather than a name no screen should print.
    static func label(for metric: MetricID) -> String {
        switch metric {
        case .cadenceMean: "Cadence"
        case .stepTimeCV: "Step-time variability"
        case .stepTimeAsymmetry: "Step-time asymmetry"
        case .stepRegularity, .strideRegularity, .trunkMotionML, .trunkMotionVT: ""
        }
    }

    // MARK: - Units

    /// A stored value in its display unit: cadence in steps per minute, and
    /// the two ratios as percentages. Scaling for display only — no statistic
    /// is computed here.
    private static func display(_ value: Double, for metric: MetricID) -> (scaled: Double, unit: String) {
        switch metric {
        case .cadenceMean: (value, " spm")
        case .stepTimeCV, .stepTimeAsymmetry: (value * 100, "%")
        case .stepRegularity, .strideRegularity, .trunkMotionML, .trunkMotionVT: (value, "")
        }
    }

    private static func number(_ value: Double, locale: Locale) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(locale))
    }

    /// "104.3 spm", "4.1%".
    static func value(_ value: Double, for metric: MetricID, locale: Locale = .current) -> String {
        let shown = display(value, for: metric)
        return "\(number(shown.scaled, locale: locale))\(shown.unit)"
    }

    /// "104.3 ± 2.0 spm", with the floor marker when the stored SD was raised
    /// to its minimum (docs/decisions.md entry 16) — the stored value is the
    /// floored one, and the clinician is told so rather than left to assume it
    /// was observed.
    static func meanAndSD(_ stat: BaselineMetricStat, locale: Locale = .current) -> String {
        let mean = display(stat.mean, for: stat.metricID)
        let sd = display(stat.sd, for: stat.metricID)
        let marker = stat.sdFloorApplied ? floorMarker : ""
        return "\(number(mean.scaled, locale: locale)) ± \(number(sd.scaled, locale: locale))\(mean.unit)\(marker)"
    }
}
