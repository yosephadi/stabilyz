import Foundation

/// Drives Restore your data (Figma 64:3890, docs/04 §4.1, docs/13 §13.4–13.5,
/// Task 10.3.2): a picked export, its passphrase, and the restore.
///
/// The screen opens on a file already chosen. Picking it runs the preflight at
/// once, so a file that is not a Stabilyz export — or one this build cannot
/// read — says so before anyone types a passphrase. Restore backup then
/// inspects with the passphrase and hands the staged payload to
/// `ArchiveRestoring`, which replaces the store atomically and broadcasts the
/// replacement; the app root re-resolves on that broadcast.
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
        /// Inspecting with the passphrase, then replacing the store.
        case restoring
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

    var onRestored: @MainActor (RestoreReceipt) -> Void
    var onClose: @MainActor () -> Void

    private let inspector: ArchiveInspecting
    private let restorer: ArchiveRestoring?
    private let fileAccess: SecurityScopedAccess
    private let logService: LogService

    /// The picked file this model currently holds security-scoped access to.
    private var accessedURL: URL?
    /// Bumped per selection, so a slow preflight for a file since swapped out
    /// cannot report on the file that replaced it.
    private var selection = 0

    /// - Parameter restorer: nil where there is no store to restore into (the
    ///   degraded graph); a restore attempt then reports `restoreFailed`.
    init(
        inspector: ArchiveInspecting,
        restorer: ArchiveRestoring?,
        fileAccess: SecurityScopedAccess,
        logService: LogService,
        onRestored: @escaping @MainActor (RestoreReceipt) -> Void = { _ in },
        onClose: @escaping @MainActor () -> Void = {}
    ) {
        self.inspector = inspector
        self.restorer = restorer
        self.fileAccess = fileAccess
        self.logService = logService
        self.onRestored = onRestored
        self.onClose = onClose
    }

    // MARK: - State

    var isWorking: Bool { phase == .checkingFile || phase == .restoring }

    var canRestore: Bool {
        guard file != nil, phase == .idle, problem?.isAboutTheFile != true else { return false }
        return !PassphrasePolicy.canonical(passphrase).isEmpty
    }

    var canChooseDifferentFile: Bool { !isWorking && phase != .restored }

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

    /// Inspects the file with the passphrase, then replaces the store.
    func restore() async {
        guard canRestore, let file else { return }
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

        guard let restorer else {
            logService.log(.error, .backup, "restore unavailable: no store to restore into")
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

    // MARK: - Leaving

    /// The back chevron. Not while a restore is running: the replace cannot be
    /// abandoned halfway, and leaving would hide how it ended.
    func close() {
        guard phase != .restoring else { return }
        discardSecrets()
        onClose()
    }

    /// Clears the passphrase and lets go of the file without reporting a
    /// close — for the screen going away by any other route.
    func discardSecrets() {
        passphrase = ""
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
}
