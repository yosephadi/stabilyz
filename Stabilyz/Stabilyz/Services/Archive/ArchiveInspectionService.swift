import Foundation

/// Reads an export file into a validated staging model, touching nothing
/// (docs/13 §13.4, Task 10.3.1). Protocol-fronted so the restore flow is
/// testable without a file or a key derivation.
protocol ArchiveInspecting: Sendable {
    /// The file's structure only — magic, envelope, suite, field lengths, the
    /// iteration ceiling. No passphrase, no key derivation, no decryption.
    ///
    /// Lets the restore flow say "that isn't a Stabilyz backup" as soon as a
    /// file is picked, instead of after the person has typed a passphrase for
    /// it. It deliberately does **not** judge the header's schema version:
    /// that field is only trustworthy once decryption has authenticated it
    /// [PRD: decrypt before schema/version validation].
    func preflight(archiveAt url: URL) async throws
    func preflight(archiveData: Data) async throws

    /// Decrypts and validates, in the PRD's order, into a
    /// `DecodedArchivePayload` held in memory. Nothing is written anywhere.
    ///
    /// - Throws: `ArchiveInspectionError`.
    func inspect(archiveAt url: URL, passphrase: String) async throws -> DecodedArchivePayload
    func inspect(archiveData: Data, passphrase: String) async throws -> DecodedArchivePayload
}

/// Production `ArchiveInspecting` over `SecureArchiveCoder` (docs/13 §13.4).
///
/// **The order is the coder's, and it is the PRD's**: the envelope is parsed
/// — iteration ceiling included — before any key derivation; the passphrase is
/// proven against the key-check value before the payload is opened; the schema
/// version is read only after decryption; digest and completeness are checked
/// last. This type adds what a picked file needs on top: reading it, bounding
/// its size, canonicalizing the typed passphrase, and naming each failure in
/// the restore flow's terms.
///
/// **It cannot touch local data.** It holds no repository, store or writer —
/// only the coder and read access to the picked file. Replacing the store is
/// Task 10.3.4's, after a staged payload exists and the person has chosen to.
struct ArchiveInspectionService: ArchiveInspecting {
    /// The largest file inspection will read.
    ///
    /// **Engineering choice, not a format rule.** A real export is metrics
    /// only — years of daily walks come to a few megabytes — so this is far
    /// above anything genuine, and exists so a wrong pick (a video, a disk
    /// image) is refused before it is read into memory.
    static let maximumArchiveByteCount = 64 * 1_024 * 1_024

    private let coder: SecureArchiveCoding
    private let fileIO: FileIO
    private let logService: LogService
    private let maximumByteCount: Int

    init(
        coder: SecureArchiveCoding,
        fileIO: FileIO,
        logService: LogService,
        maximumByteCount: Int = Self.maximumArchiveByteCount
    ) {
        self.coder = coder
        self.fileIO = fileIO
        self.logService = logService
        self.maximumByteCount = maximumByteCount
    }

    // MARK: - Preflight

    func preflight(archiveAt url: URL) async throws {
        try await preflight(archiveData: try read(url))
    }

    func preflight(archiveData: Data) async throws {
        guard archiveData.count <= maximumByteCount else { throw fail(.invalidArchiveFormat) }
        do {
            _ = try ArchiveEnvelope.parse(archiveData)
        } catch let error as StabilyzError {
            throw fail(ArchiveInspectionError(error))
        } catch {
            throw fail(.invalidArchiveFormat)
        }
    }

    // MARK: - Inspect

    func inspect(archiveAt url: URL, passphrase: String) async throws -> DecodedArchivePayload {
        try await inspect(archiveData: try read(url), passphrase: passphrase)
    }

    func inspect(archiveData: Data, passphrase: String) async throws -> DecodedArchivePayload {
        guard archiveData.count <= maximumByteCount else { throw fail(.invalidArchiveFormat) }

        // The same canonical form export used: trimmed, then NFC (docs/13 §13.3).
        var passphraseBytes = PassphraseEncoding.bytes(from: passphrase)
        defer { SecureBytes.zeroize(&passphraseBytes) }

        do {
            let staged = try await coder.decode(archiveData: archiveData, passphrase: passphraseBytes)
            // Versions and counts only — never data or key material (docs/20).
            logService.log(
                .info, .backup,
                "restore inspection passed: schema v\(staged.schemaVersion) sessions=\(staged.payload.sessions.count) baselines=\(staged.payload.baselines.count)"
            )
            return staged
        } catch let error as StabilyzError {
            throw fail(ArchiveInspectionError(error))
        } catch {
            throw fail(.invalidArchiveFormat)
        }
    }

    // MARK: - Reading the file

    /// Reads a picked file, inside its security scope when it has one (a
    /// document-picker URL), and refuses one too large to be an export before
    /// reading it.
    private func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumByteCount {
            throw fail(.invalidArchiveFormat)
        }
        do {
            return try fileIO.read(from: url)
        } catch {
            throw fail(.unreadableFile)
        }
    }

    private func fail(_ error: ArchiveInspectionError) -> ArchiveInspectionError {
        logService.log(.error, .backup, "restore inspection refused: \(error.stabilyzError.technicalDescription)")
        return error
    }
}
