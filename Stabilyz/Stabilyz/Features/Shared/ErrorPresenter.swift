/// What the user is shown for a failure (docs/15 §15.1).
struct ErrorPresentation: Sendable, Equatable {
    /// Plain-language, action-oriented, calm. Never technical [PRD §6].
    let message: String
    /// Whether retrying is worth offering.
    let isRecoverable: Bool
    /// Whether to offer a link to Settings (permission cases only).
    let offersSettingsLink: Bool
    /// Whether to state explicitly that nothing was changed — required wherever
    /// the PRD guarantees the existing data is untouched.
    let reassuresDataUnchanged: Bool

    init(
        message: String,
        isRecoverable: Bool,
        offersSettingsLink: Bool = false,
        reassuresDataUnchanged: Bool = false
    ) {
        self.message = message
        self.isRecoverable = isRecoverable
        self.offersSettingsLink = offersSettingsLink
        self.reassuresDataUnchanged = reassuresDataUnchanged
    }
}

/// The single mapper from `StabilyzError` to user-facing copy
/// (docs/15 §15.1, §15.2).
///
/// Returning nil means **show nothing**: audio failures degrade silently and
/// must never interrupt a session [PRD §6, docs/10 §10.4].
enum ErrorPresenter {
    static func presentation(for error: StabilyzError) -> ErrorPresentation? {
        switch error {
        case .permission(.motionDenied):
            ErrorPresentation(
                message: "Stabilyz needs Motion & Fitness access to measure your walk. You can turn it on in Settings.",
                isRecoverable: true,
                offersSettingsLink: true
            )
        case .permission(.motionRestricted):
            ErrorPresentation(
                message: "Motion & Fitness access isn't available on this device, so sessions can't be recorded.",
                isRecoverable: false
            )

        case .sensor:
            ErrorPresentation(
                message: "Couldn't record that session — please try again.",
                isRecoverable: true,
                reassuresDataUnchanged: true
            )

        case .recording(.alreadyRecording):
            ErrorPresentation(
                message: "A session is already running.",
                isRecoverable: true
            )
        case .recording(.notRecording):
            ErrorPresentation(
                message: "There's no session running to stop.",
                isRecoverable: true
            )
        case .recording(.notPrimed):
            ErrorPresentation(
                message: "Couldn't start that session — please try again.",
                isRecoverable: true,
                reassuresDataUnchanged: true
            )

        case .recording(.unrecoverableInterruption):
            ErrorPresentation(
                message: "That session was interrupted, so there wasn't enough clean walking to measure. Try again when you can walk without stopping.",
                isRecoverable: true
            )

        case .processing(.noWalkingDetected):
            ErrorPresentation(
                message: "We couldn't find enough walking in that session to measure. Try again on a flat, clear stretch.",
                isRecoverable: true
            )
        case .processing(.insufficientValidWalking):
            ErrorPresentation(
                message: "There wasn't quite enough steady walking in that session to give you a result. Give it another go when you have time to keep walking.",
                isRecoverable: true
            )
        case .processing(.tooFewStrides):
            ErrorPresentation(
                message: "That session was a little too short to measure reliably. Try walking for the full time.",
                isRecoverable: true
            )
        case .processing(.excessiveNoise):
            ErrorPresentation(
                message: "The movement data from that session was too unsettled to measure. Try keeping your phone in the same place for the whole walk.",
                isRecoverable: true
            )
        case .processing(.baselineModeMismatch):
            ErrorPresentation(
                message: "Something went wrong working out that result. Please try again.",
                isRecoverable: true
            )
        case .processing(.cancelled):
            ErrorPresentation(
                message: "That session was stopped before it finished, so there's no result to show.",
                isRecoverable: true
            )

        case .persistence:
            ErrorPresentation(
                message: "Something went wrong saving that. Please try again.",
                isRecoverable: true
            )

        case .export:
            ErrorPresentation(
                message: "Export didn't complete — nothing was changed.",
                isRecoverable: true,
                reassuresDataUnchanged: true
            )

        case .archiveImport(.wrongPassphrase):
            ErrorPresentation(
                message: "That passphrase didn't match this backup. Your existing data hasn't changed.",
                isRecoverable: true,
                reassuresDataUnchanged: true
            )
        case .archiveImport(.corruptedArchive):
            ErrorPresentation(
                message: "This backup file appears to be damaged and can't be restored. Your existing data hasn't changed.",
                isRecoverable: false,
                reassuresDataUnchanged: true
            )
        case .archiveImport(.notAStabilyzArchive):
            ErrorPresentation(
                message: "That file isn't a Stabilyz backup. Your existing data hasn't changed.",
                isRecoverable: true,
                reassuresDataUnchanged: true
            )
        case .archiveImport(.unreadableFile):
            ErrorPresentation(
                message: "That file couldn't be opened. Choose it again, or pick a different backup. Your existing data hasn't changed.",
                isRecoverable: true,
                reassuresDataUnchanged: true
            )

        case .schemaCompatibility(.futureSchema):
            ErrorPresentation(
                message: "This backup was made with a newer version of Stabilyz. Update the app, then try restoring again. Your existing data hasn't changed.",
                isRecoverable: true,
                reassuresDataUnchanged: true
            )
        case .schemaCompatibility(.unsupportedEnvelope):
            ErrorPresentation(
                message: "This backup format isn't supported by this version of Stabilyz. Your existing data hasn't changed.",
                isRecoverable: false,
                reassuresDataUnchanged: true
            )
        case .schemaCompatibility(.unsupportedIterationCount):
            // Most likely a backup from a newer Stabilyz that raised the
            // ceiling, so the actionable answer is the same as a newer schema.
            ErrorPresentation(
                message: "This backup uses security settings this version of Stabilyz can't open. Update the app, then try restoring again. Your existing data hasn't changed.",
                isRecoverable: true,
                reassuresDataUnchanged: true
            )

        case .crypto:
            // Surfaced through the import/export messages above; a bare crypto
            // failure reaching the user reads as an import problem.
            ErrorPresentation(
                message: "This backup file appears to be damaged and can't be restored. Your existing data hasn't changed.",
                isRecoverable: false,
                reassuresDataUnchanged: true
            )

        case .audio:
            // Silent degradation: audio can never fail a session [PRD §6].
            nil
        }
    }
}
