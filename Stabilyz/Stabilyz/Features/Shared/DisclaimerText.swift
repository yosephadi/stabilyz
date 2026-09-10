import Foundation

/// The "not a medical device" disclaimer, in one place [PRD §7 AC].
///
/// Onboarding presents it with the required checkbox; Settings/About shows the
/// same words afterwards without the checkbox, because the acceptance is asked
/// for exactly once. Two copies of this text would drift, and the copy the user
/// agreed to would stop being the copy they can go back and read.
///
/// **No em dashes anywhere in this file.** They are set as one long rule with
/// no surrounding space, which at 17pt reads as a hyphen joining two words to
/// anyone who is not looking closely, and VoiceOver skips them entirely. This
/// is the app's one legal-adjacent statement, so every clause break in it is a
/// comma or a full stop. `DisclaimerCopyTests` holds the file to that.
///
/// **PROVISIONAL copy.** The wording is plain-language and deliberately
/// non-diagnostic, but this is the kind of text that normally gets reviewed
/// before release. Nothing about its structure changes if the words do.
enum DisclaimerText {
    static let title = "Before You Begin"

    /// Read on the final onboarding screen and again from Settings.
    static let body = """
        Stabilyz is designed to help you track your walking stability over time.

        It is not a medical device and does not provide clinical diagnoses or \
        medical advice. Always consult your prosthetist or physical therapist \
        for clinical evaluations.

        By continuing, you acknowledge that Stabilyz is for personal \
        self-tracking only.
        """

    /// The required tick [PRD §7 AC].
    static let acknowledgement = "I understand that Stabilyz is not a medical device."

    /// Shown while the box is unticked, so the disabled button explains itself
    /// rather than failing silently [PRD §6].
    ///
    /// One sentence. The previous three-sentence version argued the case for
    /// the gate; the gate is a checkbox eight points above this line, and what
    /// the reader needs is the instruction, not the reasoning.
    static let blockedExplanation = "Check the box above to continue."
}
