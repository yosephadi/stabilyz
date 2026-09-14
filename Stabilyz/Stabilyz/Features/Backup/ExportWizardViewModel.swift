import Foundation

/// What the wizard hands to archive generation (Task 10.2.2).
///
/// The passphrase is already in its canonical byte form — the exact bytes the
/// key is derived from — and the receiver owns them: it passes them to
/// `SecureArchiveCoder.encode` and then to `SecureBytes.zeroize`.
struct ExportRequest: Sendable, Equatable {
    let passphrase: [UInt8]
    /// This device's calibration, clamped to the archive's floor and ceiling.
    let iterations: Int
}

/// Drives the export wizard (docs/04 §4.16, docs/13 §13.2–13.3, Task 10.2.1).
///
/// Two steps, in the PRD's order: set and confirm a passphrase, then read and
/// acknowledge that a forgotten one cannot be recovered — **before** anything
/// is generated [PRD §5, §7 AC]. Generation and the share sheet are Task
/// 10.2.2's, reached through `onCreate`.
///
/// Every string the wizard shows is decided here, so the rules are testable
/// without rendering (docs/11 §11.5).
///
/// **Memory (docs/13 §13.3).** The text fields bind to `String`, which cannot
/// be zeroed — the residual risk §13.3 accepts. The model clears both strings
/// the moment they are no longer needed: on hand-off and on cancel.
@MainActor
@Observable
final class ExportWizardViewModel {
    enum Step: Equatable {
        case passphrase
        case warning
        /// Calibrating the iteration count, between tapping Create Backup and
        /// the hand-off. About `KeyDerivationPolicy.targetDuration`.
        case preparing
        case handedOff
    }

    private(set) var step: Step = .passphrase

    var passphrase = ""
    var confirmation = ""
    /// One switch for both fields: the person checking what they typed wants
    /// to see both.
    var isPassphraseVisible = false
    var hasAcknowledgedWarning = false

    /// Set by a Continue that could not proceed, so the length rule is shown as
    /// a problem only once someone has tried — not while they are typing.
    private(set) var hasAttemptedContinue = false

    var onCreate: @MainActor (ExportRequest) -> Void
    var onCancel: @MainActor () -> Void

    private let keyDerivation: KeyDerivation

    init(
        keyDerivation: KeyDerivation,
        onCreate: @escaping @MainActor (ExportRequest) -> Void = { _ in },
        onCancel: @escaping @MainActor () -> Void = {}
    ) {
        self.keyDerivation = keyDerivation
        self.onCreate = onCreate
        self.onCancel = onCancel
    }

    // MARK: - Step 1: the passphrase

    var canContinue: Bool {
        PassphrasePolicy.accepts(passphrase: passphrase, confirmation: confirmation)
    }

    func continueToWarning() {
        guard step == .passphrase else { return }
        guard canContinue else {
            hasAttemptedContinue = true
            return
        }
        hasAcknowledgedWarning = false
        step = .warning
    }

    /// The line under the passphrase field: a neutral rule until Continue has
    /// been tried, then the problem, if there is one.
    var passphraseMessage: String {
        guard hasAttemptedContinue, let issue = PassphrasePolicy.strengthIssue(for: passphrase) else {
            return Self.lengthRule
        }
        switch issue {
        case .empty, .tooShort: return Self.tooShortMessage
        case .mismatch: return Self.lengthRule
        }
    }

    var passphraseMessageIsProblem: Bool {
        hasAttemptedContinue && PassphrasePolicy.strengthIssue(for: passphrase) != nil
    }

    /// Shown as soon as the confirmation can no longer become the passphrase,
    /// and after a failed Continue if it simply stopped short.
    var confirmationMessage: String? {
        if PassphrasePolicy.confirmationIssue(passphrase: passphrase, confirmation: confirmation) != nil {
            return Self.mismatchMessage
        }
        if hasAttemptedContinue,
           PassphrasePolicy.strengthIssue(for: passphrase) == nil,
           PassphrasePolicy.canonical(passphrase) != PassphrasePolicy.canonical(confirmation) {
            return Self.mismatchMessage
        }
        return nil
    }

    // MARK: - Step 2: the warning

    var canCreateBackup: Bool {
        step == .warning && hasAcknowledgedWarning && canContinue
    }

    func backToPassphrase() {
        guard step == .warning else { return }
        // The acknowledgement was for the passphrase as it stood. Going back
        // to change it means reading the warning again.
        hasAcknowledgedWarning = false
        step = .passphrase
    }

    /// Calibrates, clamps, and hands the request to generation.
    ///
    /// Does nothing unless the warning is acknowledged: the PRD requires the
    /// warning before generation, and a button that could be reached without
    /// it would make the requirement a convention.
    func createBackup() async {
        guard canCreateBackup else { return }
        step = .preparing

        let kdf = keyDerivation
        // Calibration spends about a third of a second in PBKDF2; not on the
        // main actor (docs/14 §14.2).
        let calibrated = await Task.detached(priority: .userInitiated) {
            kdf.calibratedIterationCount(targetDuration: KeyDerivationPolicy.targetDuration)
        }.value

        let request = ExportRequest(
            passphrase: PassphraseEncoding.bytes(from: passphrase),
            iterations: ArchiveFormat.exportIterations(calibrated: calibrated)
        )
        clearSecrets()
        step = .handedOff
        onCreate(request)
    }

    func cancel() {
        clearSecrets()
        onCancel()
    }

    /// Clears what was typed without reporting a cancel — for the sheet going
    /// away by any route other than the Cancel button.
    func discardSecrets() {
        clearSecrets()
    }

    private func clearSecrets() {
        passphrase = ""
        confirmation = ""
        isPassphraseVisible = false
        hasAcknowledgedWarning = false
        hasAttemptedContinue = false
    }

    // MARK: - Copy

    static let title = "Export My Data"
    static let cancelLabel = "Cancel"

    static let passphraseTitle = "Set a Passphrase"
    static let passphraseBody =
        "Your backup is locked with this passphrase. You'll need it to restore your data on this iPhone or a new one."
    static let passphraseLabel = "Passphrase"
    static let confirmationLabel = "Confirm passphrase"
    static let lengthRule = "At least \(PassphrasePolicy.minimumLength) characters. Spaces at the start or end are ignored."
    static let tooShortMessage = "Use at least \(PassphrasePolicy.minimumLength) characters."
    static let mismatchMessage = "These passphrases don't match."
    static let showPassphraseLabel = "Show passphrase"
    static let hidePassphraseLabel = "Hide passphrase"
    static let continueLabel = "Continue"

    static let warningTitle = "Before You Continue"
    /// Verbatim from the task (Task 10.2.1) — the PRD's "clear, unambiguous
    /// warning" [PRD §7 AC].
    static let warningMessage =
        "This backup cannot be recovered if you forget your passphrase. Stabilyz does not store your passphrase."
    static let acknowledgementLabel = "I understand I can't open this backup without my passphrase."
    static let backLabel = "Back"
    static let createBackupLabel = "Create Backup"
    static let preparingLabel = "Preparing your backup…"
}
