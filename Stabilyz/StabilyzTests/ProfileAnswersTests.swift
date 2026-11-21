import Foundation
import Testing
@testable import Stabilyz

/// The three optional profile answers (decision 2026-11-14): time since
/// amputation is optional end to end, and all three are editable on the You tab.

private final class AnswersLog: LogService, @unchecked Sendable {
    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {}
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

private actor MemoryProfiles: UserProfileRepository {
    private(set) var stored: UserProfile?
    private(set) var saveCount = 0
    private var failure: StabilyzError?

    init(_ profile: UserProfile?, failure: StabilyzError? = nil) {
        stored = profile
        self.failure = failure
    }

    func fetchProfile() async throws -> UserProfile? { stored }
    func save(_ profile: UserProfile) async throws {
        if let failure { throw failure }
        // A real store write takes time; yielding lets a second edit start
        // while this one is still in flight.
        await Task.yield()
        stored = profile
        saveCount += 1
    }
    /// Stands in for a restore: the store changes underneath the screen.
    func replace(with profile: UserProfile?) { stored = profile }
}

private func profile(
    months: Int? = nil,
    prosthesis: String? = nil,
    kLevel: KLevel? = nil,
    level: AmputationLevel = .transfemoral,
    side: AmputationSide = .right
) -> UserProfile {
    try! UserProfile(
        id: UUID(), amputationLevel: level, side: side,
        timeSinceAmputationMonths: months, prosthesisType: prosthesis, kLevel: kLevel,
        disclaimerAcceptedAt: Date(timeIntervalSince1970: 1_700_000_000),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

@MainActor
private func loaded(_ p: UserProfile?, failure: StabilyzError? = nil) async -> (ProfileAnswersViewModel, MemoryProfiles) {
    let repo = MemoryProfiles(p, failure: failure)
    let model = ProfileAnswersViewModel(profiles: repo, logService: AnswersLog())
    await model.load()
    return (model, repo)
}

// MARK: - Domain

@Test func aProfileCanHaveNoTimeSinceAmputation() {
    #expect(profile(months: nil).timeSinceAmputationMonths == nil)
    #expect(profile(months: 0).timeSinceAmputationMonths == 0)
}

@Test func replacingTheOptionalAnswersNeverTouchesLevelSideOrDates() throws {
    let original = profile(months: 12, prosthesis: "other", kLevel: .k2, level: .transtibial, side: .left)
    let updated = try original.replacingOptionalAnswers(timeSinceAmputationMonths: nil, prosthesisType: nil, kLevel: .k4)
    #expect(updated.id == original.id)
    #expect(updated.amputationLevel == .transtibial)
    #expect(updated.side == .left)
    #expect(updated.disclaimerAcceptedAt == original.disclaimerAcceptedAt)
    #expect(updated.createdAt == original.createdAt)
    #expect(updated.timeSinceAmputationMonths == nil)
    #expect(updated.prosthesisType == nil)
    #expect(updated.kLevel == .k4)
}

// MARK: - Persistence and archive

@Test func aProfileWithoutTimeRoundTripsThroughTheStoreEntity() throws {
    let skipped = profile(months: nil)
    #expect(try EntityMapping.profile(from: EntityMapping.entity(from: skipped)).timeSinceAmputationMonths == nil)
    let answered = profile(months: 36)
    #expect(try EntityMapping.profile(from: EntityMapping.entity(from: answered)).timeSinceAmputationMonths == 36)
}

@Test func theArchiveRoundTripsAProfileWithAndWithoutTime() throws {
    for months in [nil, 24] as [Int?] {
        let data = try ArchiveJSON.encoder().encode(ArchivedProfile(profile(months: months)))
        let back = try ArchiveJSON.decoder().decode(ArchivedProfile.self, from: data).domain()
        #expect(back.timeSinceAmputationMonths == months)
    }
}

@Test func anArchivedProfileWrittenBeforeTheChangeStillReads() throws {
    // The older shape: the key is present, as it always was.
    let json = """
    {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","amputationLevel":"transtibial","side":"left",
     "timeSinceAmputationMonths":18,"prosthesisType":"everydayWalking","kLevel":"k3",
     "disclaimerAcceptedAt":721000000,"createdAt":721000000}
    """
    let decoded = try ArchiveJSON.decoder().decode(ArchivedProfile.self, from: Data(json.utf8)).domain()
    #expect(decoded.timeSinceAmputationMonths == 18)

    // And a skipped one: the key is simply absent.
    let skipped = json.replacingOccurrences(of: "\"timeSinceAmputationMonths\":18,", with: "")
    let back = try ArchiveJSON.decoder().decode(ArchivedProfile.self, from: Data(skipped.utf8)).domain()
    #expect(back.timeSinceAmputationMonths == nil)
}

// MARK: - You tab

@MainActor
@Test func unansweredItemsReadAsNotSet() async {
    let (model, _) = await loaded(profile())
    #expect(model.timeSummary == "Not set")
    #expect(model.prosthesisSummary == "Not set")
    #expect(model.kLevelSummary == "Not set")
    #expect(model.timeSinceAmputation == nil && model.prosthesisType == nil && model.kLevel == nil)
}

@MainActor
@Test func answeredItemsShowOnboardingsWording() async {
    let (model, _) = await loaded(profile(months: 12, prosthesis: "microprocessorKnee", kLevel: .k3))
    #expect(model.timeSummary == "1–2 years")
    #expect(model.prosthesisSummary == "Microprocessor-controlled knee")
    #expect(model.kLevelSummary == "K3 — community walking")
    #expect(model.timeSinceAmputation == .oneToTwoYears)
}

@MainActor
@Test func aRestoredValueOutsideTheListsIsShownAsIsAndNotLost() async {
    let (model, repo) = await loaded(profile(months: 30, prosthesis: "Ottobock C-Leg"))
    #expect(model.timeSummary == "30 months")
    #expect(model.prosthesisSummary == "Ottobock C-Leg")
    #expect(model.prosthesisType == nil)

    // Changing another item leaves them as they were.
    await model.setKLevel(.k2)
    let stored = await repo.stored
    #expect(stored?.timeSinceAmputationMonths == 30)
    #expect(stored?.prosthesisType == "Ottobock C-Leg")
    #expect(stored?.kLevel == .k2)
}

@MainActor
@Test func eachAnswerCanBeSetChangedAndClearedAndIsPersisted() async {
    let (model, repo) = await loaded(profile(level: .transtibial, side: .left))

    await model.setTimeSinceAmputation(.threeToFiveYears)
    await model.setProsthesisType(.activityOrSports)
    await model.setKLevel(.k4)
    var stored = await repo.stored
    #expect(stored?.timeSinceAmputationMonths == TimeSinceAmputation.threeToFiveYears.lowerBoundMonths)
    #expect(stored?.prosthesisType == ProsthesisType.activityOrSports.rawValue)
    #expect(stored?.kLevel == .k4)
    #expect(model.kLevelSummary == "K4 — high activity")

    await model.setTimeSinceAmputation(nil)
    await model.setProsthesisType(nil)
    await model.setKLevel(nil)
    stored = await repo.stored
    #expect(stored?.timeSinceAmputationMonths == nil)
    #expect(stored?.prosthesisType == nil)
    #expect(stored?.kLevel == nil)
    #expect(model.timeSummary == "Not set")
}

@MainActor
@Test func editingNeverChangesLevelOrSide() async {
    let (model, repo) = await loaded(profile(level: .bilateral, side: .both))
    await model.setTimeSinceAmputation(.underSixMonths)
    await model.setProsthesisType(.other)
    await model.setKLevel(.k1)
    let stored = await repo.stored
    #expect(stored?.amputationLevel == .bilateral)
    #expect(stored?.side == .both)
}

@MainActor
@Test func theListsAreOnboardingsOwn() {
    #expect(ProfileAnswersViewModel.kLevelOptions == OnboardingDraft.offeredKLevels)
    #expect(ProfileAnswersViewModel.timeOptions == TimeSinceAmputation.allCases)
    #expect(ProfileAnswersViewModel.prosthesisOptions == ProsthesisType.allCases)
}

@MainActor
@Test func aFailedSaveKeepsTheOldAnswerAndSaysSo() async {
    let (model, _) = await loaded(profile(kLevel: .k2), failure: .persistence(.saveFailed))
    await model.setKLevel(.k4)
    #expect(model.kLevel == .k2)
    #expect(model.saveFailure == .persistence(.saveFailed))
}

@MainActor
@Test func noProfileMeansNothingToEdit() async {
    let (model, repo) = await loaded(nil)
    await model.setKLevel(.k1)
    #expect(model.profile == nil)
    #expect(await repo.saveCount == 0)
}

// MARK: - Saves start from the stored profile, one at a time

@MainActor
@Test func anEditAfterARestoreKeepsTheRestoredProfile() async {
    let (model, repo) = await loaded(profile(kLevel: .k2, level: .transfemoral, side: .right))
    // A restore replaces the profile while the screen holds the old one.
    let restored = profile(prosthesis: "everydayWalking", level: .transtibial, side: .left)
    await repo.replace(with: restored)

    await model.setKLevel(.k3)

    let stored = await repo.stored
    #expect(stored?.id == restored.id)
    #expect(stored?.amputationLevel == .transtibial)
    #expect(stored?.side == .left)
    #expect(stored?.prosthesisType == "everydayWalking")
    #expect(stored?.kLevel == .k3)
}

@MainActor
@Test func twoEditsMadeTogetherBothLand() async {
    let (model, repo) = await loaded(profile())

    async let first: Void = model.setTimeSinceAmputation(.oneToTwoYears)
    async let second: Void = model.setProsthesisType(.microprocessorKnee)
    _ = await (first, second)

    let stored = await repo.stored
    #expect(stored?.timeSinceAmputationMonths == TimeSinceAmputation.oneToTwoYears.lowerBoundMonths)
    #expect(stored?.prosthesisType == ProsthesisType.microprocessorKnee.rawValue)
    #expect(await repo.saveCount == 2)
}
