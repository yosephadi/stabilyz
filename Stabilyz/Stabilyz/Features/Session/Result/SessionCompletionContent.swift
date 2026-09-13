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
    case unclear(mode: TestMode)

    static func content(for result: SessionCommitResult) -> SessionCompletionContent {
        let mode = result.session.mode
        return result.session.isValid ? .measured(mode: mode) : .unclear(mode: mode)
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

    /// Plain language, and for the unclear case plain about the consequence:
    /// [PRD §5] requires the user be told the session does not count, not left
    /// to infer it from a missing number.
    var body: String {
        switch self {
        case .measured:
            "Your walking stability has been analyzed. Results are ready to view."
        case .unclear:
            """
            Excessive movement or an interruption made this walk hard to \
            measure. This session won't count toward your baseline.
            """
        }
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
