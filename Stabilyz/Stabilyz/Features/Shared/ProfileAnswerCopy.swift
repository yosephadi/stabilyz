import Foundation

/// The words for the profile's answer lists, shared by onboarding and the
/// You tab so the two can never word the same option differently.
enum ProfileAnswerCopy {
    /// The five bands, worded as the design words them.
    static func timeLabel(_ band: TimeSinceAmputation) -> String {
        switch band {
        case .underSixMonths: "Less than 6 months"
        case .sixToTwelveMonths: "6–12 months"
        case .oneToTwoYears: "1–2 years"
        case .threeToFiveYears: "3–5 years"
        case .overFiveYears: "More than 5 years"
        }
    }

    /// The five answers, worded as the design words them.
    static func prosthesisLabel(_ type: ProsthesisType) -> String {
        switch type {
        case .everydayWalking: "Everyday walking prosthesis"
        case .activityOrSports: "Activity or sports prosthesis"
        case .microprocessorKnee: "Microprocessor-controlled knee"
        case .preferNotToSay: "Prefer not to say"
        case .other: "Other"
        }
    }

    /// K1-K4 are worded as the designs word them. K0 keeps a label without
    /// being offered: `OnboardingDraft.offeredKLevels` decides what this screen
    /// shows, and a restored profile carrying K0 still has something to render.
    static func kLevelLabel(_ level: KLevel) -> String {
        switch level {
        case .k0: "K0 — not walking at present"
        case .k1: "K1 — household walking"
        case .k2: "K2 — limited community walking"
        case .k3: "K3 — community walking"
        case .k4: "K4 — high activity"
        }
    }

    /// What an unanswered optional item reads as.
    static let notSet = "Not set"
    /// The K-level list's "none" row, as onboarding words it.
    static let kLevelUnknown = "I don't know"

    /// A stored month count as a label: the band it came from, or a plain
    /// month count for a value no band produced (a restored older export).
    static func timeLabel(months: Int?) -> String {
        guard let months else { return notSet }
        if let band = TimeSinceAmputation(lowerBoundMonths: months) { return timeLabel(band) }
        return months == 1 ? "1 month" : "\(months) months"
    }

    /// A stored prosthesis string as a label: the list's wording, or the text
    /// itself when it predates the list.
    static func prosthesisLabel(stored: String?) -> String {
        guard let stored, !stored.isEmpty else { return notSet }
        if let type = ProsthesisType(rawValue: stored) { return prosthesisLabel(type) }
        return stored
    }

    static func kLevelLabel(stored: KLevel?) -> String {
        stored.map(kLevelLabel) ?? notSet
    }
}
