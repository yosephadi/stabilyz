import Foundation
import Testing
@testable import Stabilyz

/// Restoring over existing data (Task 10.3.3, PRD §5 / §7 AC, docs/04 §4.16,
/// docs/11 §11.1): never a silent overwrite.

// MARK: - Doubles

private struct SimulatedFailure: Error {}

/// Opens every file as `staged`.
private final class OpeningInspector: ArchiveInspecting, @unchecked Sendable {
    let staged: DecodedArchivePayload
    let result = Locked<Error?>(nil)
    let inspections = Locked(0)

    init(staged: DecodedArchivePayload) { self.staged = staged }

    func preflight(archiveAt url: URL) async throws {}
    func preflight(archiveData: Data) async throws {}

    func inspect(archiveAt url: URL, passphrase: String) async throws -> DecodedArchivePayload {
        inspections.withLock { $0 += 1 }
        if let error = result.withLock({ $0 }) { throw error }
        return staged
    }

    func inspect(archiveData: Data, passphrase: String) async throws -> DecodedArchivePayload { staged }
}

private final class RecordingRestorer: ArchiveRestoring, @unchecked Sendable {
    let restored = Locked<[DecodedArchivePayload]>([])
    let error = Locked<Error?>(nil)
    static let receipt = RestoreReceipt(schemaVersion: 1, sessionCount: 2, baselineModes: [])

    func restore(_ staged: DecodedArchivePayload) async throws -> RestoreReceipt {
        restored.withLock { $0.append(staged) }
        if let error = error.withLock({ $0 }) { throw error }
        return Self.receipt
    }
}

private final class ScriptedDetector: LocalDataDetecting, @unchecked Sendable {
    let answer: Result<Bool, Error>
    let checks = Locked(0)

    init(_ answer: Result<Bool, Error>) { self.answer = answer }

    func hasLocalData() async throws -> Bool {
        checks.withLock { $0 += 1 }
        return try answer.get()
    }
}

private struct OpenAccess: SecurityScopedAccess {
    func begin(_ url: URL) -> Bool { false }
    func end(_ url: URL) {}
}

/// An exporter that is never reached: these tests only open and close the
/// export flow.
private struct IdleExporter: ArchiveExporting {
    func prepare(_ request: ExportRequest) async throws -> PreparedExport {
        throw StabilyzError.export(.archiveGenerationFailed)
    }
    func discard(_ export: PreparedExport) async {}
    func discardStaleExports() async {}
}

private struct IdleKeyDerivation: KeyDerivation {
    func deriveKey(passphrase: [UInt8], salt: [UInt8], iterations: Int, keyByteCount: Int) throws -> [UInt8] { [] }
    func calibratedIterationCount(targetDuration: TimeInterval) -> Int { 600_000 }
}

/// What the screen reported outward. Not isolated, so it can be captured by
/// the main-actor callbacks.
private final class Outcomes {
    var receipts: [RestoreReceipt] = []
    var closes = 0
    var exportFlowsMade = 0
}

// MARK: - Fixtures

private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + seconds) }

/// A clinically consistent backup: its own profile and two valid walks.
private func backup() -> DecodedArchivePayload {
    DecodedArchivePayload(
        payload: ArchivePayload(
            profile: .fixture(level: .transfemoral, prosthesisType: "Backup profile"),
            baselines: [],
            sessions: [
                GaitSession.fixtureValid(mode: .quickTest, startedAt: at(0)),
                GaitSession.fixtureValid(mode: .fullTest, startedAt: at(3_600))
            ],
            appVersion: "1.0 (7)",
            algorithmVersion: "1.0.0",
            exportedAt: at(7_200)
        ),
        schemaVersion: 1
    )
}

private let pickedURL = URL(fileURLWithPath: "/private/var/mobile/Picked/userdata-stabilyz.stabilyz")

@MainActor
private func makeModel(
    inspector: ArchiveInspecting,
    restorer: ArchiveRestoring?,
    detector: LocalDataDetecting,
    outcomes: Outcomes,
    offersExport: Bool = true
) -> RestoreDataViewModel {
    let exportFlow: @MainActor (_ onClose: @escaping @MainActor () -> Void) -> ExportFlowModel = { onClose in
        outcomes.exportFlowsMade += 1
        return ExportFlowModel(
            exporter: IdleExporter(),
            keyDerivation: IdleKeyDerivation(),
            logService: SilentStoreLog(),
            onClose: onClose
        )
    }
    return RestoreDataViewModel(
        inspector: inspector,
        restorer: restorer,
        localData: detector,
        makeExportFlow: offersExport ? exportFlow : nil,
        fileAccess: OpenAccess(),
        logService: SilentStoreLog(),
        onRestored: { outcomes.receipts.append($0) },
        onClose: { outcomes.closes += 1 }
    )
}

/// A model with the file picked and a passphrase typed.
@MainActor
private func readyModel(
    hasLocalData: Result<Bool, Error>,
    inspector: OpeningInspector = OpeningInspector(staged: backup()),
    restorer: RecordingRestorer = RecordingRestorer(),
    outcomes: Outcomes = Outcomes()
) async -> (RestoreDataViewModel, ScriptedDetector) {
    let detector = ScriptedDetector(hasLocalData)
    let model = makeModel(inspector: inspector, restorer: restorer, detector: detector, outcomes: outcomes)
    await model.select(pickedURL)
    model.passphrase = "correct horse"
    return (model, detector)
}

// MARK: - Detecting existing data

@Suite struct LocalDataDetectionTests {
    private func detector(_ store: InMemoryStore) -> RepositoryLocalDataDetector {
        RepositoryLocalDataDetector(profiles: store.profiles, sessions: store.sessions, baselines: store.baselines)
    }

    @Test func aFreshStoreHoldsNothingToOverwrite() async throws {
        let store = try InMemoryStore()
        #expect(try await detector(store).hasLocalData() == false)
    }

    @Test func aProfileAloneIsData() async throws {
        let store = try InMemoryStore()
        try await store.profiles.save(.fixture())
        #expect(try await detector(store).hasLocalData())
    }

    @Test func aBaselineAloneIsData() async throws {
        let store = try InMemoryStore()
        try await store.baselines.save(.fixture(mode: .fullTest))
        #expect(try await detector(store).hasLocalData())
    }

    @Test(arguments: TestMode.allCases)
    func aValidSessionInEitherModeIsData(_ mode: TestMode) async throws {
        let store = try InMemoryStore()
        try await store.sessions.save(.fixtureValid(mode: mode))
        #expect(try await detector(store).hasLocalData())
    }

    @Test(arguments: TestMode.allCases)
    func anInvalidSessionAloneIsStillData(_ mode: TestMode) async throws {
        // A restore deletes invalid sessions too, so they count.
        let store = try InMemoryStore()
        try await store.sessions.save(.fixtureInvalid(mode: mode))
        #expect(try await detector(store).hasLocalData())
    }
}

// MARK: - The choice, on the view model

@MainActor
@Test func anEmptyStoreIsRestoredWithoutAsking() async {
    let restorer = RecordingRestorer()
    let outcomes = Outcomes()
    let (model, detector) = await readyModel(hasLocalData: .success(false), restorer: restorer, outcomes: outcomes)

    await model.restore()

    #expect(detector.checks.withLock { $0 } == 1)
    #expect(model.isConfirmationPresented == false)
    #expect(restorer.restored.withLock { $0.count } == 1)
    #expect(outcomes.receipts == [RecordingRestorer.receipt])
    #expect(model.phase == .restored)
}

@MainActor
@Test func existingDataPausesTheRestoreAndAsks() async {
    let restorer = RecordingRestorer()
    let (model, _) = await readyModel(hasLocalData: .success(true), restorer: restorer)

    await model.restore()

    #expect(model.isConfirmationPresented)
    #expect(model.phase == .awaitingConfirmation)
    #expect(restorer.restored.withLock { $0.isEmpty }, "nothing is replaced before the choice")
    #expect(model.problem == nil)
    #expect(model.passphrase == "correct horse")
}

@MainActor
@Test func theDialogSaysWhatWillBeLostAndOffersThreeWaysOn() {
    #expect(RestoreDataViewModel.replaceTitle == "Replace existing data?")
    #expect(
        RestoreDataViewModel.replaceMessage
            == "Restoring this backup will replace your current walk history and baselines. Your current data on this device will be erased."
    )
    #expect(RestoreDataViewModel.replaceLabel == "Replace Data")
    #expect(RestoreDataViewModel.exportFirstLabel == "Export Current Data First")
    #expect(RestoreDataViewModel.keepLabel == "Keep Current Data")
}

@MainActor
@Test func aStoreThatCannotBeCheckedIsAskedAboutRatherThanOverwritten() async {
    let restorer = RecordingRestorer()
    let (model, _) = await readyModel(hasLocalData: .failure(SimulatedFailure()), restorer: restorer)

    await model.restore()

    #expect(model.isConfirmationPresented)
    #expect(restorer.restored.withLock { $0.isEmpty })
}

@MainActor
@Test func aWrongPassphraseNeverGetsAsFarAsTheQuestion() async {
    let inspector = OpeningInspector(staged: backup())
    inspector.result.withLock { $0 = ArchiveInspectionError.wrongPassphrase }
    let (model, detector) = await readyModel(hasLocalData: .success(true), inspector: inspector)

    await model.restore()

    #expect(model.problem == .wrongPassphrase)
    #expect(model.isConfirmationPresented == false)
    #expect(detector.checks.withLock { $0 } == 0)
}

@MainActor
@Test func keepingCurrentDataRestoresNothingAndWipesThePassphrase() async {
    let restorer = RecordingRestorer()
    let (model, _) = await readyModel(hasLocalData: .success(true), restorer: restorer)
    await model.restore()

    model.keepCurrentData()

    #expect(model.isConfirmationPresented == false)
    #expect(model.phase == .idle)
    #expect(model.passphrase.isEmpty)
    #expect(model.file?.url == pickedURL, "stays on the restore screen with the file")
    #expect(model.problem == nil)
    #expect(restorer.restored.withLock { $0.isEmpty })

    // The opened backup went with the choice: Replace can no longer reach it.
    await model.confirmReplace()
    #expect(restorer.restored.withLock { $0.isEmpty })
}

@MainActor
@Test func replacingRestoresTheOpenedBackupAndFinishes() async {
    let restorer = RecordingRestorer()
    let outcomes = Outcomes()
    let (model, _) = await readyModel(hasLocalData: .success(true), restorer: restorer, outcomes: outcomes)
    await model.restore()

    await model.confirmReplace()

    #expect(restorer.restored.withLock { $0.count } == 1)
    #expect(model.isConfirmationPresented == false)
    #expect(model.phase == .restored)
    #expect(model.passphrase.isEmpty)
    #expect(outcomes.receipts == [RecordingRestorer.receipt])
}

@MainActor
@Test func aReplaceThatFailsSaysSoAndDoesNotAskAgain() async {
    let restorer = RecordingRestorer()
    restorer.error.withLock { $0 = StabilyzError.archiveImport(.restoreFailed) }
    let outcomes = Outcomes()
    let (model, _) = await readyModel(hasLocalData: .success(true), restorer: restorer, outcomes: outcomes)
    await model.restore()

    await model.confirmReplace()

    #expect(model.problem == .restoreFailed)
    #expect(model.phase == .idle)
    #expect(model.isConfirmationPresented == false)
    #expect(outcomes.receipts.isEmpty)
    // A retry opens the backup and asks again from the start.
    #expect(model.canRestore)
}

@MainActor
@Test func exportingFirstRestoresNothingAndThenAsksTheSameQuestion() async throws {
    let restorer = RecordingRestorer()
    let outcomes = Outcomes()
    let (model, _) = await readyModel(hasLocalData: .success(true), restorer: restorer, outcomes: outcomes)
    await model.restore()
    #expect(model.canExportFirst)

    model.exportCurrentDataFirst()

    let flow = try #require(model.exportFlow)
    #expect(outcomes.exportFlowsMade == 1)
    #expect(model.isConfirmationPresented == false)
    #expect(model.phase == .awaitingConfirmation)

    // The export flow closing takes its sheet away; the question returns
    // once the sheet is gone.
    flow.onClose()
    #expect(model.exportFlow == nil)
    #expect(model.isConfirmationPresented == false)
    model.exportDismissed()
    #expect(model.isConfirmationPresented)
    #expect(restorer.restored.withLock { $0.isEmpty })

    await model.confirmReplace()
    #expect(restorer.restored.withLock { $0.count } == 1)
}

@MainActor
@Test func withoutAnExportFlowTheChoiceHasNoExportOption() async {
    let detector = ScriptedDetector(.success(true))
    let model = makeModel(
        inspector: OpeningInspector(staged: backup()),
        restorer: RecordingRestorer(),
        detector: detector,
        outcomes: Outcomes(),
        offersExport: false
    )
    await model.select(pickedURL)
    model.passphrase = "correct horse"
    await model.restore()

    #expect(model.canExportFirst == false)
    model.exportCurrentDataFirst()
    #expect(model.exportFlow == nil)
    #expect(model.isConfirmationPresented)
}

@MainActor
@Test func aDialogDismissedWithoutAnAnswerIsAskedAgainByRestore() async {
    let restorer = RecordingRestorer()
    let inspector = OpeningInspector(staged: backup())
    let (model, _) = await readyModel(hasLocalData: .success(true), inspector: inspector, restorer: restorer)
    await model.restore()

    model.isConfirmationPresented = false
    #expect(model.canRestore)
    await model.restore()

    #expect(model.isConfirmationPresented)
    #expect(inspector.inspections.withLock { $0 } == 1, "the opened backup is reused, not reopened")
    #expect(restorer.restored.withLock { $0.isEmpty })
}

@MainActor
@Test func leavingWhileAskingDropsTheOpenedBackup() async {
    let restorer = RecordingRestorer()
    let outcomes = Outcomes()
    let (model, _) = await readyModel(hasLocalData: .success(true), restorer: restorer, outcomes: outcomes)
    await model.restore()

    model.close()

    #expect(outcomes.closes == 1)
    #expect(model.passphrase.isEmpty)
    #expect(model.isConfirmationPresented == false)
    await model.confirmReplace()
    #expect(restorer.restored.withLock { $0.isEmpty })
}

// MARK: - Against a real store

/// The view model over the real restore service and a real in-memory store.
@MainActor
private struct LiveRestore {
    let store: InMemoryStore
    /// The one backup the inspector opens. `backup()` mints fresh ids per
    /// call, so the store is compared against this instance.
    let staged: DecodedArchivePayload
    let replacer: SwiftDataStoreReplacer
    let events: StoreReplacementEvents
    let model: RestoreDataViewModel
    let outcomes: Outcomes

    init(store: InMemoryStore) {
        self.store = store
        staged = backup()
        replacer = SwiftDataStoreReplacer(reader: store.reader, writer: store.writer)
        events = StoreReplacementEvents()
        outcomes = Outcomes()
        model = makeModel(
            inspector: OpeningInspector(staged: staged),
            restorer: ArchiveRestoreService(replacer: replacer, events: events, logService: SilentStoreLog()),
            detector: RepositoryLocalDataDetector(
                profiles: store.profiles,
                sessions: store.sessions,
                baselines: store.baselines
            ),
            outcomes: outcomes
        )
    }
}

/// A store with a profile, a baseline, a valid session and an invalid one.
private func populatedStore() async throws -> InMemoryStore {
    let store = try InMemoryStore()
    try await store.profiles.save(.fixture(prosthesisType: "Local profile"))
    try await store.baselines.save(.fixture(mode: .fullTest))
    try await store.sessions.save(.fixtureValid(mode: .fullTest, startedAt: at(-86_400)))
    try await store.sessions.save(.fixtureInvalid(mode: .quickTest, startedAt: at(-80_000)))
    return store
}

@MainActor
@Test func cancellingTheOverwriteLeavesTheStoreExactlyAsItWas() async throws {
    let live = LiveRestore(store: try await populatedStore())
    let before = try await live.replacer.contents()

    await live.model.select(pickedURL)
    live.model.passphrase = "correct horse"
    await live.model.restore()
    #expect(live.model.isConfirmationPresented)
    #expect(try await live.replacer.contents() == before, "asking touched nothing")

    live.model.keepCurrentData()

    #expect(try await live.replacer.contents() == before)
    #expect(live.outcomes.receipts.isEmpty)
    #expect(live.model.passphrase.isEmpty)
}

@MainActor
@Test func confirmingTheOverwriteReplacesTheStoreAndAnnouncesIt() async throws {
    let live = LiveRestore(store: try await populatedStore())
    var replacements = live.events.subscribe().makeAsyncIterator()

    await live.model.select(pickedURL)
    live.model.passphrase = "correct horse"
    await live.model.restore()
    await live.model.confirmReplace()

    let archive = live.staged.payload
    let after = try await live.replacer.contents()
    #expect(after == StoreContents(profile: archive.profile, baselines: archive.baselines, sessions: archive.sessions))

    let replacement = try #require(await replacements.next())
    #expect(replacement.receipt.sessionCount == 2)
    #expect(live.outcomes.receipts == [replacement.receipt])
    #expect(live.model.phase == .restored)
}

@MainActor
@Test func onAFreshInstallTheBackupGoesStraightIn() async throws {
    let live = LiveRestore(store: try InMemoryStore())
    var replacements = live.events.subscribe().makeAsyncIterator()

    await live.model.select(pickedURL)
    live.model.passphrase = "correct horse"
    await live.model.restore()

    #expect(live.model.isConfirmationPresented == false)
    let replacement = try #require(await replacements.next())
    #expect(replacement.receipt.sessionCount == 2)
    #expect(try await live.store.profiles.fetchProfile()?.prosthesisType == "Backup profile")
}
