import Foundation

/// Amputation level [PRD §5].
enum AmputationLevel: String, Sendable, CaseIterable, Codable {
    case transtibial
    case transfemoral
    case bilateral

    /// Whether a single prosthetic side exists, which is what makes the
    /// secondary step-time asymmetry feature meaningful [PRD §7, OQ-1].
    var isUnilateral: Bool { self != .bilateral }
}

/// Affected side [PRD §5].
enum AmputationSide: String, Sendable, CaseIterable, Codable {
    case left
    case right
    case both
}

/// Medicare functional classification [PRD §5 — optional field].
enum KLevel: String, Sendable, CaseIterable, Codable {
    case k0, k1, k2, k3, k4
}

/// How long ago the amputation was, in the bands the onboarding screen offers
/// (docs/design/screens).
///
/// Bands rather than a number because that is the question the design asks, and
/// "An estimate is fine" is the subtitle it asks it with. Someone eighteen
/// months post-amputation does not reliably know whether that is seventeen or
/// nineteen, and a wheel that made them pick one was asking for a precision the
/// answer does not carry.
///
/// The design leaves a gap between "1-2 years" and "3-5 years". That gap is the
/// design's, not an omission here — a two-and-a-half-year answer rounds down to
/// the band below it, as every band does.
enum TimeSinceAmputation: String, Sendable, CaseIterable, Codable {
    case underSixMonths
    case sixToTwelveMonths
    case oneToTwoYears
    case threeToFiveYears
    case overFiveYears

    /// The band's lower bound, which is what `UserProfile` records.
    ///
    /// A lower bound rather than a midpoint, because it is the only number in
    /// the band that is *true*: someone who answered "1-2 years" has been an
    /// amputee for at least twelve months, and storing eighteen would be the app
    /// inventing a precision the question deliberately did not ask for.
    ///
    /// The bounds are distinct, so `init(lowerBoundMonths:)` recovers the band
    /// the user actually picked. The mapping loses nothing.
    var lowerBoundMonths: Int {
        switch self {
        case .underSixMonths: 0
        case .sixToTwelveMonths: 6
        case .oneToTwoYears: 12
        case .threeToFiveYears: 36
        case .overFiveYears: 60
        }
    }

    /// The band a stored month count came from, or nil if it came from
    /// somewhere else — a restored export written before the bands existed, say.
    init?(lowerBoundMonths months: Int) {
        guard let band = Self.allCases.first(where: { $0.lowerBoundMonths == months }) else {
            return nil
        }
        self = band
    }
}

/// The prosthesis answers the onboarding screen offers
/// (docs/design/screens).
///
/// A closed list, because the design draws one. `UserProfile.prosthesisType`
/// stays a free-form `String?` — it has to, for restores of profiles written
/// before this list existed — so this is stored by `rawValue` rather than by
/// its label. A label is display text that may be reworded; a raw value is
/// data, and rewording the screen must not silently rewrite what people
/// answered.
enum ProsthesisType: String, Sendable, CaseIterable, Codable {
    case everydayWalking
    case activityOrSports
    case microprocessorKnee
    case preferNotToSay
    case other
}

/// The single user profile (docs/05 §5.1).
///
/// Created at onboarding completion and immutable in v1. `disclaimerAcceptedAt`
/// is non-optional because the disclaimer is a hard gate before Home [PRD §7] —
/// a profile cannot exist without it. The in-progress wizard uses
/// `OnboardingDraft` (docs/05 §5.3), not this type.
struct UserProfile: Sendable, Equatable, Identifiable {
    enum ValidationError: Error, Equatable {
        /// A bilateral amputation must record `both` [PRD AC; consistency rule REC].
        case bilateralRequiresBothSides(actual: AmputationSide)
        /// A unilateral amputation must record a single side.
        case unilateralRequiresASingleSide(level: AmputationLevel)
        /// Months since amputation cannot be negative.
        case negativeTimeSinceAmputation(months: Int)
    }

    let id: UUID
    let amputationLevel: AmputationLevel
    let side: AmputationSide
    /// Months since amputation [REC].
    ///
    /// [OPEN] The *input format* is unresolved (docs/05 §5.1) — whether the
    /// wizard collects a date, a year, or a duration is a product decision.
    /// Months is the storage unit regardless.
    let timeSinceAmputationMonths: Int
    /// Optional free text [PRD AC].
    let prosthesisType: String?
    /// Optional [PRD AC].
    let kLevel: KLevel?
    /// Hard gate before Home [PRD §7].
    let disclaimerAcceptedAt: Date
    let createdAt: Date

    init(
        id: UUID,
        amputationLevel: AmputationLevel,
        side: AmputationSide,
        timeSinceAmputationMonths: Int,
        prosthesisType: String? = nil,
        kLevel: KLevel? = nil,
        disclaimerAcceptedAt: Date,
        createdAt: Date
    ) throws {
        switch (amputationLevel, side) {
        case (.bilateral, .both):
            break
        case (.bilateral, let actual):
            throw ValidationError.bilateralRequiresBothSides(actual: actual)
        case (let level, .both):
            throw ValidationError.unilateralRequiresASingleSide(level: level)
        default:
            break
        }

        guard timeSinceAmputationMonths >= 0 else {
            throw ValidationError.negativeTimeSinceAmputation(months: timeSinceAmputationMonths)
        }

        self.id = id
        self.amputationLevel = amputationLevel
        self.side = side
        self.timeSinceAmputationMonths = timeSinceAmputationMonths
        self.prosthesisType = prosthesisType
        self.kLevel = kLevel
        self.disclaimerAcceptedAt = disclaimerAcceptedAt
        self.createdAt = createdAt
    }

    /// Whether the hard gate before Home has actually been passed [PRD §7].
    ///
    /// The type already says a profile cannot exist without an acceptance date,
    /// and onboarding always writes a real one. This exists for the one way that
    /// can be untrue in practice: `UserProfileEntity` declares a SwiftData
    /// default of `.distantPast`, so a row written outside the wizard — a future
    /// migration, a hand-edited store, a restore of a malformed archive — can
    /// carry the sentinel and still map to a valid profile. Routing straight to
    /// Home on such a profile would walk the user past the disclaimer, which is
    /// the one thing [PRD §7] forbids.
    var hasAcceptedDisclaimer: Bool { disclaimerAcceptedAt > .distantPast }

    /// Whether step-time asymmetry may be reported for this user.
    ///
    /// Bilateral users never get a fabricated asymmetry value [PRD §7, OQ-1].
    /// A true result is necessary but not sufficient — the pipeline still has to
    /// identify the side reliably in the signal [method OPEN, docs/08 §8.2].
    var supportsStepTimeAsymmetry: Bool { amputationLevel.isUnilateral }
}
