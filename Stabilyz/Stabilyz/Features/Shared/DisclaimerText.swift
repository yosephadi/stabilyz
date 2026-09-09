import Foundation

/// The "not a medical device" disclaimer, in one place [PRD §7 AC].
///
/// Onboarding presents it with the required checkbox; Settings/About shows the
/// same words afterwards without the checkbox, because the acceptance is asked
/// for exactly once. Two copies of this text would drift, and the copy the user
/// agreed to would stop being the copy they can go back and read.
///
/// **PROVISIONAL copy.** The wording is plain-language and deliberately
/// non-diagnostic, but this is the app's one legal-adjacent statement and is
/// the kind of text that normally gets reviewed before release. Nothing about
/// its structure changes if the words do.
enum DisclaimerText {
    static let title = "Before you start"

    /// Read on the final onboarding screen and again from Settings.
    static let body = """
        Stabilyz is not a medical device. It doesn't diagnose anything, it \
        doesn't treat anything, and it can't tell you whether your walking is \
        healthy or safe.

        What it does is measure how steadily you walk during a session, and \
        compare that with your own earlier sessions. Every number it shows you \
        is relative to your own baseline — never to anyone else, and never to a \
        clinical standard.

        It isn't a substitute for advice from your prosthetist, physiotherapist \
        or doctor. If something feels wrong when you walk, talk to them — don't \
        wait for a score to change.
        """

    /// The required tick [PRD §7 AC].
    static let acknowledgement = "I understand that Stabilyz is not a medical device."

    /// Shown while the box is unticked, so the disabled button explains itself
    /// rather than failing silently [PRD §6].
    static let blockedExplanation = """
        You'll be able to continue once the box above is ticked. This one is \
        required — there's no way past it — because everything Stabilyz shows \
        you depends on understanding what it is and isn't.
        """
}
