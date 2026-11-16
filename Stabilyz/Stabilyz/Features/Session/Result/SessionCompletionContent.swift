import Foundation

/// What the completion gate says, and which way out it offers
/// (docs/11 §11.3, [PRD §5]).
///
/// The gate is the one screen every finished walk lands on, and it is the place
/// the valid/invalid fork is made visible: after processing the flow routes to
/// Noisy or Score, **never both, never neither**. Modelling it as a value rather
/// than as branches inside a view means that rule is a total function of the
/// committed session and can be asserted without rendering anything
/// (docs/11 §11.5).
///
/// It reads `GaitSession.isValid` and nothing else. Validity is the pipeline's
/// conclusion, already committed; a screen that re-derived it from metrics or
/// from a reason code could disagree with what was stored.
enum SessionCompletionContent: Equatable {
    /// The walk was measured. A score — or calibration progress — is waiting.
    case measured(mode: TestMode)
    /// The walk could not be measured. No score, and it counts toward nothing
    /// [PRD §5, §6, §7].
    case unclear(mode: TestMode, reason: InvalidReason)

    static func content(for result: SessionCommitResult) -> SessionCompletionContent {
        let mode = result.session.mode
        // An invalid session always carries its reason; the fallback only
        // keeps the mapping total.
        guard let reason = result.session.outcome.invalidReason else { return .measured(mode: mode) }
        return .unclear(mode: mode, reason: reason)
    }

    /// The centred glyph. SF Symbols only (§7), and both are filled circles so
    /// the two states read as the same shape carrying a different mark rather
    /// than as two unrelated screens.
    var glyph: String {
        switch self {
        case .measured: "checkmark.circle.fill"
        case .unclear: "exclamationmark.circle.fill"
        }
    }

    var title: String {
        switch self {
        case .measured(let mode): "\(mode.displayName) Completed"
        case .unclear: Self.unclearTitle
        }
    }

    /// Plain language, and for the unclear case plain about the cause, one
    /// next step, and the consequence: [PRD §5] requires the user be told the
    /// session does not count, not left to infer it from a missing number.
    var body: String { body(policy: .v1) }

    /// `policy` supplies the valid-walking floor the too-short copy quotes, so
    /// the number is the mode's own and never typed here.
    func body(policy: SessionPolicy) -> String {
        switch self {
        case .measured:
            "Your walking stability has been analyzed. Results are ready to view."
        case .unclear(let mode, let reason):
            Self.unclearCopy(
                for: reason,
                floor: policy.minimumValidWalkingDuration(for: mode)
            ) + " " + Self.doesNotCountSentence
        }
    }

    static let doesNotCountSentence = "This session won't count toward your baseline."

    /// The cause and the one next step, for each reason the pipeline can give.
    /// Never alarming, and never a pass/fail framing.
    static func unclearCopy(for reason: InvalidReason, floor: Duration) -> String {
        switch reason {
        case .insufficientValidWalking:
            "This walk was shorter than the \(spokenDuration(floor)) of walking needed. "
                + "Try walking until the timer ends."
        case .excessiveNoise:
            "Extra movement from the phone made this walk hard to measure. "
                + "Try again with the phone snug in your pocket."
        case .unrecoverableInterruption:
            "Something interrupted this walk, so it couldn't be measured. "
                + "Try again and keep the app open until the timer ends."
        case .sensorFailure:
            "The phone stopped sending motion data during this walk. "
                + "Try again, and check that Motion & Fitness is on in Settings."
        }
    }

    /// "60 seconds", "2 minutes 15 seconds", "3 minutes".
    static func spokenDuration(_ duration: Duration) -> String {
        let total = Int(duration.components.seconds)
        let minutes = total / 60
        let seconds = total % 60
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        // Under two minutes reads best in seconds: Quick's floor is "60 seconds".
        if total < 120 { return unit(total, "second") }
        if seconds == 0 { return unit(minutes, "minute") }
        return "\(unit(minutes, "minute")) \(unit(seconds, "second"))"
    }

    /// Whether arriving on this screen plays the one success haptic and the
    /// one-shot checkmark. Only a measured walk does; the unclear walk is not a
    /// success and gets neither. Both happen after Stop, never during a walk.
    var celebratesCompletion: Bool {
        switch self {
        case .measured: true
        case .unclear: false
        }
    }

    /// Whether the success haptic plays, given the user's Start & Stop Haptics
    /// setting as it stands when the screen appears. Off means no haptic.
    func playsSuccessHaptic(hapticsOn: Bool) -> Bool {
        celebratesCompletion && hapticsOn
    }

    /// Whether the screen offers the result at all.
    ///
    /// False for an unclear walk, which leaves exactly one way out. A disabled
    /// "View Result" would be a button promising a screen that does not exist.
    var offersResult: Bool {
        switch self {
        case .measured: true
        case .unclear: false
        }
    }

    static let unclearTitle = "Walk Data Unclear"
    static let viewResultLabel = "View Result"
    static let backToWalkLabel = "Back to Walk Menu"
}
