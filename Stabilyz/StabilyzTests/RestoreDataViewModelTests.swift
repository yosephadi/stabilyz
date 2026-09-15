import Foundation
import Testing
@testable import Stabilyz

/// Restore your data (Task 10.3.2, Figma 64:3890, docs/13 §13.4–13.5).

// MARK: - Doubles

private struct SimulatedFailure: Error {}

/// Scripted inspection, recording what it was asked.
private final class StubInspector: ArchiveInspecting, @unchecked Sendable {
    struct State {
        var preflightErrors: [URL: Error] = [:]
        var inspectResult: Result<DecodedArchivePayload, Error> = .success(stagedBackup())
        var preflighted: [URL] = []
        var inspected: [(url: URL, passphrase: String)] = []
    }

    let state = Locked(State())

    func preflight(archiveAt url: URL) async throws {
        let error = state.withLock { (state: inout State) -> Error? in
            state.preflighted.append(url)
            return state.preflightErrors[url]
        }
        if let error { throw error }
    }

    func preflight(archiveData: Data) async throws {
        Issue.record("the screen preflights the picked file, not bytes")
    }

    func inspect(archiveAt url: URL, passphrase: String) async throws -> DecodedArchivePayload {
        let result = state.withLock { (state: inout State) -> Result<DecodedArchivePayload, Error> in
            state.inspected.append((url, passphrase))
            return state.inspectResult
        }
        return try result.get()
    }

    func inspect(archiveData: Data, passphrase: String) async throws -> DecodedArchivePayload {
        Issue.record("the screen inspects the picked file, not bytes")
        throw SimulatedFailure()
    }
}

private final class StubRestorer: ArchiveRestoring, @unchecked Sendable {
    struct State {
        var error: Error?
        var restored: [DecodedArchivePayload] = []
    }

    let state = Locked(State())
    static let receipt = RestoreReceipt(schemaVersion: 1, sessionCount: 3, baselineModes: [.quickTest])

    func restore(_ staged: DecodedArchivePayload) async throws -> RestoreReceipt {
        let error = state.withLock { (state: inout State) -> Error? in
            state.restored.append(staged)
            return state.error
        }
        if let error { throw error }
        return Self.receipt
    }
}

/// Security-scoped access as a ledger.
private final class RecordingAccess: SecurityScopedAccess, @unchecked Sendable {
    struct State {
        var grants = true
        var begun: [URL] = []
        var ended: [URL] = []
    }

    let state = Locked(State())

    func begin(_ url: URL) -> Bool {
        state.withLock { (state: inout State) -> Bool in
            state.begun.append(url)
            return state.grants
        }
    }

    func end(_ url: URL) {
        state.withLock { $0.ended.append(url) }
    }

    /// URLs begun (and granted) but not yet ended.
    var held: [URL] {
        state.withLock { (state: inout State) -> [URL] in
            var open = state.grants ? state.begun : []
            for url in state.ended {
                if let index = open.firstIndex(of: url) { open.remove(at: index) }
            }
            return open
        }
    }
}

private final class QuietLog: LogService, @unchecked Sendable {
    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {}
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

/// What the screen reported outward. Not isolated, so it can be a default
/// argument.
private final class Outcomes {
    var receipts: [RestoreReceipt] = []
    var closes = 0
}

// MARK: - Fixtures

private func stagedBackup() -> DecodedArchivePayload {
    DecodedArchivePayload(
        payload: ArchivePayload(
            profile: .fixture(),
            baselines: [],
            sessions: [],
            appVersion: "1.0 (7)",
            algorithmVersion: "1.0.0",
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ),
        schemaVersion: 1
    )
}

private let pickedURL = URL(fileURLWithPath: "/private/var/mobile/Picked/userdata-stabilyz.stabilyz")
private let otherURL = URL(fileURLWithPath: "/private/var/mobile/Picked/Stabilyz-Backup-2026-09-15-101500.stabilyz")

private struct Harness {
    let model: RestoreDataViewModel
    let inspector: StubInspector
    let restorer: StubRestorer
    let access: RecordingAccess
    let outcomes: Outcomes
}

@MainActor
private func makeHarness(withRestorer: Bool = true) -> Harness {
    let inspector = StubInspector()
    let restorer = StubRestorer()
    let access = RecordingAccess()
    let outcomes = Outcomes()
    let model = RestoreDataViewModel(
        inspector: inspector,
        restorer: withRestorer ? restorer : nil,
        fileAccess: access,
        logService: QuietLog(),
        onRestored: { outcomes.receipts.append($0) },
        onClose: { outcomes.closes += 1 }
    )
    return Harness(model: model, inspector: inspector, restorer: restorer, access: access, outcomes: outcomes)
}

// MARK: - Picking a file

@MainActor
@Test func pickingAFileTakesScopedAccessAndPreflightsIt() async {
    let harness = makeHarness()

    await harness.model.fileImported(.success(pickedURL))

    #expect(harness.model.file?.url == pickedURL)
    #expect(harness.model.file?.displayName == "userdata-stabilyz")
    #expect(harness.access.held == [pickedURL])
    #expect(harness.inspector.state.withLock { $0.preflighted } == [pickedURL])
    #expect(harness.model.phase == .idle)
    #expect(harness.model.problem == nil)
    // Nothing is inspected or restored until there is a passphrase.
    #expect(harness.inspector.state.withLock { $0.inspected.isEmpty })
    #expect(harness.restorer.state.withLock { $0.restored.isEmpty })
}

@MainActor
@Test func restoreWaitsForAPassphrase() async {
    let harness = makeHarness()
    await harness.model.select(pickedURL)

    #expect(harness.model.canRestore == false)
    harness.model.passphrase = "   "
    #expect(harness.model.canRestore == false, "edge whitespace alone is no passphrase")
    harness.model.passphrase = "correct horse"
    #expect(harness.model.canRestore)
}

@MainActor
@Test func aURLThatNeedsNoScopedAccessIsNeverEnded() async {
    let harness = makeHarness()
    harness.access.state.withLock { $0.grants = false }

    await harness.model.select(pickedURL)
    harness.model.close()

    #expect(harness.access.state.withLock { $0.begun } == [pickedURL])
    #expect(harness.access.state.withLock { $0.ended.isEmpty })
    // Still preflighted: the inspection service reads the file itself.
    #expect(harness.inspector.state.withLock { $0.preflighted } == [pickedURL])
}

@MainActor
@Test func backingOutOfThePickerChangesNothing() async {
    let harness = makeHarness()
    await harness.model.select(pickedURL)
    harness.model.passphrase = "correct horse"

    await harness.model.fileImported(.failure(CocoaError(.userCancelled)))

    #expect(harness.model.file?.url == pickedURL)
    #expect(harness.model.passphrase == "correct horse")
    #expect(harness.model.problem == nil)
    #expect(harness.access.held == [pickedURL])
    #expect(RestoreDataViewModel.isCancellation(CocoaError(.userCancelled)))
    #expect(RestoreDataViewModel.isCancellation(SimulatedFailure()) == false)
}

// MARK: - The three problems, word for word

@MainActor
@Test func aFileThatIsNotAStabilyzExportIsReportedAsSoonAsItIsPicked() async throws {
    let harness = makeHarness()
    harness.inspector.state.withLock { $0.preflightErrors[pickedURL] = ArchiveInspectionError.notAStabilyzArchive }

    await harness.model.select(pickedURL)

    let problem = try #require(harness.model.problem)
    #expect(problem == .notAStabilyzBackup)
    #expect(problem.title == "This isn't a Stabilyz backup")
    #expect(problem.body == "Choose an export created by Stabilyz, then try again.")

    // A passphrase cannot make it one.
    harness.model.passphrase = "correct horse"
    #expect(harness.model.canRestore == false)
    await harness.model.restore()
    #expect(harness.inspector.state.withLock { $0.inspected.isEmpty })
    #expect(harness.model.canChooseDifferentFile)
}

@MainActor
@Test(arguments: [
    ArchiveInspectionError.invalidArchiveFormat,
    .unreadableFile,
    .unsupportedEnvelopeVersion(9),
    .unsupportedIterationCount(9_000_000)
])
func aDamagedOrUnsupportedFileIsReportedAsSoonAsItIsPicked(_ error: ArchiveInspectionError) async throws {
    let harness = makeHarness()
    harness.inspector.state.withLock { $0.preflightErrors[pickedURL] = error }

    await harness.model.select(pickedURL)

    let problem = try #require(harness.model.problem)
    #expect(problem.title == "We couldn't use this backup")
    #expect(
        problem.body
            == "This file may be damaged or from a version of Stabilyz that isn't supported. Your data has not been changed."
    )
    harness.model.passphrase = "correct horse"
    #expect(harness.model.canRestore == false)
}

@MainActor
@Test func aWrongPassphraseIsReportedAndRestoresNothing() async throws {
    let harness = makeHarness()
    harness.inspector.state.withLock { $0.inspectResult = .failure(ArchiveInspectionError.wrongPassphrase) }
    await harness.model.select(pickedURL)
    harness.model.passphrase = "wrong horse"

    await harness.model.restore()

    let problem = try #require(harness.model.problem)
    #expect(problem.title == "That passphrase didn't work")
    #expect(problem.body == "Check the passphrase and try again. Your data has not been changed.")
    #expect(harness.restorer.state.withLock { $0.restored.isEmpty })
    #expect(harness.model.phase == .idle)

    // The file is fine, so trying again stays possible, and what was typed
    // stays for correcting.
    #expect(harness.model.passphrase == "wrong horse")
    #expect(harness.model.canRestore)
    #expect(harness.access.held == [pickedURL])

    // Typing again clears the problem it no longer describes.
    harness.model.passphrase = "correct horse"
    #expect(harness.model.problem == nil)
}

@MainActor
@Test(arguments: [
    ArchiveInspectionError.invalidArchiveFormat,
    .unsupportedSchemaVersion(99)
])
func aBackupThatFailsOnlyOnceOpenedIsReportedAsUnusable(_ error: ArchiveInspectionError) async throws {
    let harness = makeHarness()
    harness.inspector.state.withLock { $0.inspectResult = .failure(error) }
    await harness.model.select(pickedURL)
    harness.model.passphrase = "correct horse"

    await harness.model.restore()

    let problem = try #require(harness.model.problem)
    #expect(problem.title == "We couldn't use this backup")
    #expect(
        problem.body
            == "This file may be damaged or from a version of Stabilyz that isn't supported. Your data has not been changed."
    )
    #expect(harness.restorer.state.withLock { $0.restored.isEmpty })
    #expect(harness.model.canRestore == false)
}

// MARK: - Restoring

@MainActor
@Test func theRightPassphraseInspectsThenRestoresTheStagedPayload() async {
    let harness = makeHarness()
    await harness.model.select(pickedURL)
    harness.model.passphrase = "  correct horse "

    await harness.model.restore()

    // The passphrase goes to inspection as typed; canonicalizing it is the
    // inspection service's job, the one place it is defined.
    let inspected = harness.inspector.state.withLock { $0.inspected }
    #expect(inspected.count == 1)
    #expect(inspected.first?.url == pickedURL)
    #expect(inspected.first?.passphrase == "  correct horse ")

    // Exactly what inspection staged, handed on untouched.
    let staged = try? harness.inspector.state.withLock { $0.inspectResult }.get()
    #expect(staged != nil)
    #expect(harness.restorer.state.withLock { $0.restored } == [staged].compactMap { $0 })
    #expect(harness.outcomes.receipts == [StubRestorer.receipt])
    #expect(harness.model.phase == .restored)
    #expect(harness.model.problem == nil)

    // Done with: the passphrase is gone and the file let go.
    #expect(harness.model.passphrase.isEmpty)
    #expect(harness.access.held.isEmpty)
    #expect(harness.model.canRestore == false)
    #expect(harness.model.canChooseDifferentFile == false)
}

@MainActor
@Test func aRestoreThatFailedButLeftTheStoreAloneCanBeRetried() async throws {
    let harness = makeHarness()
    harness.restorer.state.withLock { $0.error = StabilyzError.archiveImport(.restoreFailed) }
    await harness.model.select(pickedURL)
    harness.model.passphrase = "correct horse"

    await harness.model.restore()

    let problem = try #require(harness.model.problem)
    #expect(problem == .restoreFailed)
    #expect(problem.body.hasSuffix("Your data has not been changed."))
    #expect(harness.outcomes.receipts.isEmpty)
    #expect(harness.model.canRestore)
}

@MainActor
@Test func aRestoreThatCouldNotBePutBackNeverSaysTheDataIsUnchanged() async throws {
    let harness = makeHarness()
    harness.restorer.state.withLock { $0.error = StabilyzError.archiveImport(.restoreIncomplete) }
    await harness.model.select(pickedURL)
    harness.model.passphrase = "correct horse"

    await harness.model.restore()

    let problem = try #require(harness.model.problem)
    #expect(problem == .restoreIncomplete)
    #expect(problem.body.contains("not been changed") == false)
    #expect(problem.body.contains("hasn't changed") == false)
    #expect(harness.model.canRestore)
}

@MainActor
@Test func aPayloadTheRestoreRefusesReadsAsAnUnusableBackup() async throws {
    let harness = makeHarness()
    harness.restorer.state.withLock { $0.error = StabilyzError.archiveImport(.corruptedArchive) }
    await harness.model.select(pickedURL)
    harness.model.passphrase = "correct horse"

    await harness.model.restore()

    #expect(try #require(harness.model.problem) == .unusableBackup)
}

@MainActor
@Test func withNoStoreToRestoreIntoTheRestoreFailsWithoutReassuranceBeingWrong() async {
    let harness = makeHarness(withRestorer: false)
    await harness.model.select(pickedURL)
    harness.model.passphrase = "correct horse"

    await harness.model.restore()

    #expect(harness.model.problem == .restoreFailed)
    #expect(harness.outcomes.receipts.isEmpty)
}

// MARK: - Choosing a different file

@MainActor
@Test func chooseADifferentFileOpensThePickerAndSwapsTheFile() async {
    let harness = makeHarness()
    harness.inspector.state.withLock { $0.preflightErrors[pickedURL] = ArchiveInspectionError.notAStabilyzArchive }
    await harness.model.select(pickedURL)
    harness.model.passphrase = "typed for the wrong file"

    harness.model.chooseDifferentFile()
    #expect(harness.model.isPickerPresented)

    await harness.model.fileImported(.success(otherURL))

    #expect(harness.model.file?.url == otherURL)
    #expect(harness.model.file?.displayName == "Stabilyz-Backup-2026-09-15-101500")
    #expect(harness.model.problem == nil, "the old file's problem went with it")
    #expect(harness.model.passphrase.isEmpty, "a passphrase for one file is not one for another")
    #expect(harness.inspector.state.withLock { $0.preflighted } == [pickedURL, otherURL])
    // Access moves with the file: the first is ended, only the second held.
    #expect(harness.access.state.withLock { $0.ended } == [pickedURL])
    #expect(harness.access.held == [otherURL])

    harness.model.passphrase = "correct horse"
    await harness.model.restore()
    #expect(harness.inspector.state.withLock { $0.inspected.map(\.url) } == [otherURL])
}

// MARK: - Leaving

@MainActor
@Test func closingLetsGoOfTheFileAndThePassphrase() async {
    let harness = makeHarness()
    await harness.model.select(pickedURL)
    harness.model.passphrase = "correct horse"

    harness.model.close()

    #expect(harness.outcomes.closes == 1)
    #expect(harness.model.passphrase.isEmpty)
    #expect(harness.access.held.isEmpty)
}
