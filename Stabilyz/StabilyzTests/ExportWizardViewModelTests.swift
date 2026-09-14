import Foundation
import Testing
@testable import Stabilyz

/// The export wizard (Task 10.2.1, docs/04 §4.16, docs/13 §13.2–13.3).

// MARK: - Doubles

/// Reports a fixed calibration and derives nothing.
private struct CalibratingKeyDerivation: KeyDerivation {
    let calibration: Int

    func deriveKey(passphrase: [UInt8], salt: [UInt8], iterations: Int, keyByteCount: Int) throws -> [UInt8] {
        Issue.record("the wizard must never derive a key")
        return []
    }

    func calibratedIterationCount(targetDuration: TimeInterval) -> Int { calibration }
}

/// Records what the wizard handed outward. Only ever touched from main-actor
/// test code and the wizard's main-actor callbacks; not itself isolated, so it
/// can be a default argument.
private final class Handoff {
    var requests: [ExportRequest] = []
    var cancels = 0
}

@MainActor
private func makeWizard(calibration: Int = 1_200_000, handoff: Handoff = Handoff()) -> ExportWizardViewModel {
    ExportWizardViewModel(
        keyDerivation: CalibratingKeyDerivation(calibration: calibration),
        onCreate: { handoff.requests.append($0) },
        onCancel: { handoff.cancels += 1 }
    )
}

/// A wizard with a valid passphrase entered, on the warning step.
@MainActor
private func atWarning(calibration: Int = 1_200_000, handoff: Handoff = Handoff()) -> ExportWizardViewModel {
    let wizard = makeWizard(calibration: calibration, handoff: handoff)
    wizard.passphrase = "correct horse"
    wizard.confirmation = "correct horse"
    wizard.continueToWarning()
    return wizard
}

// MARK: - Length

@Test func sevenCharactersAreRejectedAndEightAccepted() {
    #expect(PassphrasePolicy.strengthIssue(for: "1234567") == .tooShort(minimum: 8))
    #expect(PassphrasePolicy.strengthIssue(for: "12345678") == nil)
    #expect(PassphrasePolicy.strengthIssue(for: "a much longer passphrase") == nil)
}

@Test func edgeWhitespaceDoesNotCountTowardTheLength() {
    #expect(PassphrasePolicy.strengthIssue(for: "  1234567  ") == .tooShort(minimum: 8))
    #expect(PassphrasePolicy.strengthIssue(for: "\t12345678\n") == nil)
    // Inside, a space is a character like any other.
    #expect(PassphrasePolicy.strengthIssue(for: "abc defg") == nil)
}

@Test func emptyAndWhitespaceOnlyPassphrasesAreRefused() {
    for blank in ["", " ", "          ", "\n\t  \n"] {
        #expect(PassphrasePolicy.strengthIssue(for: blank) == .empty, "\(blank.debugDescription)")
    }
}

@Test func lengthIsCountedInCharactersAsAPersonSeesThem() {
    // One family emoji (seven code points) plus seven letters is eight
    // characters.
    #expect(PassphrasePolicy.strengthIssue(for: "👨‍👩‍👧‍👦abcdefg") == nil)
    #expect(PassphrasePolicy.strengthIssue(for: "👨‍👩‍👧‍👦abcdef") == .tooShort(minimum: 8))
}

// MARK: - Confirmation

@Test func aConfirmationThatDiffersIsAMismatch() {
    #expect(PassphrasePolicy.confirmationIssue(passphrase: "correct horse", confirmation: "correct hose") == .mismatch)
    #expect(PassphrasePolicy.confirmationIssue(passphrase: "correct horse", confirmation: "correct horses") == .mismatch)
    #expect(PassphrasePolicy.accepts(passphrase: "correct horse", confirmation: "Correct horse") == false)
}

@Test func aConfirmationStillBeingTypedIsNotAMismatch() {
    for partial in ["", "c", "correct", "correct hors"] {
        #expect(PassphrasePolicy.confirmationIssue(passphrase: "correct horse", confirmation: partial) == nil)
    }
    #expect(PassphrasePolicy.accepts(passphrase: "correct horse", confirmation: "correct hors") == false)
}

@Test func anEdgeSpaceIsNotAMismatchBecauseItIsNotPartOfTheKey() {
    #expect(PassphrasePolicy.accepts(passphrase: "correct horse", confirmation: "correct horse "))
    #expect(PassphraseEncoding.bytes(from: " correct horse ") == PassphraseEncoding.bytes(from: "correct horse"))
    // Inner spaces are kept.
    #expect(PassphraseEncoding.bytes(from: "correct  horse") != PassphraseEncoding.bytes(from: "correct horse"))
}

@MainActor @Test func aMismatchIsShownAsSoonAsItCannotBecomeAMatch() {
    let wizard = makeWizard()
    wizard.passphrase = "correct horse"

    wizard.confirmation = "correct"
    #expect(wizard.confirmationMessage == nil)

    wizard.confirmation = "correct hose"
    #expect(wizard.confirmationMessage == "These passphrases don't match.")
}

// MARK: - Continue

@MainActor @Test func continueIsRefusedUntilBothRulesPass() {
    let wizard = makeWizard()

    wizard.passphrase = "short"
    wizard.confirmation = "short"
    #expect(wizard.canContinue == false)
    wizard.continueToWarning()
    #expect(wizard.step == .passphrase)
    #expect(wizard.passphraseMessageIsProblem)
    #expect(wizard.passphraseMessage == "Use at least 8 characters.")

    wizard.passphrase = "correct horse"
    wizard.confirmation = "correct hors"
    #expect(wizard.canContinue == false)
    wizard.continueToWarning()
    #expect(wizard.step == .passphrase)
    // Stopped short of the passphrase: only a failed Continue calls it out.
    #expect(wizard.confirmationMessage == "These passphrases don't match.")

    wizard.confirmation = "correct horse"
    #expect(wizard.canContinue)
    wizard.continueToWarning()
    #expect(wizard.step == .warning)
}

@MainActor @Test func theLengthRuleIsNeutralUntilContinueIsTried() {
    let wizard = makeWizard()
    wizard.passphrase = "abc"
    #expect(wizard.passphraseMessage == "At least 8 characters. Spaces at the start or end are ignored.")
    #expect(wizard.passphraseMessageIsProblem == false)
}

// MARK: - The warning

@MainActor @Test func theWarningSaysWhatThePRDRequires() {
    #expect(ExportWizardViewModel.warningMessage
        == "This backup cannot be recovered if you forget your passphrase. Stabilyz does not store your passphrase.")
}

@MainActor @Test func aBackupCannotBeCreatedWithoutAcknowledgingTheWarning() async {
    let handoff = Handoff()
    let wizard = atWarning(handoff: handoff)

    #expect(wizard.hasAcknowledgedWarning == false)
    #expect(wizard.canCreateBackup == false)
    await wizard.createBackup()
    #expect(wizard.step == .warning)
    #expect(handoff.requests.isEmpty)

    wizard.hasAcknowledgedWarning = true
    #expect(wizard.canCreateBackup)
    await wizard.createBackup()
    #expect(wizard.step == .handedOff)
    #expect(handoff.requests.count == 1)
}

@MainActor @Test func goingBackClearsTheAcknowledgement() {
    let wizard = atWarning()
    wizard.hasAcknowledgedWarning = true

    wizard.backToPassphrase()
    #expect(wizard.step == .passphrase)
    #expect(wizard.hasAcknowledgedWarning == false)
    // What was typed is still there to correct.
    #expect(wizard.passphrase == "correct horse")

    wizard.continueToWarning()
    #expect(wizard.canCreateBackup == false)
}

@MainActor @Test func theWarningCannotBeSkippedFromTheFirstStep() async {
    let handoff = Handoff()
    let wizard = makeWizard(handoff: handoff)
    wizard.passphrase = "correct horse"
    wizard.confirmation = "correct horse"
    wizard.hasAcknowledgedWarning = true

    await wizard.createBackup()
    #expect(wizard.step == .passphrase)
    #expect(handoff.requests.isEmpty)
}

// MARK: - Calibration and hand-off

@MainActor @Test func theCalibratedCountIsClampedAtFiveMillion() async {
    let handoff = Handoff()
    let wizard = atWarning(calibration: 9_000_000, handoff: handoff)
    wizard.hasAcknowledgedWarning = true

    await wizard.createBackup()
    #expect(handoff.requests.first?.iterations == 5_000_000)
}

@MainActor @Test func aCalibrationInsideTheRangeIsUsedAsIs() async {
    let handoff = Handoff()
    let wizard = atWarning(calibration: 1_234_567, handoff: handoff)
    wizard.hasAcknowledgedWarning = true

    await wizard.createBackup()
    #expect(handoff.requests.first?.iterations == 1_234_567)
}

@Test func theExportCountNeverLeavesTheFloorToCeilingRange() {
    #expect(ArchiveFormat.exportIterations(calibrated: 9_000_000) == 5_000_000)
    #expect(ArchiveFormat.exportIterations(calibrated: 5_000_000) == 5_000_000)
    #expect(ArchiveFormat.exportIterations(calibrated: 1_000_000) == 1_000_000)
    #expect(ArchiveFormat.exportIterations(calibrated: 1_000) == KeyDerivationPolicy.minimumIterations)
}

@MainActor @Test func theHandOffCarriesTheCanonicalBytesAndClearsWhatWasTyped() async {
    let handoff = Handoff()
    let wizard = makeWizard(handoff: handoff)
    wizard.passphrase = "  correct horse  "
    wizard.confirmation = "correct horse"
    wizard.continueToWarning()
    wizard.isPassphraseVisible = true
    wizard.hasAcknowledgedWarning = true

    await wizard.createBackup()

    #expect(handoff.requests.first?.passphrase == Array("correct horse".utf8))
    #expect(wizard.passphrase.isEmpty)
    #expect(wizard.confirmation.isEmpty)
    #expect(wizard.isPassphraseVisible == false)
}

@MainActor @Test func aHandedOffRequestOpensAnArchiveWithTheSamePassphrase() async throws {
    // The wizard's bytes and restore's bytes must be the same bytes.
    let handoff = Handoff()
    let wizard = atWarning(handoff: handoff)
    wizard.hasAcknowledgedWarning = true
    await wizard.createBackup()
    let request = try #require(handoff.requests.first)

    let coder = SecureArchiveCoder(minimumEncodeIterations: 1)
    let payload = ArchivePayload(
        profile: .fixture(), baselines: [], sessions: [],
        appVersion: "1.0 (7)", algorithmVersion: "1.0.0", exportedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let archive = try await coder.encode(payload, passphrase: request.passphrase, iterations: 1_000)
    let decoded = try await coder.decode(archiveData: archive, passphrase: PassphraseEncoding.bytes(from: "correct horse "))
    #expect(decoded.payload == payload)
}

@MainActor @Test func cancellingClearsWhatWasTypedAndHandsNothingOff() {
    let handoff = Handoff()
    let wizard = atWarning(handoff: handoff)
    wizard.hasAcknowledgedWarning = true

    wizard.cancel()

    #expect(handoff.cancels == 1)
    #expect(handoff.requests.isEmpty)
    #expect(wizard.passphrase.isEmpty)
    #expect(wizard.confirmation.isEmpty)
    #expect(wizard.hasAcknowledgedWarning == false)
}

@MainActor @Test func discardingOnDismissClearsSecretsWithoutReportingACancel() {
    let handoff = Handoff()
    let wizard = makeWizard(handoff: handoff)
    wizard.passphrase = "correct horse"
    wizard.confirmation = "correct horse"
    wizard.isPassphraseVisible = true

    wizard.discardSecrets()

    #expect(wizard.passphrase.isEmpty)
    #expect(wizard.confirmation.isEmpty)
    #expect(wizard.isPassphraseVisible == false)
    #expect(handoff.cancels == 0)
}
