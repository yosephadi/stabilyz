import Foundation
import SwiftUI
import Testing
@testable import Stabilyz

/// The History trend (Task 9.1.2, Figma node 64:7837, design-system §6).
///
/// Carries EPIC 6 audit #12's trend limb: the two modes render as separate
/// series and never share a line [PRD OQ-5].

private let day: TimeInterval = 86_400
private let origin = Date(timeIntervalSince1970: 1_800_000_000) // 15 Jan 2027, 08:00 UTC

private func at(_ days: Double) -> Date { origin.addingTimeInterval(days * day) }

/// Five calibration walks, each with a provisional score, on days 0-4.
private func calibration(_ mode: TestMode = .quickTest, provisional: Int = 70) -> [GaitSession] {
    (0..<5).map {
        GaitSession.fixtureValid(mode: mode, startedAt: at(Double($0)), provisionalScore: .fixture(value: provisional))
    }
}

private func scored(
    _ mode: TestMode = .quickTest,
    day: Double,
    index: Int,
    summary: String = "About usual for you."
) -> GaitSession {
    GaitSession.fixtureValid(
        mode: mode,
        startedAt: at(day),
        score: .fixture(relativeIndex: index, summaryLine: summary),
        provisionalScore: .fixture(value: 64)
    )
}

private func trend(_ mode: TestMode, _ sessions: [GaitSession]) -> StabilityTrend {
    StabilityTrend(
        mode: mode,
        rows: SessionHistoryRow.rows(from: sessions, baselineIndex: 100),
        baselineIndex: 100
    )
}

private let utc = TimeZone(identifier: "UTC")!
private let britain = Locale(identifier: "en_GB")

// MARK: - Calibrated walks only

@Test func provisionalWalksAreNeverPlotted() {
    let sixth = scored(day: 5, index: 108)
    let seventh = scored(day: 6, index: 112)

    let quick = trend(.quickTest, calibration(provisional: 95) + [sixth, seventh])

    #expect(quick.points.map(\.id) == [sixth.id, seventh.id])
    #expect(quick.points.map(\.index) == [108, 112])
    #expect(quick.state == .trend)
}

@Test func calibrationWalksAloneDrawNoLine() {
    let quick = trend(.quickTest, calibration(provisional: 80))
    #expect(quick.points.isEmpty)
    #expect(quick.state == .awaitingFirstScore)
}

@Test func aWalkPastCalibrationWithNoStoredScoreIsNotPlotted() {
    let unscoredSixth = GaitSession.fixtureValid(startedAt: at(5), provisionalScore: .fixture(value: 90))
    let seventh = scored(day: 6, index: 104)

    let quick = trend(.quickTest, calibration() + [unscoredSixth, seventh])

    #expect(quick.points.map(\.id) == [seventh.id])
    #expect(quick.points.first?.position == 1)
}

@Test func invalidWalksAreNeverPlotted() {
    let noisy = GaitSession.fixtureInvalid(startedAt: at(5))
    let quick = trend(.quickTest, calibration() + [noisy, scored(day: 6, index: 101)])
    #expect(quick.points.count == 1)
}

// MARK: - One mode, one series [PRD OQ-5]

@Test func onlyTheSelectedModesWalksArePlotted() {
    let quickSixth = scored(.quickTest, day: 10, index: 108)
    let fullSixth = scored(.fullTest, day: 11, index: 91)
    let sessions = calibration(.quickTest) + calibration(.fullTest) + [quickSixth, fullSixth]

    #expect(trend(.quickTest, sessions).points.map(\.id) == [quickSixth.id])
    #expect(trend(.fullTest, sessions).points.map(\.id) == [fullSixth.id])
}

@Test func anotherModesWalksCannotMoveThisModesTrend() {
    let quick = calibration(.quickTest) + [scored(day: 5, index: 108), scored(day: 7, index: 112)]
    let full = calibration(.fullTest) + [scored(.fullTest, day: 6, index: 80), scored(.fullTest, day: 8, index: 130)]

    // Interleaved dates, and still the same line, positions and domain.
    #expect(trend(.quickTest, quick) == trend(.quickTest, quick + full))
}

@Test func calibrationIsCountedWithinTheSelectedModeOnly() {
    let sessions = calibration(.quickTest) + [scored(day: 5, index: 110)]
        + (0..<2).map { GaitSession.fixtureValid(mode: .fullTest, startedAt: at(Double(10 + $0))) }

    #expect(trend(.fullTest, sessions).state == .calibrating(completed: 2, required: 5))
    #expect(trend(.quickTest, sessions).state == .trend)
}

// MARK: - The calibration card

@Test func noWalksYetIsCalibratingFromZero() {
    #expect(trend(.quickTest, []).state == .calibrating(completed: 0, required: 5))
}

@Test func fewerThanFiveValidWalksIsStillCalibrating() {
    for count in 1...4 {
        let sessions = Array(calibration().prefix(count))
        let quick = trend(.quickTest, sessions)
        #expect(quick.state == .calibrating(completed: count, required: 5))
        #expect(quick.points.isEmpty)
    }
}

@Test func theCalibrationCardSaysWhatUnlocksTheTrend() {
    let quick = trend(.quickTest, Array(calibration().prefix(3)))

    #expect(quick.lockedHeadline == "3 of 5 calibration walks done")
    #expect(quick.lockedMessage == "Complete two more valid Quick Tests to set your personal baseline. Your trend starts with the Quick Test after that.")
}

@Test func theLastCalibrationWalkIsSingular() {
    let full = trend(.fullTest, Array(calibration(.fullTest).prefix(4)))
    #expect(full.lockedMessage == "Complete one more valid Full Test to set your personal baseline. Your trend starts with the Full Test after that.")
}

@Test func afterCalibrationTheCardNeverPromisesTheNextWalk() {
    // A refused baseline leaves the sixth walk unscored too; "your next walk"
    // would be a promise the app cannot keep.
    let quick = trend(.quickTest, calibration() + [GaitSession.fixtureValid(startedAt: at(5))])

    #expect(quick.state == .awaitingFirstScore)
    #expect(quick.lockedHeadline == "Calibration walks done")
    #expect(quick.lockedMessage == "Your trend starts with your first Quick Test scored against your personal baseline.")
}

@Test func aTrendHasNoCalibrationCopy() {
    let quick = trend(.quickTest, calibration() + [scored(day: 5, index: 100)])
    #expect(quick.lockedHeadline == nil)
    #expect(quick.lockedMessage == nil)
}

// MARK: - The line

@Test func pointsRunOldestFirstAndCarryTheirDelta() {
    // Stored newest first, as History reads them.
    let sessions = calibration() + [scored(day: 7, index: 94), scored(day: 5, index: 108), scored(day: 6, index: 100)]
    let quick = trend(.quickTest, sessions)

    #expect(quick.points.map(\.position) == [1, 2, 3])
    #expect(quick.points.map(\.index) == [108, 100, 94])
    #expect(quick.points.map(\.delta) == [8, 0, -6])
    #expect(quick.latest?.index == 94)
}

@Test func theBaselineIsAlwaysInsideTheChart() {
    // Every point well above the baseline: the rule must still be on screen.
    let high = trend(.quickTest, calibration() + [scored(day: 5, index: 131), scored(day: 6, index: 142)])
    #expect(high.yDomain.contains(100))
    #expect(high.yDomain.contains(142))

    let low = trend(.quickTest, calibration() + [scored(day: 5, index: 71)])
    #expect(low.yDomain.contains(100))
    #expect(low.yDomain.contains(71))
}

@Test func theDomainLeavesAirAndLandsOnTheGrid() {
    let quick = trend(.quickTest, calibration() + [scored(day: 5, index: 108), scored(day: 6, index: 112)])

    #expect(quick.yDomain == 90...120)
    #expect(quick.gridValues == [90, 100, 110, 120])
    #expect(quick.yDomain.lowerBound < 100 && quick.yDomain.upperBound > 112)
}

@Test func theDomainNeverGoesBelowZero() {
    let quick = trend(.quickTest, calibration() + [scored(day: 5, index: 2)])
    #expect(quick.yDomain.lowerBound == 0)
}

@Test func threeWalksAtMostCarryText() {
    func labelled(_ count: Int) -> [Int] {
        let walks = (0..<count).map { scored(day: Double(5 + $0), index: 100 + $0) }
        return trend(.quickTest, calibration() + walks).labelledPositions
    }

    #expect(labelled(1) == [1])
    #expect(labelled(2) == [1, 2])
    #expect(labelled(3) == [1, 2, 3])
    #expect(labelled(9) == [1, 5, 9])
}

@Test func theAxisSaysTodayForAWalkFromToday() {
    let quick = trend(.quickTest, calibration() + [scored(day: 5, index: 108), scored(day: 20, index: 110)])

    #expect(quick.axisLabel(for: 2, now: at(20.2), locale: britain, timeZone: utc) == "Today")
    #expect(quick.axisLabel(for: 1, now: at(20.2), locale: britain, timeZone: utc) == "20 Jan")
    #expect(quick.axisLabel(for: 3, now: at(20.2), locale: britain, timeZone: utc) == "")
}

@Test func theLastTestIsTheLatestScoredWalkWithItsSummary() {
    let quick = trend(.quickTest, calibration() + [
        scored(day: 5, index: 102, summary: "Older."),
        scored(day: 6, index: 108, summary: "Your walking pattern was more consistent than in your recent Quick Tests.")
    ])

    #expect(quick.lastTestDate(locale: britain, timeZone: utc) == "(21 Jan 2027)")
    #expect(quick.latestSummary == "Your walking pattern was more consistent than in your recent Quick Tests.")
}

@Test func theCardIsTitledForItsMode() {
    #expect(trend(.quickTest, []).title == "Quick Test Trend")
    #expect(trend(.fullTest, []).title == "Full Test Trend")
}

@Test func voiceOverHearsTheTrendAsSentences() {
    let quick = trend(.quickTest, calibration() + [scored(day: 5, index: 102), scored(day: 6, index: 108)])

    #expect(quick.accessibilitySummary == "Quick Test Trend. 2 walks scored against your baseline of 100. Latest: Stability score 108, 8 points above your baseline.")
    let point = quick.points[0]
    #expect(quick.pointAccessibilityLabel(point, locale: britain, timeZone: utc) == "20 January 2027. Stability score 102, 2 points above your baseline.")
}

// MARK: - Tokens (§6, §8, §9)

private func luminance(_ color: Color, dark: Bool) -> Double {
    let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
    let resolved = UIColor(color).resolvedColor(with: traits)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
    func channel(_ value: CGFloat) -> Double {
        let v = Double(value)
        return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
}

private func alpha(_ color: Color, dark: Bool) -> CGFloat {
    let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    UIColor(color).resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
    return a
}

@Test func theTrendLineStaysLegibleOnTheCardInBothModes() {
    // A line the reader follows needs 3:1 against what it is drawn on (§9).
    for dark in [false, true] {
        let line = luminance(StabilyzColor.chartLine, dark: dark)
        let card = luminance(StabilyzColor.bgElevated, dark: dark)
        let ratio = (max(line, card) + 0.05) / (min(line, card) + 0.05)
        #expect(ratio >= 3, "chart line is \(ratio):1 on the card in \(dark ? "dark" : "light") mode")
    }
}

@Test func theAreaFillIsFlatAndHeavierInDarkMode() {
    // §6: ~15% in light mode, ~25% in dark.
    #expect(abs(alpha(StabilyzColor.chartArea, dark: false) - 0.15) < 0.01)
    #expect(abs(alpha(StabilyzColor.chartArea, dark: true) - 0.25) < 0.01)
}

@Test func theChartDrawsWithTheDocumentsStrokes() {
    #expect(ChartMetrics.lineWidth == 2)
    #expect(ChartMetrics.gridLineWidth == Metrics.hairline)
    #expect(ChartMetrics.baselineDash.isEmpty == false)
}
