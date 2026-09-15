import Foundation
import Testing
@testable import Stabilyz

/// The You tab (Task 8.3.1 as repurposed in decisions.md entry 42, docs/04
/// §4.15).

// MARK: - Doubles

private struct FixedBuild: BuildInfoProviding {
    let appVersion = "1.2 (34)"
    let deviceModel = "iPhone17,1"
}

private final class QuietLog: LogService, @unchecked Sendable {
    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {}
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

/// Accepts every file as a Stabilyz export; never opens one.
private struct AcceptingInspector: ArchiveInspecting {
    func preflight(archiveAt url: URL) async throws {}
    func preflight(archiveData: Data) async throws {}
    func inspect(archiveAt url: URL, passphrase: String) async throws -> DecodedArchivePayload {
        throw ArchiveInspectionError.wrongPassphrase
    }
    func inspect(archiveData: Data, passphrase: String) async throws -> DecodedArchivePayload {
        throw ArchiveInspectionError.wrongPassphrase
    }
}

private struct PopulatedStore: LocalDataDetecting {
    func hasLocalData() async throws -> Bool { true }
}

private struct NoScopedAccess: SecurityScopedAccess {
    func begin(_ url: URL) -> Bool { false }
    func end(_ url: URL) {}
}

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

/// Counts what the tab built. Not isolated, so the main-actor factories can
/// capture it.
private final class Built {
    var exportFlows = 0
    var restoreFlows = 0
}

private let pickedURL = URL(fileURLWithPath: "/private/var/mobile/Picked/Stabilyz-Backup-2026-09-15-101500.stabilyz")

@MainActor
private func makeSettings(events: StoreReplacementEvents = StoreReplacementEvents(), built: Built = Built()) -> SettingsViewModel {
    SettingsViewModel(
        makeExportFlow: { onClose in
            built.exportFlows += 1
            return ExportFlowModel(
                exporter: IdleExporter(),
                keyDerivation: IdleKeyDerivation(),
                logService: QuietLog(),
                onClose: onClose
            )
        },
        makeRestoreFlow: { onFinished in
            built.restoreFlows += 1
            return RestoreDataViewModel(
                inspector: AcceptingInspector(),
                restorer: nil,
                localData: PopulatedStore(),
                makeExportFlow: nil,
                fileAccess: NoScopedAccess(),
                logService: QuietLog(),
                onRestored: { _ in onFinished() },
                onClose: onFinished
            )
        },
        buildInfo: FixedBuild(),
        storeEvents: events,
        logService: QuietLog()
    )
}

/// Polls a main-actor condition for up to about a second.
@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

// MARK: - Backup & Data

@MainActor
@Test func exportMyDataPresentsTheExportFlowAndItsCloseDismissesIt() throws {
    let built = Built()
    let settings = makeSettings(built: built)

    settings.exportMyData()

    let flow = try #require(settings.exportFlow)
    #expect(built.exportFlows == 1)
    #expect(flow.phase == .entering)

    flow.onClose()
    #expect(settings.exportFlow == nil)
}

@MainActor
@Test func swipingTheExportSheetAwayDismissesIt() {
    let settings = makeSettings()
    settings.exportMyData()

    settings.exportClosed()

    #expect(settings.exportFlow == nil)
}

@MainActor
@Test func restoreFromBackupOpensTheFilePickerAndNothingElse() {
    let built = Built()
    let settings = makeSettings(built: built)

    settings.restoreFromBackup()

    #expect(settings.isPickingRestoreFile)
    #expect(settings.restoreFlow == nil, "no screen until there is a file")
    #expect(built.restoreFlows == 0)
}

@MainActor
@Test func aPickedFileOpensRestoreYourDataOnThatFile() async throws {
    let built = Built()
    let settings = makeSettings(built: built)
    settings.restoreFromBackup()

    await settings.restoreFileImported(.success(pickedURL))

    let flow = try #require(settings.restoreFlow)
    #expect(built.restoreFlows == 1)
    #expect(flow.file?.url == pickedURL)
    #expect(flow.problem == nil)
}

@MainActor
@Test func backingOutOfThePickerOpensNothing() async {
    let built = Built()
    let settings = makeSettings(built: built)
    settings.restoreFromBackup()

    await settings.restoreFileImported(.failure(CocoaError(.userCancelled)))

    #expect(settings.restoreFlow == nil)
    #expect(built.restoreFlows == 0)
}

@MainActor
@Test func leavingRestoreYourDataDismissesItAndWipesThePassphrase() async throws {
    let settings = makeSettings()
    await settings.restoreFileImported(.success(pickedURL))
    let flow = try #require(settings.restoreFlow)
    flow.passphrase = "correct horse"

    flow.close()

    #expect(settings.restoreFlow == nil)
    #expect(flow.passphrase.isEmpty)
}

// MARK: - Clinician & About

@MainActor
@Test func theClinicianSummaryAndDisclaimerOpenFromTheTab() {
    let settings = makeSettings()

    settings.openClinicianSummary()
    settings.showDisclaimer()

    #expect(settings.isShowingClinicianSummary)
    #expect(settings.isShowingDisclaimer)
}

@MainActor
@Test func aboutNamesTheAppAndItsBuild() {
    let settings = makeSettings()
    #expect(SettingsViewModel.appName == "Stabilyz")
    #expect(settings.version == "1.2 (34)")
}

@MainActor
@Test func theDisclaimerIsTheTextAgreedToDuringOnboarding() {
    #expect(SettingsViewModel.disclaimerBody == DisclaimerText.body)
    #expect(SettingsViewModel.disclaimerBody.contains("not a medical device"))
}

@MainActor
@Test func theTabsLabelsAreTheSpecifiedOnes() {
    #expect(SettingsViewModel.backupSectionTitle == "Backup & Data")
    #expect(SettingsViewModel.exportLabel == "Export My Data")
    #expect(SettingsViewModel.restoreLabel == "Restore from Backup")
    #expect(SettingsViewModel.aboutSectionTitle == "About & Legal")
    #expect(SettingsViewModel.clinicianSummaryLabel == ClinicianSummaryViewModel.title)
}

// MARK: - Store replacement

@MainActor
@Test func aStoreReplacementWhileOnYouDismissesEverythingPresented() async throws {
    let events = StoreReplacementEvents()
    let settings = makeSettings(events: events)
    await settings.restoreFileImported(.success(pickedURL))
    let restore = try #require(settings.restoreFlow)
    restore.passphrase = "correct horse"
    settings.exportMyData()
    settings.isPickingRestoreFile = true
    settings.openClinicianSummary()
    settings.showDisclaimer()

    let observation = Task { await settings.observeStoreReplacements() }
    defer { observation.cancel() }
    #expect(await eventually { events.subscriberCount == 1 })

    events.publish(StoreReplacement(receipt: RestoreReceipt(schemaVersion: 1, sessionCount: 4, baselineModes: [.quickTest])))

    #expect(await eventually {
        settings.exportFlow == nil
            && settings.restoreFlow == nil
            && !settings.isPickingRestoreFile
            && !settings.isShowingClinicianSummary
            && !settings.isShowingDisclaimer
    })
    #expect(restore.passphrase.isEmpty, "the dismissed restore screen took its passphrase with it")
}

@MainActor
@Test func theTabStopsListeningWhenItsTaskEnds() async {
    let events = StoreReplacementEvents()
    let settings = makeSettings(events: events)

    let observation = Task { await settings.observeStoreReplacements() }
    #expect(await eventually { events.subscriberCount == 1 })

    observation.cancel()
    #expect(await eventually { events.subscriberCount == 0 })
}

@MainActor
@Test func aStoreReplacementWithNothingPresentedIsHarmless() {
    let settings = makeSettings()

    settings.handleStoreReplacement()

    #expect(settings.exportFlow == nil)
    #expect(settings.restoreFlow == nil)
}
