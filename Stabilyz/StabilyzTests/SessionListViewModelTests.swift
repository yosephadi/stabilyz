import Foundation
import Testing
@testable import Stabilyz

/// The Result tab's session list (Task 9.1.1, Figma node 64:7837).
///
/// Valid-only, newest first, mode-labelled, split by mode [PRD §5, §7, OQ-5].

private final class HistoryLog: LogService, @unchecked Sendable {
    let entries = Locked<[String]>([])

    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        entries.withLock { $0.append(message) }
    }
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

/// Answers from a fixed set of sessions, honouring the filters it is asked for
/// — unless `leaky`, where it hands back invalid sessions regardless, so the
/// list's own check can be tested on its own.
private actor StubHistoryRepository: GaitSessionRepository {
    struct Unreadable: Error {}

    var stored: [GaitSession]
    var failing: Bool
    let leaky: Bool
    private(set) var queries: [(mode: TestMode, includeInvalid: Bool)] = []

    init(_ stored: [GaitSession] = [], failing: Bool = false, leaky: Bool = false) {
        self.stored = stored
        self.failing = failing
        self.leaky = leaky
    }

    func setFailing(_ failing: Bool) { self.failing = failing }
    func setStored(_ stored: [GaitSession]) { self.stored = stored }
    var queryCount: Int { queries.count }
    var queriedModes: [TestMode] { queries.map(\.mode) }
    var everAskedForInvalid: Bool { queries.contains { $0.includeInvalid } }

    func save(_ session: GaitSession) async throws {}
    func session(id: UUID) async throws -> GaitSession? { nil }
    func validSessionCount(mode: TestMode) async throws -> Int { 0 }

    func sessions(mode: TestMode, includeInvalid: Bool, limit: Int?) async throws -> [GaitSession] {
        queries.append((mode, includeInvalid))
        if failing { throw Unreadable() }
        return stored
            .filter { $0.mode == mode && (includeInvalid || leaky || $0.isValid) }
            .sorted { $0.startedAt > $1.startedAt }
    }
}

/// Holds the first read open until released, so the loading phase can be seen.
private actor GatedHistoryRepository: GaitSessionRepository {
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false

    var isWaiting: Bool { waiting != nil }

    func release() {
        released = true
        waiting?.resume()
        waiting = nil
    }

    func save(_ session: GaitSession) async throws {}
    func session(id: UUID) async throws -> GaitSession? { nil }
    func validSessionCount(mode: TestMode) async throws -> Int { 0 }

    func sessions(mode: TestMode, includeInvalid: Bool, limit: Int?) async throws -> [GaitSession] {
        if released == false {
            await withCheckedContinuation { waiting = $0 }
        }
        return []
    }
}

private let day: TimeInterval = 86_400
private let origin = Date(timeIntervalSince1970: 1_800_000_000)

private func at(_ days: Double) -> Date { origin.addingTimeInterval(days * day) }

/// Five calibration walks of a mode, on days 0-4.
private func calibration(_ mode: TestMode = .quickTest) -> [GaitSession] {
    (0..<5).map { GaitSession.fixtureValid(mode: mode, startedAt: at(Double($0))) }
}

@MainActor
private func makeModel(
    _ repository: GaitSessionRepository,
    log: HistoryLog = HistoryLog(),
    onSetUp: @escaping @MainActor (TestMode) -> Void = { _ in }
) -> SessionListViewModel {
    SessionListViewModel(sessions: repository, logService: log, baselineIndex: 100, onSetUp: onSetUp)
}

// MARK: - Valid only

@MainActor @Test func invalidSessionsNeverAppear() async {
    let valid = GaitSession.fixtureValid(startedAt: at(0))
    let invalid = GaitSession.fixtureInvalid(startedAt: at(1))
    let repository = StubHistoryRepository([valid, invalid])
    let model = makeModel(repository)

    await model.load()

    #expect(model.rows.map(\.id) == [valid.id])
    #expect(await repository.everAskedForInvalid == false)
}

@MainActor @Test func invalidSessionsAreDroppedEvenIfTheStoreHandsThemOver() async {
    let valid = GaitSession.fixtureValid(mode: .fullTest, startedAt: at(0))
    let noisy = GaitSession.fixtureInvalid(mode: .fullTest, startedAt: at(1))
    let model = makeModel(StubHistoryRepository([valid, noisy], leaky: true))

    await model.load()

    #expect(model.allRows.map(\.id) == [valid.id])
}

@MainActor @Test func anInvalidWalkDoesNotConsumeACalibrationNumber() async {
    let first = GaitSession.fixtureValid(startedAt: at(0))
    let noisy = GaitSession.fixtureInvalid(startedAt: at(1))
    let second = GaitSession.fixtureValid(startedAt: at(2))
    let model = makeModel(StubHistoryRepository([first, noisy, second], leaky: true))

    await model.load()

    #expect(model.rows.map(\.standing) == [
        .calibrating(walk: 2, required: 5, provisional: nil),
        .calibrating(walk: 1, required: 5, provisional: nil)
    ])
}

// MARK: - Order

@MainActor @Test func sessionsAreNewestFirst() async {
    let oldestQuick = GaitSession.fixtureValid(mode: .quickTest, startedAt: at(0))
    let middleFull = GaitSession.fixtureValid(mode: .fullTest, startedAt: at(1))
    let newestQuick = GaitSession.fixtureValid(mode: .quickTest, startedAt: at(2))
    // Stored out of order on purpose.
    let model = makeModel(StubHistoryRepository([middleFull, oldestQuick, newestQuick]))

    await model.load()

    #expect(model.allRows.map(\.id) == [newestQuick.id, middleFull.id, oldestQuick.id])
    #expect(model.rows.map(\.id) == [newestQuick.id, oldestQuick.id])
}

@MainActor @Test func everyQueryNamesItsModeAndBothModesAreRead() async {
    let repository = StubHistoryRepository()
    let model = makeModel(repository)

    await model.load()

    #expect(Set(await repository.queriedModes) == Set(TestMode.allCases))
    #expect(await repository.queryCount == TestMode.allCases.count)
}

// MARK: - The segment

@MainActor @Test func eachSegmentShowsOnlyItsMode() async {
    let quick = GaitSession.fixtureValid(mode: .quickTest, startedAt: at(0))
    let full = GaitSession.fixtureValid(mode: .fullTest, startedAt: at(1))
    let model = makeModel(StubHistoryRepository([quick, full]))
    await model.load()

    model.select(.quickTest)
    #expect(model.rows.map(\.id) == [quick.id])

    model.select(.fullTest)
    #expect(model.rows.map(\.id) == [full.id])
}

@MainActor @Test func theListOpensOnTheModeWalkedMostRecently() async {
    let quick = GaitSession.fixtureValid(mode: .quickTest, startedAt: at(0))
    let full = GaitSession.fixtureValid(mode: .fullTest, startedAt: at(1))
    let model = makeModel(StubHistoryRepository([quick, full]))

    #expect(model.mode == .quickTest)
    await model.load()
    #expect(model.mode == .fullTest)
}

@MainActor @Test func aSegmentTheUserChoseSurvivesAReload() async {
    let quick = GaitSession.fixtureValid(mode: .quickTest, startedAt: at(0))
    let full = GaitSession.fixtureValid(mode: .fullTest, startedAt: at(1))
    let model = makeModel(StubHistoryRepository([quick, full]))
    await model.load()

    model.select(.quickTest)
    await model.load()

    #expect(model.mode == .quickTest)
}

@MainActor @Test func switchingTheSegmentDoesNotReadTheStoreAgain() async {
    let repository = StubHistoryRepository([GaitSession.fixtureValid()])
    let model = makeModel(repository)
    await model.load()
    let reads = await repository.queryCount

    model.select(.fullTest)
    model.select(.quickTest)
    _ = model.rows

    #expect(await repository.queryCount == reads)
}

// MARK: - What a row may claim

@MainActor @Test func aScoredSessionCarriesItsIndexAndDeltaAgainstTheBaseline() async {
    let above = GaitSession.fixtureValid(startedAt: at(5), score: .fixture(relativeIndex: 108))
    let below = GaitSession.fixtureValid(startedAt: at(6), score: .fixture(relativeIndex: 94))
    let level = GaitSession.fixtureValid(startedAt: at(7), score: .fixture(relativeIndex: 100))
    let model = makeModel(StubHistoryRepository(calibration() + [above, below, level]))

    await model.load()

    #expect(Array(model.rows.prefix(3)).map(\.standing) == [
        .scored(index: 100, delta: 0),
        .scored(index: 94, delta: -6),
        .scored(index: 108, delta: 8)
    ])
    #expect(model.rows.first?.walkLabel == nil)
}

@MainActor @Test func aCalibrationWalkShowsItsProvisionalNumberBesideItsWalkCount() async {
    let first = GaitSession.fixtureValid(startedAt: at(0), provisionalScore: .fixture(value: 72))
    let second = GaitSession.fixtureValid(startedAt: at(1), provisionalScore: .fixture(value: 75))
    let model = makeModel(StubHistoryRepository([first, second]))

    await model.load()

    #expect(model.rows.map(\.standing) == [
        .calibrating(walk: 2, required: 5, provisional: 75),
        .calibrating(walk: 1, required: 5, provisional: 72)
    ])
    #expect(model.rows.map(\.walkLabel) == ["Walk 2 of 5", "Walk 1 of 5"])
}

@MainActor @Test func calibrationIsCountedWithinEachModeSeparately() async {
    let firstFull = GaitSession.fixtureValid(mode: .fullTest, startedAt: at(10))
    let model = makeModel(StubHistoryRepository(calibration() + [firstFull]))

    await model.load()

    // Five Quick Tests say nothing about the Full Test count [PRD OQ-5].
    model.select(.fullTest)
    #expect(model.rows.first?.walkLabel == "Walk 1 of 5")
    model.select(.quickTest)
    #expect(model.rows.first?.walkLabel == "Walk 5 of 5")
}

@MainActor @Test func aWalkPastCalibrationWithNoStoredScoreIsNotShownAsCalibration() async {
    let sixth = GaitSession.fixtureValid(startedAt: at(5), provisionalScore: .fixture(value: 70))
    let model = makeModel(StubHistoryRepository(calibration() + [sixth]))

    await model.load()

    #expect(model.rows.first?.standing == .notComparable)
    #expect(model.rows.first?.walkLabel == nil)
}

@MainActor @Test func aStoredScoreWinsOverTheProvisionalOne() async {
    let sixth = GaitSession.fixtureValid(
        startedAt: at(5),
        score: .fixture(relativeIndex: 112),
        provisionalScore: .fixture(value: 64)
    )
    let model = makeModel(StubHistoryRepository(calibration() + [sixth]))

    await model.load()

    #expect(model.rows.first?.standing == .scored(index: 112, delta: 12))
}

// MARK: - The page a row opens

@MainActor @Test func aRowOpensTheScoreScreenForItsOwnWalk() async {
    let second = GaitSession.fixtureValid(startedAt: at(1), provisionalScore: .fixture(value: 75))
    let sessions = [GaitSession.fixtureValid(startedAt: at(0)), second, GaitSession.fixtureValid(startedAt: at(2))]
    let model = makeModel(StubHistoryRepository(sessions))

    await model.load()

    let row = model.rows.first { $0.id == second.id }
    #expect(row?.detail == SessionScorePresentation(
        stored: second, walk: 2, validSessionCount: 3, baselineIndex: 100
    ))
    #expect(row?.detail.baselineProgress?.header == "Walk 2 of 5")
}

@MainActor @Test func aRowAndItsPageAgreeOnWhatTheWalkWas() async {
    let sixth = GaitSession.fixtureValid(startedAt: at(5), score: .fixture(relativeIndex: 108))
    let seventh = GaitSession.fixtureValid(startedAt: at(6))
    let model = makeModel(StubHistoryRepository(calibration() + [sixth, seventh]))

    await model.load()

    for row in model.rows {
        switch (row.standing, row.detail.progress) {
        case (.scored(let a, let b), .scored(let c, let d)):
            #expect(a == c && b == d)
        case (.calibrating(let a, let b, let c), .building(let d, let e, let f)):
            #expect(a == d && b == e && c == f)
        case (.notComparable, .notComparable):
            break
        default:
            Issue.record("row \(row.standing) opens a page showing \(row.detail.progress)")
        }
    }
}

// MARK: - Copy

private let britain = Locale(identifier: "en_GB")
private let utc = TimeZone(identifier: "UTC")!

@MainActor @Test func theRowTitleIsTheDateAsTheNodeWritesIt() async {
    let date = Date(timeIntervalSince1970: 1_788_912_000) // 9 Sep 2026, 00:00 UTC
    let model = makeModel(StubHistoryRepository([GaitSession.fixtureValid(startedAt: date)]))
    await model.load()

    #expect(model.rows.first?.title(locale: britain, timeZone: utc) == "9 Sep 2026")
}

@MainActor @Test func theSubtitleAlwaysNamesTheMode() async {
    let model = makeModel(StubHistoryRepository([GaitSession.fixtureValid(mode: .fullTest, startedAt: at(0))]))
    await model.load()

    let subtitle = model.rows.first?.subtitle(locale: britain, timeZone: utc) ?? ""
    #expect(subtitle.hasPrefix("Full Test · "))
}

@MainActor @Test func voiceOverHearsTheScoreAsASentence() async {
    let scored = GaitSession.fixtureValid(startedAt: at(5), score: .fixture(relativeIndex: 108))
    let model = makeModel(StubHistoryRepository(calibration() + [scored]))
    await model.load()

    let label = model.rows.first?.accessibilityLabel(locale: britain, timeZone: utc) ?? ""
    #expect(label.hasSuffix("Quick Test. Stability score 108, 8 points above your baseline."))
}

@MainActor @Test func voiceOverHearsProvisionalBeforeTheNumber() async {
    let first = GaitSession.fixtureValid(startedAt: at(0), provisionalScore: .fixture(value: 72))
    let model = makeModel(StubHistoryRepository([first]))
    await model.load()

    let label = model.rows.first?.accessibilityLabel(locale: britain, timeZone: utc) ?? ""
    #expect(label.hasSuffix("Provisional stability score 72 out of 100. Walk 1 of 5."))
}

// MARK: - Empty states

@MainActor @Test func aFirstEverEmptyStateSaysWhatTheListIsFor() async {
    let model = makeModel(StubHistoryRepository())
    await model.load()

    #expect(model.content == .empty)
    #expect(model.emptyState == SessionListViewModel.EmptyState(
        title: "No Quick Tests Yet",
        message: "Each Quick Test you finish shows up here. Your first five valid Quick Tests set your personal baseline, so later walks have something to be compared with.",
        actionTitle: "Set Up a Quick Test"
    ))
}

@MainActor @Test func anEmptyModeBesideAFullOneSaysTheModesAreKeptApart() async {
    // [PRD §6]: a Quick Test history, and Full Test opened for the first time.
    // An empty list here must not read as data lost.
    let model = makeModel(StubHistoryRepository(calibration(.quickTest)))
    await model.load()

    model.select(.fullTest)

    #expect(model.content == .empty)
    #expect(model.emptyState.title == "No Full Tests Yet")
    #expect(model.emptyState.message == "Full Tests keep their own baseline, separate from your Quick Tests. Your first five valid Full Tests set it.")
}

@MainActor @Test func theEmptyStateActionHandsTheModeToTheWalkTab() async {
    var handed: TestMode?
    let model = makeModel(StubHistoryRepository(), onSetUp: { handed = $0 })
    await model.load()

    model.select(.fullTest)
    model.setUp()

    #expect(handed == .fullTest)
}

// MARK: - Phases

@MainActor @Test func beforeTheFirstAnswerNothingIsClaimed() {
    let model = makeModel(StubHistoryRepository())
    #expect(model.phase == .idle)
    // Blank, not "no sessions": nothing has been read yet.
    #expect(model.content == .waiting)
    #expect(model.showsFailureBanner == false)
}

@MainActor @Test func aReadInProgressIsLoadingThenLoaded() async {
    let repository = GatedHistoryRepository()
    let model = makeModel(repository)

    let load = Task { await model.load() }
    var spins = 0
    while await repository.isWaiting == false, spins < 1_000 {
        await Task.yield()
        spins += 1
    }
    #expect(model.phase == .loading)
    #expect(model.content == .waiting)

    await repository.release()
    await load.value
    #expect(model.phase == .loaded)
    #expect(model.content == .empty)
}

@MainActor @Test func aReloadOverAnEmptyListDoesNotBlankIt() async {
    let repository = GatedHistoryRepository()
    await repository.release()
    let model = makeModel(repository)
    await model.load()

    // Already answered once: a refresh keeps the empty state up.
    model.select(.fullTest)
    #expect(model.content == .empty)
}

@MainActor @Test func sessionsOnScreenAreTheSessionsContent() async {
    let model = makeModel(StubHistoryRepository([GaitSession.fixtureValid()]))
    await model.load()
    #expect(model.content == .sessions)
}

@MainActor @Test func anUnreadableStoreSaysSoAndLogsIt() async {
    let log = HistoryLog()
    let model = makeModel(StubHistoryRepository(failing: true), log: log)

    await model.load()

    #expect(model.phase == .failed)
    #expect(model.content == .failed)
    #expect(model.showsFailureBanner == false)
    #expect(log.entries.withLock { $0 }.contains { $0.contains("history load failed") })
}

@MainActor @Test func aFailedRefreshKeepsTheListAndSaysSoAboveIt() async {
    let session = GaitSession.fixtureValid()
    let repository = StubHistoryRepository([session])
    let model = makeModel(repository)
    await model.load()

    await repository.setFailing(true)
    await model.load()

    #expect(model.phase == .failed)
    #expect(model.content == .sessions)
    #expect(model.showsFailureBanner)
    #expect(model.rows.map(\.id) == [session.id])
}

@MainActor @Test func retryingAfterAFailureRecovers() async {
    let session = GaitSession.fixtureValid()
    let repository = StubHistoryRepository([session], failing: true)
    let model = makeModel(repository)
    await model.load()
    #expect(model.content == .failed)

    await repository.setFailing(false)
    await model.load()

    #expect(model.phase == .loaded)
    #expect(model.content == .sessions)
    #expect(model.rows.map(\.id) == [session.id])
}

@MainActor @Test func reloadingPicksUpANewlyCommittedSession() async {
    let first = GaitSession.fixtureValid(startedAt: at(0))
    let repository = StubHistoryRepository([first])
    let model = makeModel(repository)
    await model.load()

    let next = GaitSession.fixtureValid(startedAt: at(1))
    await repository.setStored([first, next])
    await model.load()

    #expect(model.rows.map(\.id) == [next.id, first.id])
}
