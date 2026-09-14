import Foundation

/// One line of session history, derived from one stored session
/// (docs/04 §4.13, Figma node 64:7837, [PRD §5, §7]).
///
/// A pure value so the list's rules — which sessions may appear, in what
/// order, and what each one may claim — are testable without rendering
/// (docs/11 §11.5).
struct SessionHistoryRow: Equatable, Identifiable {

    /// What the row may say about the walk's result.
    ///
    /// Read off `detail.progress` rather than decided separately, so the row
    /// and the page its chevron opens cannot disagree about what a walk was.
    enum Standing: Equatable {
        /// A relative index against this mode's baseline, as stored at commit.
        /// `delta` is signed against the baseline's reference index [PRD §7].
        case scored(index: Int, delta: Int)
        /// One of the mode's first five valid walks — the ones that build its
        /// baseline. `provisional` is the within-walk score on its own 0-100
        /// placeholder scale; the row shows it beside "Walk X of 5", which is
        /// the building framing [PRD §7 AC], and never with a delta. Nil when
        /// the walk could not be read against the anchors.
        case calibrating(walk: Int, required: Int, provisional: Int?)
        /// Past calibration, and yet no score was stored — the commit could not
        /// complete one (docs/09 §9.5), or the baseline was refused.
        case notComparable
    }

    let id: UUID
    let mode: TestMode
    let startedAt: Date
    let standing: Standing
    /// The Score screen for this walk, as the row's chevron opens it.
    let detail: SessionScorePresentation

    // MARK: - Building the list

    /// Rows for every **user-visible** session, newest first.
    ///
    /// Invalid sessions are dropped here even though the repository was asked
    /// not to return them: they must never appear in History [PRD §5, §6], and
    /// a second check costs nothing next to a list that shows one.
    ///
    /// Calibration walks are numbered **within their own mode** from the valid
    /// sessions alone, so a Full Test after five Quick Tests is still walk 1
    /// [PRD OQ-5], and an invalid walk never consumes a number.
    ///
    /// - Parameter baselineIndex: what a baseline scores by construction
    ///   [PRD §7]. Passed in so the delta follows the configuration the score
    ///   was computed under, as the Score screen's does.
    static func rows(from sessions: [GaitSession], baselineIndex: Int) -> [SessionHistoryRow] {
        let visible = sessions.filter(\.isUserVisible)

        var rows: [SessionHistoryRow] = []
        for mode in TestMode.allCases {
            let oldestFirst = visible
                .filter { $0.mode == mode }
                .sorted { $0.startedAt < $1.startedAt }
            for (offset, session) in oldestFirst.enumerated() {
                rows.append(SessionHistoryRow(
                    session: session,
                    walk: offset + 1,
                    validSessionCount: oldestFirst.count,
                    baselineIndex: baselineIndex
                ))
            }
        }

        return rows.sorted { lhs, rhs in
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
            // Same instant is not a real case, but the order must still be
            // stable from one load to the next.
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private init(session: GaitSession, walk: Int, validSessionCount: Int, baselineIndex: Int) {
        self.id = session.id
        self.mode = session.mode
        self.startedAt = session.startedAt
        self.detail = SessionScorePresentation(
            stored: session,
            walk: walk,
            validSessionCount: validSessionCount,
            baselineIndex: baselineIndex
        )

        switch detail.progress {
        case .scored(let index, let delta):
            standing = .scored(index: index, delta: delta)
        case .building(let walk, let required, let provisional):
            standing = .calibrating(walk: walk, required: required, provisional: provisional)
        case .notComparable:
            standing = .notComparable
        }
    }

    // MARK: - Copy

    /// "9 Sep 2026", as the node draws it, in the reader's own date order.
    func title(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        style.locale = locale
        style.timeZone = timeZone
        return startedAt.formatted(style)
    }

    /// The mode and the time. The mode is on every row even though the segment
    /// above names it: the row must say which mode its number belongs to
    /// [PRD §5 AC, OQ-5], and a row read out by VoiceOver has no segment.
    func subtitle(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.locale = locale
        style.timeZone = timeZone
        return "\(mode.displayName) · \(startedAt.formatted(style))"
    }

    /// "Walk 3 of 5" under a calibration walk's number; nil on every other row.
    var walkLabel: String? {
        guard case .calibrating(let walk, let required, _) = standing else { return nil }
        return "Walk \(walk) of \(required)"
    }

    static let noScoreLabel = "No score"
    static let notComparedLabel = "Not compared"
    static let sameAsBaselineLabel = "same"

    /// §9's wording: a number is not a sentence.
    func accessibilityLabel(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let heading = "\(title(locale: locale, timeZone: timeZone)), \(mode.displayName)."
        switch standing {
        case .scored(let index, let delta):
            guard delta != 0 else {
                return "\(heading) Stability score \(index), the same as your baseline."
            }
            let direction = delta > 0 ? "above" : "below"
            return "\(heading) Stability score \(index), \(abs(delta)) points \(direction) your baseline."
        case .calibrating(let walk, let required, let provisional):
            // "Provisional" leads, as on the Score screen: a listener who stops
            // early must not be left with the bare number.
            let result = provisional.map { "Provisional stability score \($0) out of 100." } ?? "No score."
            return "\(heading) \(result) Walk \(walk) of \(required)."
        case .notComparable:
            return "\(heading) No score. This walk could not be compared against your baseline."
        }
    }
}
