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
        await update { current in
            try current.replacingOptionalAnswers(
                timeSinceAmputationMonths: band?.lowerBoundMonths,
                prosthesisType: current.prosthesisType,
                kLevel: current.kLevel
            )
        }
    }

    func setProsthesisType(_ type: ProsthesisType?) async {
        await update { current in
            try current.replacingOptionalAnswers(
                timeSinceAmputationMonths: current.timeSinceAmputationMonths,
                prosthesisType: type?.rawValue,
                kLevel: current.kLevel
            )
        }
    }

    func setKLevel(_ level: KLevel?) async {
        await update { current in
            try current.replacingOptionalAnswers(
                timeSinceAmputationMonths: current.timeSinceAmputationMonths,
                prosthesisType: current.prosthesisType,
                kLevel: level
            )
        }
    }

    // MARK: - Saving

    /// The save in flight, so the next one waits for it.
    private var saveChain: Task<Void, Never>?

    /// Applies one answer change to the profile **as stored now**, one change
    /// at a time.
    ///
    /// Two things this guards against. The cached `profile` can be out of date
    /// — a restore replaces the store underneath this screen — and rebuilding
    /// from it would write the old level, side and disclaimer date back over
    /// the restored profile. And two edits made close together would otherwise
    /// both start from the same snapshot, so the second save would undo the
    /// first. So each change waits for the previous save, then reads the stored
    /// profile and changes only its own answer.
    private func update(_ change: @escaping @Sendable (UserProfile) throws -> UserProfile) async {
        let previous = saveChain
        let task = Task { @MainActor in
            await previous?.value
            await self.apply(change)
        }
        saveChain = task
        await task.value
    }

    private func apply(_ change: (UserProfile) throws -> UserProfile) async {
        saveFailure = nil
        do {
            guard let current = try await profiles.fetchProfile() else {
                profile = nil
                return
            }
            let updated = try change(current)
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
