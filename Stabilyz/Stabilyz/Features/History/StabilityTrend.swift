import Foundation

/// The trend card for **one** mode (Figma node 64:7837, docs/04 §4.13,
/// Task 9.1.2).
///
/// A pure value, so the chart's rules are testable without rendering
/// (docs/11 §11.5):
///
/// - **One mode, always.** It is built for a `TestMode` and holds nothing else;
///   there is no shape of this type that carries two series. Quick Test and
///   Full Test never share a line or an axis [PRD OQ-5, EPIC 6 audit #12].
/// - **Relative index only.** A point is a walk with a stored `SessionScore`.
///   Calibration walks carry a provisional score on a different 0-100 scale,
///   and plotting it here would put two units on one axis
///   (`ProvisionalStabilityScore`), so walks 1-5 are never points.
/// - **No retroactive scores.** Nothing is computed for a walk that was not
///   scored at commit (docs/21 #8 is `[OPEN]`).
struct StabilityTrend: Equatable {

    struct Point: Equatable, Identifiable {
        let id: UUID
        /// 1-based, oldest first: the x axis. Walks are spaced evenly rather
        /// than by date, as the node draws them — two walks on one day would
        /// otherwise stack into a vertical stroke.
        let position: Int
        let date: Date
        let index: Int
        /// Signed against the baseline's reference index [PRD §7].
        let delta: Int
    }

    enum State: Equatable {
        /// At least one scored walk to plot.
        case trend
        /// The mode is still building its baseline. `completed` counts its
        /// valid walks.
        case calibrating(completed: Int, required: Int)
        /// Five or more valid walks, and none scored yet — the sixth has not
        /// happened, or the baseline was refused (docs/decisions.md entry 17).
        case awaitingFirstScore
    }

    let mode: TestMode
    let baselineIndex: Int
    /// Oldest first.
    let points: [Point]
    let state: State
    /// The latest scored walk's summary line, frozen at its commit [PRD §7].
    let latestSummary: String?

    /// - Parameters:
    ///   - rows: History's rows, already valid-only. Filtered to `mode` here
    ///     regardless, so a caller cannot hand in a mixed list and get a mixed
    ///     chart.
    init(mode: TestMode, rows: [SessionHistoryRow], baselineIndex: Int) {
        self.mode = mode
        self.baselineIndex = baselineIndex

        let ofMode = rows.filter { $0.mode == mode }
        let scoredOldestFirst = ofMode
            .sorted { lhs, rhs in
                lhs.startedAt != rhs.startedAt
                    ? lhs.startedAt < rhs.startedAt
                    : lhs.id.uuidString < rhs.id.uuidString
            }
            .compactMap { row -> (row: SessionHistoryRow, index: Int, delta: Int)? in
                guard case .scored(let index, let delta) = row.standing else { return nil }
                return (row, index, delta)
            }

        self.points = scoredOldestFirst.enumerated().map { offset, scored in
            Point(
                id: scored.row.id,
                position: offset + 1,
                date: scored.row.startedAt,
                index: scored.index,
                delta: scored.delta
            )
        }
        self.latestSummary = scoredOldestFirst.last?.row.detail.highlight

        let required = Baseline.requiredValidSessionCount
        if points.isEmpty == false {
            state = .trend
        } else if ofMode.count < required {
            state = .calibrating(completed: ofMode.count, required: required)
        } else {
            state = .awaitingFirstScore
        }
    }

    var latest: Point? { points.last }

    // MARK: - Scales

    /// Index points of air above and below the outermost value.
    static let domainPadding = 5
    /// Gridline spacing, in index points.
    static let gridStep = 10

    /// Always contains the baseline, so the reference rule is never off the
    /// chart, and snaps to the grid so the gridlines land on round numbers.
    var yDomain: ClosedRange<Int> {
        let values = points.map(\.index) + [baselineIndex]
        let low = (values.min() ?? baselineIndex) - Self.domainPadding
        let high = (values.max() ?? baselineIndex) + Self.domainPadding
        let lower = max(0, Int((Double(low) / Double(Self.gridStep)).rounded(.down)) * Self.gridStep)
        let upper = Int((Double(high) / Double(Self.gridStep)).rounded(.up)) * Self.gridStep
        return lower...upper
    }

    var gridValues: [Int] {
        Array(stride(from: yDomain.lowerBound, through: yDomain.upperBound, by: Self.gridStep))
    }

    /// Half a step of air either side, so the first and last points are not
    /// cut in half by the plot's edge.
    var xDomain: ClosedRange<Double> {
        0.5...(Double(max(points.count, 1)) + 0.5)
    }

    /// The walks that carry a date under the axis and a value above the point:
    /// the first, the middle and the latest, as the node labels three. Every
    /// point is still drawn and still reachable by VoiceOver; only the text is
    /// thinned, so a long history does not become a smear of numbers.
    var labelledPositions: [Int] {
        let count = points.count
        guard count > 0 else { return [] }
        return Array(Set([1, (count + 1) / 2, count])).sorted()
    }

    // MARK: - Copy

    var title: String { "\(mode.displayName) Trend" }

    static let baselineLabel = "Baseline"
    static let lastTestLabel = "Last Test"
    /// §6: the rule is labelled in lower case.
    static let baselineRuleLabel = "baseline"
    static let todayLabel = "Today"

    /// "(14 Sep 2026)", beside "Last Test", as the node writes it.
    func lastTestDate(locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        guard let latest else { return nil }
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        style.locale = locale
        style.timeZone = timeZone
        return "(\(latest.date.formatted(style)))"
    }

    /// "Aug 27", or "Today" for a walk from today.
    func axisLabel(
        for position: Int,
        now: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        guard points.indices.contains(position - 1) else { return "" }
        let date = points[position - 1].date

        var calendar = Calendar.current
        calendar.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            return Self.todayLabel
        }

        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.locale = locale
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// The headline under the card title while there is nothing to plot.
    var lockedHeadline: String? {
        switch state {
        case .trend: nil
        case .calibrating(let completed, let required): "\(completed) of \(required) calibration walks done"
        case .awaitingFirstScore: "Calibration walks done"
        }
    }

    /// What unlocks the trend. Encouraging, and exact: it never promises the
    /// *next* walk will be plotted, because a refused baseline would make that
    /// untrue.
    var lockedMessage: String? {
        switch state {
        case .trend:
            return nil
        case .calibrating(let completed, let required):
            let remaining = required - completed
            let tests = remaining == 1 ? mode.displayName : "\(mode.displayName)s"
            return """
                Complete \(SessionScorePresentation.spelledOut(remaining)) more valid \(tests) \
                to set your personal baseline. Your trend starts with the \(mode.displayName) after that.
                """
        case .awaitingFirstScore:
            return """
                Your trend starts with your first \(mode.displayName) scored against \
                your personal baseline.
                """
        }
    }

    /// §9: "Stability score 112, 8 points above your baseline."
    static func scoreSentence(index: Int, delta: Int) -> String {
        guard delta != 0 else { return "Stability score \(index), the same as your baseline." }
        let direction = delta > 0 ? "above" : "below"
        return "Stability score \(index), \(abs(delta)) points \(direction) your baseline."
    }

    func pointAccessibilityLabel(
        _ point: Point,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        var style = Date.FormatStyle.dateTime.day().month(.wide).year()
        style.locale = locale
        style.timeZone = timeZone
        return "\(point.date.formatted(style)). \(Self.scoreSentence(index: point.index, delta: point.delta))"
    }

    /// The chart, for a listener who cannot see the line.
    var accessibilitySummary: String {
        guard let latest else {
            return "\(title). \(lockedHeadline ?? ""). \(lockedMessage ?? "")"
        }
        let walks = points.count == 1 ? "1 walk" : "\(points.count) walks"
        return """
            \(title). \(walks) scored against your baseline of \(baselineIndex). \
            Latest: \(Self.scoreSentence(index: latest.index, delta: latest.delta))
            """
    }
}
