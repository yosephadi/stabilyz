import Foundation

/// The three optional profile answers on the You tab: time since amputation,
/// prosthesis type and K-level.
///
/// Amputation level and side are deliberately **not** editable here — they
/// gate step-time asymmetry — so every change goes through
/// `UserProfile.replacingOptionalAnswers`, which carries them over untouched.
/// The option lists and wording are onboarding's own (`OnboardingDraft`,
/// `ProfileAnswerCopy`); this type adds no list of its own.
///
/// An unanswered item reads as "Not set".
@MainActor
@Observable
final class ProfileAnswersViewModel {
    private(set) var profile: UserProfile?
    /// Set when a change could not be saved; the old answer is kept.
    private(set) var saveFailure: StabilyzError?

    private let profiles: UserProfileRepository
    private let logService: LogService

    init(profiles: UserProfileRepository, logService: LogService) {
        self.profiles = profiles
        self.logService = logService
    }

    func load() async {
        do {
            profile = try await profiles.fetchProfile()
        } catch {
            logService.log(.error, .app, "profile answers could not be loaded")
        }
    }

    // MARK: - What the lists offer

    static let timeOptions = TimeSinceAmputation.allCases
    static let prosthesisOptions = ProsthesisType.allCases
    static let kLevelOptions = OnboardingDraft.offeredKLevels

    // MARK: - Current answers

    /// `nil` when unanswered, or when a restored value matches no band.
    var timeSinceAmputation: TimeSinceAmputation? {
        profile?.timeSinceAmputationMonths.flatMap { TimeSinceAmputation(lowerBoundMonths: $0) }
    }

    /// `nil` when unanswered, or when a restored string predates the list.
    var prosthesisType: ProsthesisType? {
        profile?.prosthesisType.flatMap { ProsthesisType(rawValue: $0) }
    }

    var kLevel: KLevel? { profile?.kLevel }

    // MARK: - Row summaries

    var timeSummary: String { ProfileAnswerCopy.timeLabel(months: profile?.timeSinceAmputationMonths) }
    var prosthesisSummary: String { ProfileAnswerCopy.prosthesisLabel(stored: profile?.prosthesisType) }
    var kLevelSummary: String { ProfileAnswerCopy.kLevelLabel(stored: profile?.kLevel) }

    // MARK: - Changes (nil clears an answer)

    func setTimeSinceAmputation(_ band: TimeSinceAmputation?) async {
        guard let profile else { return }
        await save {
            try profile.replacingOptionalAnswers(
                timeSinceAmputationMonths: band?.lowerBoundMonths,
                prosthesisType: profile.prosthesisType,
                kLevel: profile.kLevel
            )
        }
    }

    func setProsthesisType(_ type: ProsthesisType?) async {
        guard let profile else { return }
        await save {
            try profile.replacingOptionalAnswers(
                timeSinceAmputationMonths: profile.timeSinceAmputationMonths,
                prosthesisType: type?.rawValue,
                kLevel: profile.kLevel
            )
        }
    }

    func setKLevel(_ level: KLevel?) async {
        guard let profile else { return }
        await save {
            try profile.replacingOptionalAnswers(
                timeSinceAmputationMonths: profile.timeSinceAmputationMonths,
                prosthesisType: profile.prosthesisType,
                kLevel: level
            )
        }
    }

    private func save(_ makeUpdated: () throws -> UserProfile) async {
        saveFailure = nil
        do {
            let updated = try makeUpdated()
            try await profiles.save(updated)
            profile = updated
        } catch let error as StabilyzError {
            saveFailure = error
            logService.log(.error, .app, "profile answers could not be saved")
        } catch {
            saveFailure = .persistence(.saveFailed)
            logService.log(.error, .app, "profile answers could not be saved")
        }
    }
}
