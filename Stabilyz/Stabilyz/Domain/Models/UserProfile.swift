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
