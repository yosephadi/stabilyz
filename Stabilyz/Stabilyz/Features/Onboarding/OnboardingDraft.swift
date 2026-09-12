import Foundation

/// One screen of the wizard (docs/04 §4.3).
///
/// [PRD §7 AC] One field, or one tightly grouped field-set, per screen — so the
/// steps are the fields, and the progress indicator is a position in this list.
enum OnboardingStep: String, Codable, Sendable, CaseIterable {
    case amputationLevel
    case side
    case timeSinceAmputation
    case prosthesisType
    case kLevel
    case disclaimer

    var isOptionalField: Bool {
        self == .prosthesisType || self == .kLevel
    }
}

/// The in-progress wizard, persisted so a relaunch resumes rather than restarts
/// [PRD §6 edge case, §7 AC].
///
/// **The disclaimer tick is deliberately not a field here.** [PRD AC] requires
/// resuming *on* the final screen with the box unticked, and that is also the
/// only defensible behaviour: an acknowledgement is an affirmative act, and a
/// box that came back already ticked would be the app remembering a consent the
/// user never finished giving. Quitting on that screen costs one tap, not a
/// wizard.
///
/// Codable and tiny, persisted to `UserDefaults` (docs/05 §5.3) — it is
/// pre-profile and ephemeral, so it never touches the SwiftData store.
struct OnboardingDraft: Codable, Equatable, Sendable {
    /// Where the user was when they left.
    var step: OnboardingStep

    var amputationLevel: AmputationLevel?
    var side: AmputationSide?
    /// A band, not a month count: the screen offers five ranges and the domain
    /// converts. Required [PRD §5] — nil means unanswered.
    var timeSinceAmputation: TimeSinceAmputation?
    /// Optional [PRD AC] — nil is a complete answer.
    var prosthesisType: ProsthesisType?
    /// Optional [PRD AC] — nil is a complete answer.
    var kLevel: KLevel?

    init(
        step: OnboardingStep = .amputationLevel,
        amputationLevel: AmputationLevel? = nil,
        side: AmputationSide? = nil,
        timeSinceAmputation: TimeSinceAmputation? = nil,
        prosthesisType: ProsthesisType? = nil,
        kLevel: KLevel? = nil
    ) {
        self.step = step
        self.amputationLevel = amputationLevel
        self.side = side
        self.timeSinceAmputation = timeSinceAmputation
        self.prosthesisType = prosthesisType
        self.kLevel = kLevel
    }

    /// The sides a given level allows [REC — docs/04 §4.3 consistency rule].
    ///
    /// A bilateral amputation records `both` and a unilateral one records a
    /// single side; `UserProfile` throws on any other pairing. Offering only the
    /// valid options means the wizard cannot construct the state that would
    /// throw.
    static func allowedSides(for level: AmputationLevel?) -> [AmputationSide] {
        switch level {
        case .bilateral: [.both]
        case .transtibial, .transfemoral: [.left, .right]
        case nil: []
        }
    }

    /// The K-levels the wizard offers, which is **not** `KLevel.allCases`.
    ///
    /// The design's screen lists K1 to K4 and nothing else. K0 stays a real
    /// `KLevel` the domain supports — a restored export may carry one, and
    /// dropping it from the type would make that profile unreadable — but
    /// "not walking at present" is not an answer this wizard asks a walking-app
    /// user to give about themselves, so it is not offered.
    static let offeredKLevels: [KLevel] = [.k1, .k2, .k3, .k4]
}
