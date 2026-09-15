import Foundation
import Testing
@testable import Stabilyz

/// User-facing failure copy across surfaces (Task 11.1.2): `ErrorPresenter`,
/// Export My Data and Restore your data, against [PRD §6, §7], docs/15 §15.1
/// and the strings docs/13 quotes.

private let importOutcomes: [StabilyzError] = [
    .archiveImport(.wrongPassphrase), .archiveImport(.corruptedArchive),
    .archiveImport(.notAStabilyzArchive), .archiveImport(.unreadableFile),
    .archiveImport(.restoreFailed), .archiveImport(.restoreIncomplete),
    .schemaCompatibility(.futureSchema(version: 9)),
    .schemaCompatibility(.unsupportedEnvelope(version: 9)),
    .schemaCompatibility(.unsupportedIterationCount(count: 9_000_000)),
    .crypto(.tagVerificationFailed), .crypto(.randomGenerationFailed)
]

private let inspectionOutcomes: [ArchiveInspectionError] = [
    .unreadableFile, .notAStabilyzArchive, .invalidArchiveFormat, .wrongPassphrase,
    .unsupportedSchemaVersion(9), .unsupportedEnvelopeVersion(9), .unsupportedIterationCount(9_000_000)
]

// MARK: - Export (docs/15 §15.1)

@MainActor
@Test func everyExportFailureSaysTheDocumentedSentence() throws {
    let documented = "Export didn't complete — nothing was changed."
    for export in [StabilyzError.Export.keyDerivationFailed, .fileWriteFailed, .shareFailed, .archiveGenerationFailed] {
        let presentation = try #require(ErrorPresenter.presentation(for: .export(export)))
        #expect(presentation.message == documented, "export.\(export)")
        #expect(presentation.reassuresDataUnchanged)
        #expect(presentation.isRecoverable)
    }
    // The flow's own fallback is the same sentence, not a second wording.
    #expect(ExportFlowModel.fallbackFailureMessage == documented)
}

// MARK: - Import (PRD §6, §7 AC; docs/15 §15.1)

@Test func everyImportOutcomeThatLeavesTheDataUntouchedSaysSoAndTheOneThatMayNotNeverDoes() throws {
    for error in importOutcomes {
        let presentation = try #require(ErrorPresenter.presentation(for: error))
        let mayHaveChanged = error == .archiveImport(.restoreIncomplete)

        #expect(presentation.reassuresDataUnchanged == !mayHaveChanged, "\(error.technicalDescription)")
        #expect(
            presentation.message.contains("hasn't changed") == !mayHaveChanged,
            "\(error.technicalDescription): \(presentation.message)"
        )
    }
}

@Test func aWrongPassphraseReadsDifferentlyFromADamagedFileOnEverySurface() throws {
    // [PRD §6]: "distinguishing 'wrong passphrase' from 'corrupted file' where possible".
    let wrong = try #require(ErrorPresenter.presentation(for: .archiveImport(.wrongPassphrase)))
    let damaged = try #require(ErrorPresenter.presentation(for: .archiveImport(.corruptedArchive)))
    #expect(wrong.message != damaged.message)

    let screenWrong = RestoreDataViewModel.Problem(inspection: ArchiveInspectionError.wrongPassphrase)
    let screenDamaged = RestoreDataViewModel.Problem(inspection: ArchiveInspectionError.invalidArchiveFormat)
    #expect(screenWrong.title != screenDamaged.title)
    #expect(screenWrong.body != screenDamaged.body)
}

@Test func theRestoreScreenNeverClaimsUnchangedDataWhereErrorPresenterWouldNot() throws {
    for error in importOutcomes {
        let presentation = try #require(ErrorPresenter.presentation(for: error))
        let problem = RestoreDataViewModel.Problem(restore: error)
        if problem.body.contains("not been changed") {
            #expect(presentation.reassuresDataUnchanged, "the screen reassures for \(error.technicalDescription) and the taxonomy does not")
        }
    }
}

@Test func everyInspectionFailureOnTheRestoreScreenIsPlainAndNamesItsFile() {
    for error in inspectionOutcomes {
        let problem = RestoreDataViewModel.Problem(inspection: error)

        #expect(problem.title.isEmpty == false && problem.body.isEmpty == false)
        // Inspection never touches the store, so every body that talks about
        // the data may only say it is unchanged. "Not a Stabilyz backup" asks
        // for another file instead (Task 10.3.2 copy).
        if problem != .notAStabilyzBackup {
            #expect(problem.body.hasSuffix("Your data has not been changed."), "\(error)")
        }
        for term in ["error", "decrypt", "schema", "envelope", "PBKDF2", "iteration", "GCM", "key"] {
            #expect(
                (problem.title + " " + problem.body).localizedCaseInsensitiveContains(term) == false,
                "\(error) shows the technical term '\(term)'"
            )
        }
    }
}

// MARK: - The strings docs/13 quotes

@Test func theIterationCeilingAndUnreadableFileCopyMatchDocs13Verbatim() throws {
    let ceiling = try #require(ErrorPresenter.presentation(for: .schemaCompatibility(.unsupportedIterationCount(count: 9_000_000))))
    #expect(
        ceiling.message
            == "This backup uses security settings this version of Stabilyz can't open. Update the app, then try restoring again. Your existing data hasn't changed."
    )

    let unreadable = try #require(ErrorPresenter.presentation(for: .archiveImport(.unreadableFile)))
    #expect(
        unreadable.message
            == "That file couldn't be opened. Choose it again, or pick a different backup. Your existing data hasn't changed."
    )
}

// MARK: - Recording (PRD §7 AC: priming failure is plain-language)

@Test func aSensorFailureDuringTheCountdownIsPlainAndRetryable() throws {
    for sensor in [StabilyzError.Sensor.unavailable, .primingTimeout, .midSessionFailure] {
        let presentation = try #require(ErrorPresenter.presentation(for: .sensor(sensor)))
        #expect(presentation.isRecoverable)
        #expect(presentation.message.localizedCaseInsensitiveContains("timeout") == false)
        #expect(presentation.message.localizedCaseInsensitiveContains("priming") == false)
    }
}
