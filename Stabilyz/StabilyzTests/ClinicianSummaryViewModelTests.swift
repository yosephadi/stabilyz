import Foundation
import Testing
@testable import Stabilyz

/// The Clinician Summary (Task 9.2.1, docs/04 §4.14, [PRD §5, §6, §7]).
///
/// Every mode state, the scored-only window of five, objective copy, and mode
/// segregation [PRD OQ-5].

private final class ClinicianLog: LogService, @unchecked Sendable {
    let entries = Locked<[String]>([])

    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        entries.withLock { $0.append(message) }
    }
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

/// Counts and lists from one set of sessions, so the two can never disagree.
/// `leaky` hands back invalid sessions regardless of what was asked.
private actor ClinicianSessions: GaitSessionRepository {
    struct Unreadable: Error {}

    var stored: [GaitSession]
    var failing = false
    let leaky: Bool
    private(set) var queries: [(mode: TestMode, includeInvalid: Bool)] = []

    init(_ stored: [GaitSession] = [], leaky: Bool = false) {
        self.stored = stored
        self.leaky = leaky
    }

    func setFailing(_ failing: Bool) { self.failing = failing }
    var queriedModes: [TestMode] { queries.map(\.mode) }
    var everAskedForInvalid: Bool { queries.contains { $0.includeInvalid } }

    func save(_ session: GaitSession) async throws {}
    func session(id: UUID) async throws -> GaitSession? { nil }

    func validSessionCount(mode: TestMode) async throws -> Int {
        if failing { throw Unreadable() }
        return stored.filter { $0.mode == mode && $0.isValid }.count
    }

    func sessions(mode: TestMode, includeInvalid: Bool, limit: Int?) async throws -> [GaitSession] {
        queries.append((mode, includeInvalid))
        if failing { throw Unreadable() }
        let matching = stored
            .filter { $0.mode == mode && (includeInvalid || leaky || $0.isValid) }
            .sorted { $0.startedAt > $1.startedAt }
        return limit.map { Array(matching.prefix($0)) } ?? matching
    }
}

private actor ClinicianBaselines: BaselineRepository {
    var stored: [TestMode: Baseline]

    init(_ stored: [TestMode: Baseline] = [:]) {
        self.stored = stored
    }

    func baseline(mode: TestMode) async throws -> Baseline? { stored[mode] }
    func save(_ baseline: Baseline) async throws { stored[baseline.mode] = baseline }
    func allBaselines() async throws -> [Baseline] { Array(stored.values) }
}

private let day: TimeInterval = 86_400
private let origin = Date(timeIntervalSince1970: 1_800_000_000) // 15 Jan 2027, 08:00 UTC
private let utc = TimeZone(identifier: "UTC")!
private let britain = Locale(identifier: "en_GB")
private let us = Locale(identifier: "en_US")

private func at(_ days: Double) -> Date { origin.addingTimeInterval(days * day) }

/// Calibration walks carrying provisional scores, so a test can prove none of
/// those numbers reach the screen.
private func calibration(_ mode: TestMode = .quickTest, count: Int = 5) -> [GaitSession] {
    (0..<count).map {
        GaitSession.fixtureValid(mode: mode, startedAt: at(Double($0)), provisionalScore: .fixture(value: 88))
    }
}

private func scored(_ mode: TestMode = .quickTest, day: Double, index: Int) -> GaitSession {
    GaitSession.fixtureValid(
        mode: mode,
        startedAt: at(day),
        score: .fixture(relativeIndex: index),
        provisionalScore: .fixture(value: 61)
    )
}

private func baseline(_ mode: TestMode = .quickTest, asymmetry: Bool = true) -> Baseline {
    var stats = [
        BaselineMetricStat(metricID: .stepRegularity, mean: 0.82, sd: 0.04, n: 5, sdFloorApplied: false),
        BaselineMetricStat(metricID: .cadenceMean, mean: 104.26, sd: 2.0, n: 5, sdFloorApplied: true),
        BaselineMetricStat(metricID: .stepTimeCV, mean: 0.0412, sd: 0.0104, n: 5, sdFloorApplied: false)
    ]
    if asymmetry {
        stats.append(BaselineMetricStat(metricID: .stepTimeAsymmetry, mean: 0.062, sd: 0.021, n: 4, sdFloorApplied: false))
    }
    return try! Baseline(
        id: UUID(),
        mode: mode,
        stats: stats,
        cadenceBPM: 104.26,
        algorithmVersion: "1.0.0",
        establishedAt: origin,
        sourceSessionIDs: (0..<5).map { _ in UUID() }
    )
}

@MainActor
private func makeModel(
    _ sessions: ClinicianSessions,
    _ baselines: ClinicianBaselines = ClinicianBaselines(),
    mode: TestMode = .quickTest,
    log: ClinicianLog = ClinicianLog()
) -> ClinicianSummaryViewModel {
    ClinicianSummaryViewModel(
        sessions: sessions,
        baselines: baselines,
        logService: log,
        baselineIndex: 100,
        mode: mode
    )
}

/// A loaded model for one mode's sessions and baseline.
@MainActor
private func loaded(
    _ sessions: [GaitSession],
    baselines: [TestMode: Baseline] = [:],
    mode: TestMode = .quickTest
) async -> ClinicianSummaryViewModel {
    let model = makeModel(ClinicianSessions(sessions), ClinicianBaselines(baselines), mode: mode)
    await model.load()
    return model
}

// MARK: - The window

@Test func theWindowIsFiveAndTheSummaryLineWindowIsUntouched() {
    #expect(ClinicianSummaryPolicy.recentScoredSessionCount == 5)
    // Decided separately: user summary lines keep their own versioned window.
    #expect(AlgorithmConfiguration.v1.summary.recentSessionCount == 3)
}

@MainActor @Test func theListIsTheFiveNewestScoredWalks() async {
    let walks = (5..<13).map { scored(day: Double($0), index: 100 + $0) }
    let model = await loaded(calibration() + walks, baselines: [.quickTest: baseline()])

    let recent = model.selected?.recent ?? []
    #expect(recent.map(\.id) == walks.suffix(5).reversed().map(\.id))
    #expect(recent.map(\.index) == [112, 111, 110, 109, 108])
    #expect(model.selected?.recentTitle == "Last 5 Sessions")
}

@MainActor @Test func calibrationWalksNeverCountTowardTheFive() async {
    let sixth = scored(day: 5, index: 104)
    let seventh = scored(day: 6, index: 97)
    let sessions = calibration() + [sixth, seventh]
    let model = await loaded(sessions, baselines: [.quickTest: baseline()])

    let recent = model.selected?.recent ?? []
    #expect(recent.map(\.id) == [seventh.id, sixth.id])
    let calibrationIDs = Set(sessions.prefix(5).map(\.id))
    #expect(recent.allSatisfy { calibrationIDs.contains($0.id) == false })
}

@MainActor @Test func anUnscoredWalkAfterCalibrationIsNotListed() async {
    let unscored = GaitSession.fixtureValid(startedAt: at(5), provisionalScore: .fixture(value: 70))
    let scoredWalk = scored(day: 6, index: 101)
    let model = await loaded(calibration() + [unscored, scoredWalk], baselines: [.quickTest: baseline()])

    #expect(model.selected?.recent.map(\.id) == [scoredWalk.id])
}

@MainActor @Test func aSmallerWindowIsHonoured() async {
    let walks = (5..<9).map { scored(day: Double($0), index: 100) }
    let model = ClinicianSummaryViewModel(
        sessions: ClinicianSessions(calibration() + walks),
        baselines: ClinicianBaselines([.quickTest: baseline()]),
        logService: ClinicianLog(),
        baselineIndex: 100,
        recentCount: 2
    )
    await model.load()

    #expect(model.selected?.recent.count == 2)
    #expect(model.selected?.recentTitle == "Last 2 Sessions")
}

@MainActor @Test func theTrendPlotsEveryScoredWalkNotJustTheFive() async {
    let walks = (5..<13).map { scored(day: Double($0), index: 100) }
    let model = await loaded(calibration() + walks, baselines: [.quickTest: baseline()])

    #expect(model.selected?.trend?.points.count == 8)
    #expect(model.selected?.trend?.mode == .quickTest)
}

// MARK: - Every mode state

@MainActor @Test func aModeWithNoWalksIsNotStarted() async {
    let model = await loaded([])

    #expect(model.selected?.status == .notStarted)
    #expect(model.selected?.statusText() == "No Quick Tests recorded.")
    #expect(model.selected?.baseline == nil)
    #expect(model.selected?.recent.isEmpty == true)
    #expect(model.selected?.trend == nil)
}

@MainActor @Test func aCalibratingModeShowsProgressAndNoNumbers() async {
    let model = await loaded(calibration(count: 3))
    let summary = model.selected

    #expect(summary?.status == .calibrating(completed: 3, required: 5))
    #expect(summary?.statusText() == "Calibrating: 3 of 5 walks completed")
    // The provisional 88s exist in the store and reach nothing here.
    #expect(summary?.baseline == nil)
    #expect(summary?.recent.isEmpty == true)
    #expect(summary?.trend == nil)
}

@MainActor @Test func aRefusedBaselineIsItsOwnStateAndNeverSevenOfFive() async {
    let refused = calibration() + [GaitSession.fixtureValid(startedAt: at(5)), GaitSession.fixtureValid(startedAt: at(6))]
    let model = await loaded(refused)
    let summary = model.selected

    #expect(summary?.status == .baselineRefused)
    #expect(summary?.statusText() == "Baseline could not be established from the first 5 calibration walks.")
    #expect(summary?.statusText().contains("7") == false)
    #expect(summary?.baseline == nil)
    #expect(summary?.trend == nil)
}

@MainActor @Test func theRefusedCopyNamesNoCause() {
    // Decided cause-neutral: nothing stored can confirm a reason.
    for cause in ["variance", "alike", "version"] {
        #expect(ClinicianModeSummary.refusedText.localizedCaseInsensitiveContains(cause) == false)
    }
}

@MainActor @Test func anEstablishedModeCarriesItsBaselineParameters() async {
    let model = await loaded(calibration() + [scored(day: 5, index: 108)], baselines: [.quickTest: baseline()])
    let summary = model.selected

    #expect(summary?.status == .established)
    #expect(summary?.statusText(locale: britain, timeZone: utc) == "Established 15 Jan 2027 · from 5 calibration walks")

    let parameters = summary?.baseline?.parameters ?? []
    // Physical units only: the stored step-regularity stat is not listed.
    #expect(parameters.map(\.metric) == [.cadenceMean, .stepTimeCV, .stepTimeAsymmetry])
    #expect(parameters.map(\.label) == ["Cadence", "Step-time variability", "Step-time asymmetry"])
    #expect(parameters.map { $0.displayValue(locale: us) } == ["104.3 ± 2.0 spm*", "4.1 ± 1.0%", "6.2 ± 2.1%"])
    #expect(parameters.map(\.sampleSize) == ["n = 5", "n = 5", "n = 4"])
}

@MainActor @Test func aFlooredSpreadIsMarkedAndFootnoted() async {
    let model = await loaded(calibration(), baselines: [.quickTest: baseline()])
    #expect(model.selected?.baseline?.anyFloorApplied == true)

    let unfloored = BaselineMetricStat(metricID: .cadenceMean, mean: 98, sd: 3.46, n: 5, sdFloorApplied: false)
    #expect(ClinicianModeSummary.meanAndSD(unfloored, locale: us) == "98.0 ± 3.5 spm")
}

@MainActor @Test func anAsymmetryStatTheBaselineNeverHadReadsNotEstablished() async {
    let model = await loaded(calibration(), baselines: [.quickTest: baseline(asymmetry: false)])
    let asymmetry = model.selected?.baseline?.parameters.first { $0.metric == .stepTimeAsymmetry }

    #expect(asymmetry?.stat == nil)
    #expect(asymmetry?.displayValue(locale: us) == "Not established")
    #expect(asymmetry?.sampleSize == nil)
}

@MainActor @Test func anEstablishedModeWithNoScoredWalkYetHasAnEmptyList() async {
    let model = await loaded(calibration(), baselines: [.quickTest: baseline()])

    #expect(model.selected?.status == .established)
    #expect(model.selected?.recent.isEmpty == true)
    #expect(model.selected?.trend?.state == .awaitingFirstScore)
}

// MARK: - A recent session is objective

@MainActor @Test func aRecentSessionShowsItsDateScoreSignedDeltaAndValues() async {
    let model = await loaded(
        calibration() + [scored(day: 5, index: 108), scored(day: 6, index: 94), scored(day: 7, index: 100)],
        baselines: [.quickTest: baseline()]
    )
    let recent = model.selected?.recent ?? []

    #expect(recent.map(\.deltaText) == ["0", "-6", "+8"])
    // The date is fixed; whether the hour is zero-padded follows the runtime's
    // locale data ("8:00" on iOS 26.4 for en_GB), so only its value is pinned.
    let title = recent.last?.title(locale: britain, timeZone: utc) ?? ""
    #expect(title.hasPrefix("20 Jan 2027 · "))
    #expect(title.hasSuffix("8:00"))
    #expect(recent.first?.measurements.map(\.metric) == [.cadenceMean, .stepTimeCV, .stepTimeAsymmetry])
}

@Test func measuredValuesCarryTheirUnits() {
    #expect(ClinicianModeSummary.value(104.26, for: .cadenceMean, locale: us) == "104.3 spm")
    #expect(ClinicianModeSummary.value(0.0412, for: .stepTimeCV, locale: us) == "4.1%")
    #expect(ClinicianModeSummary.value(0.062, for: .stepTimeAsymmetry, locale: us) == "6.2%")
}

@Test func anUnmeasuredValueSaysSoRatherThanZero() {
    let measurement = ClinicianModeSummary.Measurement(metric: .stepTimeAsymmetry, value: nil)
    #expect(measurement.displayValue(locale: us) == "Not detected")
}

// MARK: - Valid only, one mode at a time [PRD OQ-5]

@MainActor @Test func invalidWalksNeverAppear() async {
    let noisy = GaitSession.fixtureInvalid(startedAt: at(9))
    let walk = scored(day: 5, index: 103)
    let sessions = ClinicianSessions(calibration() + [walk, noisy], leaky: true)
    let model = makeModel(sessions, ClinicianBaselines([.quickTest: baseline()]))
    await model.load()

    #expect(model.selected?.recent.map(\.id) == [walk.id])
    #expect(model.selected?.trend?.points.count == 1)
    #expect(await sessions.everAskedForInvalid == false)
}

@MainActor @Test func theModesNeverShareASection() async {
    let quickWalk = scored(.quickTest, day: 5, index: 108)
    let sessions = calibration(.quickTest) + [quickWalk] + calibration(.fullTest, count: 2)
    let model = await loaded(sessions, baselines: [.quickTest: baseline(.quickTest)])

    model.select(.quickTest)
    #expect(model.selected?.mode == .quickTest)
    #expect(model.selected?.status == .established)
    #expect(model.selected?.recent.map(\.id) == [quickWalk.id])

    model.select(.fullTest)
    #expect(model.selected?.mode == .fullTest)
    #expect(model.selected?.status == .calibrating(completed: 2, required: 5))
    #expect(model.selected?.baseline == nil)
    #expect(model.selected?.recent.isEmpty == true)
}

@MainActor @Test func anotherModesWalksCannotChangeThisModesSection() async {
    let quick = calibration(.quickTest) + [scored(day: 5, index: 108), scored(day: 6, index: 111)]
    let full = calibration(.fullTest) + [scored(.fullTest, day: 5, index: 80), scored(.fullTest, day: 7, index: 130)]
    let quickBaseline = baseline(.quickTest)

    let alone = await loaded(quick, baselines: [.quickTest: quickBaseline])
    let together = await loaded(quick + full, baselines: [.quickTest: quickBaseline, .fullTest: baseline(.fullTest)])

    #expect(alone.summaries[.quickTest] == together.summaries[.quickTest])
}

@MainActor @Test func everyReadNamesItsMode() async {
    let sessions = ClinicianSessions()
    let model = makeModel(sessions)
    await model.load()

    #expect(Set(await sessions.queriedModes) == Set(TestMode.allCases))
    #expect(Set(model.summaries.keys) == Set(TestMode.allCases))
}

@MainActor @Test func aBaselineFromTheOtherModeFailsRatherThanBlending() async {
    let log = ClinicianLog()
    let model = makeModel(
        ClinicianSessions(calibration(.fullTest)),
        ClinicianBaselines([.fullTest: baseline(.quickTest)]),
        log: log
    )
    await model.load()

    #expect(model.phase == .failed)
    #expect(model.summaries.isEmpty)
    #expect(log.entries.withLock { $0 }.contains { $0.contains("clinician summary load failed") })
}

// MARK: - Phases and selection

@MainActor @Test func theScreenOpensOnTheModeItWasGiven() {
    let model = makeModel(ClinicianSessions(), mode: .fullTest)
    #expect(model.mode == .fullTest)
    #expect(model.phase == .idle)
    #expect(model.selected == nil)
    #expect(model.showsFailureBanner == false)
}

@MainActor @Test func aSuccessfulReadIsLoaded() async {
    let model = await loaded(calibration(count: 1))
    #expect(model.phase == .loaded)
    #expect(model.selected != nil)
}

@MainActor @Test func aFailedRefreshKeepsTheLastSummaryAndSaysSo() async {
    let sessions = ClinicianSessions(calibration(count: 2))
    let model = makeModel(sessions)
    await model.load()

    await sessions.setFailing(true)
    await model.load()

    #expect(model.phase == .failed)
    #expect(model.showsFailureBanner)
    #expect(model.selected?.status == .calibrating(completed: 2, required: 5))
}

@MainActor @Test func aFirstReadThatFailsShowsNoSection() async {
    let sessions = ClinicianSessions()
    await sessions.setFailing(true)
    let model = makeModel(sessions)
    await model.load()

    #expect(model.phase == .failed)
    #expect(model.selected == nil)
    #expect(model.showsFailureBanner == false)
}
