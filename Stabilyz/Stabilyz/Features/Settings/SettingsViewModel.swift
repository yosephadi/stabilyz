import Foundation

/// Drives the You tab (docs/04 §4.15, docs/11 §11.1, Task 8.3.1 as repurposed
/// in decisions.md entry 42).
///
/// Settings is a container: every flow it opens is its own feature. It owns
/// only what is presented and when —
///
/// - **Export My Data** (docs/04 §4.16), in a sheet;
/// - **Restore from Backup** (docs/04 §4.17): the document picker, then Restore
///   your data over the tab. Local data always exists here, so that screen's
///   overwrite choice always applies (Task 10.3.3);
/// - **Clinician Summary** [PRD §5: "accessible from History or Settings"];
/// - **About**: the build, and the disclaimer the user agreed to [PRD §7 AC].
///
/// **After a restore.** The store the tab was describing is gone. Everything
/// presented is dismissed on the replacement broadcast; the app root
/// re-resolves on the same broadcast and rebuilds the shell around the new
/// store (docs/11 §11.4).
@MainActor
@Observable
final class SettingsViewModel {
    typealias ExportFlowFactory = @MainActor (_ onClose: @escaping @MainActor () -> Void) -> ExportFlowModel
    typealias RestoreFlowFactory = @MainActor (_ onFinished: @escaping @MainActor () -> Void) -> RestoreDataViewModel

    /// Export My Data, while it is presented.
    private(set) var exportFlow: ExportFlowModel?
    /// Restore your data, once a file has been picked.
    private(set) var restoreFlow: RestoreDataViewModel?

    /// Bound to the document picker.
    var isPickingRestoreFile = false
    var isShowingClinicianSummary = false
    var isShowingDisclaimer = false

    /// "1.2 (34)": the marketing version and the build.
    let version: String

    private let makeExportFlow: ExportFlowFactory
    private let makeRestoreFlow: RestoreFlowFactory
    /// Opened by Restore from Backup in place of the document picker, when set
    /// (UI tests).
    private let presetRestoreFile: URL?
    private let storeEvents: StoreReplacementEvents
    private let logService: LogService

    init(
        makeExportFlow: @escaping ExportFlowFactory,
        makeRestoreFlow: @escaping RestoreFlowFactory,
        buildInfo: BuildInfoProviding,
        storeEvents: StoreReplacementEvents,
        logService: LogService,
        presetRestoreFile: URL? = nil
    ) {
        self.makeExportFlow = makeExportFlow
        self.makeRestoreFlow = makeRestoreFlow
        self.presetRestoreFile = presetRestoreFile
        self.storeEvents = storeEvents
        self.logService = logService
        version = buildInfo.appVersion
    }

    // MARK: - Backup & Data

    func exportMyData() {
        exportFlow = makeExportFlow { [weak self] in self?.exportClosed() }
    }

    /// The export sheet went, by Close or by swipe.
    func exportClosed() {
        exportFlow = nil
    }

    func restoreFromBackup() {
        if let presetRestoreFile {
            Task { await restoreFileImported(.success(presetRestoreFile)) }
            return
        }
        isPickingRestoreFile = true
    }

    /// The picker's result: Restore your data, on the picked file. Backing out
    /// of the picker opens nothing.
    func restoreFileImported(_ result: Result<URL, Error>) async {
        if case .failure(let error) = result, RestoreDataViewModel.isCancellation(error) { return }
        let flow = makeRestoreFlow { [weak self] in self?.restoreClosed() }
        restoreFlow = flow
        logService.log(.info, .backup, "restore opened from Settings")
        await flow.fileImported(result)
    }

    /// Restore your data went: closed, finished, or dismissed.
    func restoreClosed() {
        restoreFlow?.discardSecrets()
        restoreFlow = nil
    }

    // MARK: - Clinician & About

    func openClinicianSummary() {
        isShowingClinicianSummary = true
    }

    func showDisclaimer() {
        isShowingDisclaimer = true
    }

    // MARK: - Store replacement

    /// Dismisses everything on each store replacement, for as long as the
    /// calling task runs.
    func observeStoreReplacements() async {
        for await _ in storeEvents.subscribe() {
            handleStoreReplacement()
        }
    }

    /// Nothing on screen may go on describing the store that was replaced.
    func handleStoreReplacement() {
        exportFlow = nil
        restoreClosed()
        isPickingRestoreFile = false
        isShowingClinicianSummary = false
        isShowingDisclaimer = false
        logService.log(.info, .backup, "Settings reset after the store was replaced")
    }

    // MARK: - Copy

    static let title = "You"
    static let clinicianSummaryLabel = ClinicianSummaryViewModel.title
    static let backupSectionTitle = "Backup & Data"
    static let exportLabel = "Export My Data"
    static let restoreLabel = "Restore from Backup"
    static let aboutSectionTitle = "About & Legal"
    static let appNameLabel = "App"
    static let appName = "Stabilyz"
    static let versionLabel = "Version"
    static let disclaimerLabel = "Disclaimer"
    /// The words agreed to during onboarding, not a second copy of them
    /// [PRD §7 AC].
    static let disclaimerBody = DisclaimerText.body
}
