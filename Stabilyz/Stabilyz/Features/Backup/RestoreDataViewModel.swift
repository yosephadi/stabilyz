import Foundation

/// Drives Restore your data (Figma 64:3890, docs/04 §4.1, §4.16, docs/13
/// §13.4–13.5, Tasks 10.3.2–10.3.3): a picked export, its passphrase, and the
/// restore.
///
/// The screen opens on a file already chosen. Picking it runs the preflight at
/// once, so a file that is not a Stabilyz export — or one this build cannot
/// read — says so before anyone types a passphrase. Restore backup then
/// inspects with the passphrase and hands the staged payload to
/// `ArchiveRestoring`, which replaces the store atomically and broadcasts the
/// replacement; the app root re-resolves on that broadcast.
///
/// **Existing data (Task 10.3.3).** Once the backup has opened, and before the
/// store is touched, the store is checked. Empty, and the restore goes
/// straight ahead [PRD §5 first launch]. Otherwise it waits on an explicit
/// choice — Keep Current Data, Export Current Data First, or Replace Data
/// [PRD §7 AC: never a silent overwrite]. A store that cannot be checked is
/// treated as holding data: asking is the only safe answer.
///
/// **The picked file.** Security-scoped access is taken when the file is
/// selected and held until it is swapped, the screen closes, or the restore
/// succeeds — the passphrase can take a while to type, and the file must still
/// be readable when it is.
///
/// Every string the screen shows is decided here (docs/11 §11.5).
@MainActor
@Observable
final class RestoreDataViewModel: Identifiable {
    struct PickedFile: Equatable {
        let url: URL
        /// The file's name without `.stabilyz` (Figma: "userdata-stabilyz").
        var displayName: String { url.deletingPathExtension().lastPathComponent }
    }

    /// What went wrong, as the screen words it: a title above the field and
    /// an explanation beneath it.
    enum Problem: Equatable {
        /// The key-check did not open. The file is fine; the passphrase is not.
        case wrongPassphrase
        /// Damaged, tampered with, unreadable, or from a newer Stabilyz.
        case unusableBackup
        /// Some other kind of file.
        case notAStabilyzBackup
        /// The replace failed and the store is exactly as it was.
        case restoreFailed
        /// The replace failed and the pre-restore store could not be put back.
        case restoreIncomplete

        var title: String {
            switch self {
            case .wrongPassphrase: "That passphrase didn't work"
            case .unusableBackup: "We couldn't use this backup"
            case .notAStabilyzBackup: "This isn't a Stabilyz backup"
            case .restoreFailed: "We couldn't restore this backup"
            case .restoreIncomplete: "Restoring didn't finish"
            }
        }

        var body: String {
            switch self {
            case .wrongPassphrase:
                "Check the passphrase and try again. Your data has not been changed."
            case .unusableBackup:
                "This file may be damaged or from a version of Stabilyz that isn't supported. Your data has not been changed."
            case .notAStabilyzBackup:
                "Choose an export created by Stabilyz, then try again."
            case .restoreFailed:
                "Something went wrong while restoring. Try again. Your data has not been changed."
            case .restoreIncomplete:
                // The one outcome that must not reassure: the store may not be
                // what it was (docs/13 §13.5).
                "Some of your data may be missing. Try restoring this backup again."
            }
        }

        /// Whether the problem is the file itself, so trying it again cannot
        /// help — only choosing a different one can.
        var isAboutTheFile: Bool {
            self == .unusableBackup || self == .notAStabilyzBackup
        }

        /// From anything inspection throws.
        init(inspection error: Error) {
            switch error as? ArchiveInspectionError {
            case .wrongPassphrase: self = .wrongPassphrase
            case .notAStabilyzArchive: self = .notAStabilyzBackup
            default: self = .unusableBackup
            }
        }

        /// From anything the restore throws. A failure it did not classify
        /// still came from a service that leaves the store untouched on
        /// failure, so it reads as `restoreFailed`.
        init(restore error: Error) {
            switch error as? StabilyzError {
            case .archiveImport(.wrongPassphrase): self = .wrongPassphrase
            case .archiveImport(.notAStabilyzArchive): self = .notAStabilyzBackup
            case .archiveImport(.corruptedArchive), .archiveImport(.unreadableFile), .schemaCompatibility:
                self = .unusableBackup
            case .archiveImport(.restoreIncomplete): self = .restoreIncomplete
            default: self = .restoreFailed
            }
        }
    }

    enum Phase: Equatable {
        case idle
        /// The preflight on a just-picked file.
        case checkingFile
        /// Inspecting with the passphrase, checking the store, or replacing it.
        case restoring
        /// The backup opened and the store holds data: waiting on the
        /// overwrite choice. Nothing has been touched.
        case awaitingConfirmation
        case restored
    }

    private(set) var file: PickedFile?
    private(set) var phase: Phase = .idle
    private(set) var problem: Problem?

    /// Editing clears a wrong-passphrase problem: it described what was typed
    /// before, not what is typed now.
    var passphrase = "" {
        didSet {
            if problem == .wrongPassphrase, passphrase != oldValue { problem = nil }
        }
    }

    /// Bound to the document picker for "Choose a different file".
    var isPickerPresented = false

    /// Bound to the overwrite confirmation.
    var isConfirmationPresented = false

    /// Export My Data, while "Export Current Data First" is running.
    private(set) var exportFlow: ExportFlowModel?

    var onRestored: @MainActor (RestoreReceipt) -> Void
    var onClose: @MainActor () -> Void

    private let inspector: ArchiveInspecting
    private let restorer: ArchiveRestoring?
    private let localData: LocalDataDetecting
    private let makeExportFlow: (@MainActor (_ onClose: @escaping @MainActor () -> Void) -> ExportFlowModel)?
    private let fileAccess: SecurityScopedAccess
    private let logService: LogService

    /// The picked file this model currently holds security-scoped access to.
    private var accessedURL: URL?
    /// Bumped per selection, so a slow preflight for a file since swapped out
    /// cannot report on the file that replaced it.
    private var selection = 0
    /// The opened backup, held while the overwrite choice is open. Dropped the
    /// moment the choice is anything but Replace.
    private var pendingRestore: DecodedArchivePayload?

    /// - Parameters:
    ///   - restorer: nil where there is no store to restore into (the degraded
    ///     graph); a restore attempt then reports `restoreFailed`.
    ///   - makeExportFlow: builds Export My Data for "Export Current Data
    ///     First"; nil leaves that choice out.
    init(
        inspector: ArchiveInspecting,
        restorer: ArchiveRestoring?,
        localData: LocalDataDetecting,
        makeExportFlow: (@MainActor (_ onClose: @escaping @MainActor () -> Void) -> ExportFlowModel)?,
        fileAccess: SecurityScopedAccess,
        logService: LogService,
        onRestored: @escaping @MainActor (RestoreReceipt) -> Void = { _ in },
        onClose: @escaping @MainActor () -> Void = {}
    ) {
        self.inspector = inspector
        self.restorer = restorer
        self.localData = localData
        self.makeExportFlow = makeExportFlow
        self.fileAccess = fileAccess
        self.logService = logService
        self.onRestored = onRestored
        self.onClose = onClose
    }

    // MARK: - State

    var isWorking: Bool { phase == .checkingFile || phase == .restoring }

    /// While the choice is open, Restore backup asks it again rather than
    /// starting over — for a dialog dismissed without an answer.
    var canRestore: Bool {
        guard file != nil,
              phase == .idle || phase == .awaitingConfirmation,
              problem?.isAboutTheFile != true
        else { return false }
        return !PassphrasePolicy.canonical(passphrase).isEmpty
    }

    var canChooseDifferentFile: Bool { !isWorking && phase != .restored }

    var canExportFirst: Bool { makeExportFlow != nil }

    // MARK: - Picking a file

    /// Whether a picker result is the person backing out, which changes
    /// nothing.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        (error as? CocoaError)?.code == .userCancelled
    }

    /// The document picker's result.
    func fileImported(_ result: Result<URL, Error>) async {
        switch result {
        case .success(let url):
            await select(url)
        case .failure(let error):
            guard !Self.isCancellation(error) else { return }
            logService.log(.error, .backup, "restore file pick failed: \(type(of: error))")
            // The picker could not hand over a file; whatever was picked
            // before stays picked.
            if file == nil { problem = .unusableBackup }
        }
    }

    /// Makes `url` the file to restore, and preflights it.
    func select(_ url: URL) async {
        guard phase != .restoring, phase != .restored else { return }

        releaseFile()
        dropPendingRestore()
        if fileAccess.begin(url) { accessedURL = url }
        file = PickedFile(url: url)
        // A passphrase typed for one file is not one for another.
        passphrase = ""
        problem = nil
        selection += 1
        let current = selection

        phase = .checkingFile
        do {
            try await inspector.preflight(archiveAt: url)
            guard current == selection else { return }
        } catch {
            guard current == selection else { return }
            problem = Problem(inspection: error)
            logService.log(.info, .backup, "restore preflight refused the picked file")
        }
        phase = .idle
    }

    func chooseDifferentFile() {
        guard canChooseDifferentFile else { return }
        isPickerPresented = true
    }

    // MARK: - Restoring

    /// Inspects the file with the passphrase, checks the store, then replaces
    /// it — or asks first, if there is anything to lose.
    func restore() async {
        guard canRestore, let file else { return }
        if phase == .awaitingConfirmation, pendingRestore != nil {
            isConfirmationPresented = true
            return
        }

        problem = nil
        phase = .restoring

        let staged: DecodedArchivePayload
        do {
            staged = try await inspector.inspect(archiveAt: file.url, passphrase: passphrase)
        } catch {
            problem = Problem(inspection: error)
            phase = .idle
            return
        }

        // No store means nothing to overwrite and nothing to restore into;
        // asking first would only put a question before the failure.
        guard restorer != nil else {
            logService.log(.error, .backup, "restore unavailable: no store to restore into")
            problem = .restoreFailed
            phase = .idle
            return
        }

        if await storeHasData() {
            pendingRestore = staged
            phase = .awaitingConfirmation
            isConfirmationPresented = true
            logService.log(.info, .backup, "restore paused: the store holds data, asking before replacing it")
            return
        }

        await replace(with: staged)
    }

    // MARK: - The overwrite choice

    /// Replace Data.
    func confirmReplace() async {
        guard phase == .awaitingConfirmation, let staged = pendingRestore else { return }
        isConfirmationPresented = false
        pendingRestore = nil
        phase = .restoring
        logService.log(.info, .backup, "replace confirmed")
        await replace(with: staged)
    }

    /// Keep Current Data: nothing is touched, the screen stays, and the
    /// passphrase goes — a decision not to restore is not a reason to keep it.
    func keepCurrentData() {
        guard phase == .awaitingConfirmation else { return }
        dropPendingRestore()
        passphrase = ""
        phase = .idle
        logService.log(.info, .backup, "replace declined: current data kept")
    }

    /// Export Current Data First: runs Export My Data, then asks the same
    /// question again (docs/11 §11.1).
    func exportCurrentDataFirst() {
        guard phase == .awaitingConfirmation, pendingRestore != nil, let makeExportFlow else { return }
        isConfirmationPresented = false
        exportFlow = makeExportFlow { [weak self] in self?.exportClosed() }
    }

    /// The export flow closed. The question comes back once its sheet has
    /// finished going — `exportDismissed()` — not while it is still on screen.
    func exportClosed() {
        exportFlow = nil
    }

    /// The export sheet is gone, however it went.
    func exportDismissed() {
        exportFlow = nil
        guard phase == .awaitingConfirmation, pendingRestore != nil else { return }
        isConfirmationPresented = true
    }

    private func storeHasData() async -> Bool {
        do {
            return try await localData.hasLocalData()
        } catch {
            logService.log(.error, .backup, "could not check the store before restoring: \(type(of: error))")
            return true
        }
    }

    private func replace(with staged: DecodedArchivePayload) async {
        guard let restorer else {
            problem = .restoreFailed
            phase = .idle
            return
        }

        do {
            let receipt = try await restorer.restore(staged)
            passphrase = ""
            releaseFile()
            phase = .restored
            onRestored(receipt)
        } catch {
            problem = Problem(restore: error)
            phase = .idle
        }
    }

    private func dropPendingRestore() {
        pendingRestore = nil
        isConfirmationPresented = false
    }

    // MARK: - Leaving

    /// The back chevron. Not while a restore is running: the replace cannot be
    /// abandoned halfway, and leaving would hide how it ended.
    func close() {
        guard phase != .restoring else { return }
        discardSecrets()
        onClose()
    }

    /// Clears the passphrase and the opened backup and lets go of the file,
    /// without reporting a close — for the screen going away by any other
    /// route.
    func discardSecrets() {
        passphrase = ""
        dropPendingRestore()
        if phase == .awaitingConfirmation { phase = .idle }
        releaseFile()
    }

    private func releaseFile() {
        if let accessedURL { fileAccess.end(accessedURL) }
        accessedURL = nil
    }

    // MARK: - Copy

    static let title = "Restore your data"
    static let prompt = "Enter the passphrase you created for it."
    static let helper = "Stabilyz cannot recover a forgotten passphrase."
    static let passphraseLabel = "Passphrase"
    static let restoreLabel = "Restore backup"
    static let restoringLabel = "Checking your backup…"
    static let chooseDifferentFileLabel = "Choose a different file"
    static let backLabel = "Back"

    static let replaceTitle = "Replace existing data?"
    static let replaceMessage =
        "Restoring this backup will replace your current walk history and baselines. Your current data on this device will be erased."
    static let replaceLabel = "Replace Data"
    static let exportFirstLabel = "Export Current Data First"
    static let keepLabel = "Keep Current Data"
}
