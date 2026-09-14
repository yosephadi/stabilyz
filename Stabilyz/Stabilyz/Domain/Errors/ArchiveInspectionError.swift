/// Why an export file could not be staged for restore (docs/13 §13.4, docs/15
/// §15.1, Task 10.3.1).
///
/// The restore flow's own vocabulary: one case per thing it has to tell apart.
/// Each maps onto the app-wide `StabilyzError` taxonomy (`stabilyzError`),
/// whose `ErrorPresenter` copy is what the person sees — so a restore failure
/// reads exactly like every other surface's description of the same problem.
///
/// **Every case guarantees the store was not touched.** Inspection reads a file
/// and nothing else.
enum ArchiveInspectionError: Error, Equatable {
    /// The file could not be read at all.
    case unreadableFile
    /// No Stabilyz magic: some other file was picked.
    case notAStabilyzArchive
    /// Truncated, malformed, tampered with or damaged — including a header
    /// edited after export and a ciphertext that fails its tag.
    case invalidArchiveFormat
    /// The key-check value did not open under this passphrase.
    case wrongPassphrase
    /// Decrypted fine, but written with a newer payload schema.
    case unsupportedSchemaVersion(Int)
    /// A newer envelope or crypto suite this build does not read.
    case unsupportedEnvelopeVersion(Int)
    /// More PBKDF2 iterations than `ArchiveFormat.maximumIterations`, refused
    /// before any derivation.
    case unsupportedIterationCount(Int)

    /// From the coder's `StabilyzError`. Anything outside the import taxonomy
    /// is a file this build cannot interpret, and is reported as such.
    init(_ error: StabilyzError) {
        switch error {
        case .archiveImport(.wrongPassphrase): self = .wrongPassphrase
        case .archiveImport(.corruptedArchive): self = .invalidArchiveFormat
        case .archiveImport(.notAStabilyzArchive): self = .notAStabilyzArchive
        case .archiveImport(.unreadableFile): self = .unreadableFile
        case .schemaCompatibility(.futureSchema(let version)): self = .unsupportedSchemaVersion(version)
        case .schemaCompatibility(.unsupportedEnvelope(let version)): self = .unsupportedEnvelopeVersion(version)
        case .schemaCompatibility(.unsupportedIterationCount(let count)): self = .unsupportedIterationCount(count)
        case .archiveImport(.restoreFailed), .archiveImport(.restoreIncomplete):
            // Restore-execution outcomes (Task 10.3.4); inspection never
            // produces them, and cannot have got as far as touching the store.
            self = .invalidArchiveFormat
        case .permission, .sensor, .recording, .processing, .persistence, .export, .audio, .crypto:
            self = .invalidArchiveFormat
        }
    }

    /// The app-wide error this is, for presentation and logging.
    var stabilyzError: StabilyzError {
        switch self {
        case .unreadableFile: .archiveImport(.unreadableFile)
        case .notAStabilyzArchive: .archiveImport(.notAStabilyzArchive)
        case .invalidArchiveFormat: .archiveImport(.corruptedArchive)
        case .wrongPassphrase: .archiveImport(.wrongPassphrase)
        case .unsupportedSchemaVersion(let version): .schemaCompatibility(.futureSchema(version: version))
        case .unsupportedEnvelopeVersion(let version): .schemaCompatibility(.unsupportedEnvelope(version: version))
        case .unsupportedIterationCount(let count): .schemaCompatibility(.unsupportedIterationCount(count: count))
        }
    }
}
