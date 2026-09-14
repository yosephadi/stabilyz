import Foundation
import Testing
@testable import Stabilyz

/// Every error the taxonomy can produce, so the copy audit below is exhaustive.
private let allErrors: [StabilyzError] = [
    .permission(.motionDenied), .permission(.motionRestricted),
    .sensor(.unavailable), .sensor(.primingTimeout), .sensor(.midSessionFailure),
    .recording(.unrecoverableInterruption),
    .processing(.noWalkingDetected), .processing(.insufficientValidWalking),
    .processing(.tooFewStrides), .processing(.excessiveNoise), .processing(.cancelled),
    .persistence(.saveFailed), .persistence(.storeCorruption),
    .export(.keyDerivationFailed), .export(.fileWriteFailed), .export(.shareFailed),
    .export(.archiveGenerationFailed),
    .archiveImport(.wrongPassphrase), .archiveImport(.corruptedArchive),
    .archiveImport(.notAStabilyzArchive), .archiveImport(.unreadableFile),
    .archiveImport(.restoreFailed), .archiveImport(.restoreIncomplete),
    .schemaCompatibility(.futureSchema(version: 9)),
    .schemaCompatibility(.unsupportedEnvelope(version: 9)),
    .schemaCompatibility(.unsupportedIterationCount(count: 9_000_000)),
    .audio(.routeLost), .audio(.interrupted), .audio(.engineFailure),
    .crypto(.tagVerificationFailed), .crypto(.randomGenerationFailed)
]

// MARK: - Copy audit (docs/15 §15.2)

@Test func everyUserVisibleErrorHasPlainLanguageCopy() {
    let technicalTerms = [
        "nil", "error", "exception", "failed to", "throw", "AES", "GCM", "PBKDF2",
        "schema", "decrypt", "actor", "nonce", "salt", "tag", "buffer", "stream",
        "autocorrelation", "asymmetry", "z-score", "SD"
    ]

    for error in allErrors {
        guard let presentation = ErrorPresenter.presentation(for: error) else { continue }

        #expect(presentation.message.isEmpty == false)
        // Technical detail is logged, never shown [PRD rule].
        for term in technicalTerms {
            #expect(
                presentation.message.localizedCaseInsensitiveContains(term) == false,
                "\(error.technicalDescription) surfaces the technical term '\(term)'"
            )
        }
    }
}

@Test func audioFailuresShowNothingAtAll() {
    // [PRD §6, docs/10 §10.4] audio degrades silently and never fails a session.
    for audio in [StabilyzError.Audio.routeLost, .interrupted, .engineFailure] {
        #expect(ErrorPresenter.presentation(for: .audio(audio)) == nil)
    }
}

@Test func everyNonAudioErrorIsPresentable() {
    for error in allErrors {
        if case .audio = error { continue }
        #expect(ErrorPresenter.presentation(for: error) != nil, "\(error.technicalDescription) has no copy")
    }
}

// MARK: - PRD guarantees carried into the copy

@Test func failuresWithAnUntouchedDataGuaranteeSayNothingChanged() {
    // docs/15 §15.1: import, schema and export paths all guarantee the existing
    // store is untouched, and [PRD] requires the user be told so.
    let guaranteed: [StabilyzError] = [
        .archiveImport(.wrongPassphrase), .archiveImport(.corruptedArchive),
        .archiveImport(.notAStabilyzArchive), .archiveImport(.unreadableFile),
        .archiveImport(.restoreFailed),
        .schemaCompatibility(.futureSchema(version: 9)),
        .schemaCompatibility(.unsupportedEnvelope(version: 9)),
        .schemaCompatibility(.unsupportedIterationCount(count: 9_000_000)),
        .export(.fileWriteFailed),
        .export(.archiveGenerationFailed)
    ]

    for error in guaranteed {
        let presentation = ErrorPresenter.presentation(for: error)
        #expect(presentation?.reassuresDataUnchanged == true, "\(error.technicalDescription)")
        #expect(presentation?.message.localizedCaseInsensitiveContains("hasn't changed") == true
            || presentation?.message.localizedCaseInsensitiveContains("nothing was changed") == true)
    }
}

@Test func wrongPassphraseIsDistinctFromCorruptedFile() {
    // [PRD] requires distinguishing these where possible; the key-check value
    // is what makes it possible (docs/13 §13.4).
    let wrong = ErrorPresenter.presentation(for: .archiveImport(.wrongPassphrase))
    let corrupted = ErrorPresenter.presentation(for: .archiveImport(.corruptedArchive))

    #expect(wrong?.message != corrupted?.message)
    #expect(wrong?.isRecoverable == true)
    #expect(corrupted?.isRecoverable == false)
}

@Test func onlyPermissionErrorsOfferASettingsLink() {
    for error in allErrors {
        guard let presentation = ErrorPresenter.presentation(for: error) else { continue }
        if case .permission(.motionDenied) = error {
            #expect(presentation.offersSettingsLink)
        } else {
            #expect(presentation.offersSettingsLink == false, "\(error.technicalDescription)")
        }
    }
}

// MARK: - Logging

@Test func errorsCarryALogCategoryAndTechnicalDescription() {
    #expect(StabilyzError.processing(.excessiveNoise).logCategory == .processing)
    #expect(StabilyzError.persistence(.saveFailed).logCategory == .persistence)
    #expect(StabilyzError.audio(.routeLost).logCategory == .audio)
    #expect(StabilyzError.archiveImport(.wrongPassphrase).logCategory == .backup)

    // Technical descriptions are for the log and carry no secrets (docs/20).
    #expect(StabilyzError.archiveImport(.wrongPassphrase).technicalDescription == "import.wrongPassphrase")
    #expect(StabilyzError.sensor(.primingTimeout).technicalDescription == "sensor.primingTimeout")
}
