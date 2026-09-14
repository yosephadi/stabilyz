import CryptoKit
import Foundation

/// Production `SecureArchiveCoding`: the export file, sealed and opened
/// (docs/13 §13.1–13.4, §13.6; Task 10.1.3).
///
/// Composed from the two vetted wrappers — `CommonCryptoKeyDerivation`
/// (PBKDF2-HMAC-SHA256) and `AESGCMEncryptionService` (AES-256-GCM). Nothing
/// cryptographic is implemented here [PRD]; this type fixes the file layout,
/// the order of operations, and what each failure means.
///
/// **Decode order is the PRD's** (docs/13 §13.4): parse the envelope — with
/// the iteration ceiling — before deriving anything; derive; open the key-check
/// (wrong passphrase); open the payload (damaged file); only then read the
/// schema version, migrate, verify the digest and completeness. Nothing local
/// is touched at any point; that is the restore flow's, after this returns.
///
/// **Memory (docs/13 §13.3).** Derived key bytes are wiped as soon as they
/// become a key. The serialized payload and the decrypted document are wiped
/// when the call ends. `Data` shares storage with any copy still alive, and
/// `JSONEncoder`/`JSONDecoder` keep buffers of their own, so this bounds
/// exposure rather than eliminating it — the residual risk docs/13 §13.3
/// accepts.
struct SecureArchiveCoder: SecureArchiveCoding {
    private let keyDerivation: KeyDerivation
    private let encryption: SymmetricEncryptionService
    private let randomSource: RandomSource
    private let minimumEncodeIterations: Int
    private let writtenSchemaVersion: Int
    private let migrations: ArchiveMigrations

    /// - Parameters:
    ///   - minimumEncodeIterations: the fewest iterations an export may be
    ///     written with. Production uses the KDF policy's floor; tests lower it
    ///     so a round trip does not cost a third of a second.
    ///   - writtenSchemaVersion: the schema this coder writes. Only a test
    ///     writes anything but the current one, to make a "future" archive.
    init(
        keyDerivation: KeyDerivation = CommonCryptoKeyDerivation(),
        encryption: SymmetricEncryptionService = AESGCMEncryptionService(),
        randomSource: RandomSource = SystemRandomSource(),
        minimumEncodeIterations: Int = KeyDerivationPolicy.minimumIterations,
        writtenSchemaVersion: Int = ArchiveFormat.schemaVersion,
        migrations: ArchiveMigrations = .production
    ) {
        self.keyDerivation = keyDerivation
        self.encryption = encryption
        self.randomSource = randomSource
        self.minimumEncodeIterations = minimumEncodeIterations
        self.writtenSchemaVersion = writtenSchemaVersion
        self.migrations = migrations
    }

    // MARK: - Encode

    /// Seals `payload` into a complete export file.
    ///
    /// The salt is drawn here, never supplied: a unique salt per export is a
    /// [PRD] requirement, and a caller cannot reuse what it never holds.
    ///
    /// - Parameter iterations: the calibrated count
    ///   (`KeyDerivation.calibratedIterationCount`), clamped by the caller to
    ///   `ArchiveFormat.maximumIterations`. Written into the header, so the
    ///   file stays decryptable whatever a later build calibrates to.
    func encode(_ payload: ArchivePayload, passphrase: [UInt8], iterations: Int) async throws -> Data {
        guard !passphrase.isEmpty else { throw ArchiveEncodingError.emptyPassphrase }
        guard (minimumEncodeIterations...ArchiveFormat.maximumIterations).contains(iterations) else {
            throw ArchiveEncodingError.iterationsOutOfRange(iterations)
        }
        guard (1...ArchiveFormat.maximumAlgorithmVersionByteCount).contains(payload.algorithmVersion.utf8.count) else {
            throw ArchiveEncodingError.invalidAlgorithmVersion
        }
        if let inconsistency = payload.inconsistency { throw inconsistency }

        let salt: [UInt8]
        do {
            salt = try randomSource.bytes(count: KeyDerivationPolicy.saltByteCount)
        } catch {
            throw ArchiveEncodingError.randomGenerationFailed
        }
        guard salt.count == KeyDerivationPolicy.saltByteCount else {
            throw ArchiveEncodingError.randomGenerationFailed
        }

        let key: SymmetricKey
        do {
            var keyBytes = try keyDerivation.deriveKey(
                passphrase: passphrase,
                salt: salt,
                iterations: iterations,
                keyByteCount: KeyDerivationPolicy.keyByteCount
            )
            key = try AESGCMEncryptionService.key(consuming: &keyBytes)
        } catch {
            throw ArchiveEncodingError.keyDerivationFailed
        }

        var body: Data
        do {
            body = try ArchiveJSON.encoder().encode(ArchiveBody(
                profile: ArchivedProfile(payload.profile),
                baselines: payload.baselines.map(ArchivedBaseline.init),
                sessions: payload.sessions.compactMap(ArchivedSession.init),
                preferences: ArchivedPreferences()
            ))
        } catch {
            throw ArchiveEncodingError.serializationFailed
        }
        defer { SecureBytes.zeroize(&body) }

        var document: Data
        do {
            document = try ArchiveJSON.encoder().encode(ArchiveDocument(
                schemaVersion: writtenSchemaVersion,
                appVersion: payload.appVersion,
                algorithmVersion: payload.algorithmVersion,
                exportedAt: payload.exportedAt,
                bodySHA256: Self.sha256Hex(body),
                body: body
            ))
        } catch {
            throw ArchiveEncodingError.serializationFailed
        }
        defer { SecureBytes.zeroize(&document) }

        let keyCheck = try seal(ArchiveFormat.keyCheckPlaintext, key: key, authenticating: nil)
        let header = ArchiveHeader(
            envelopeVersion: ArchiveFormat.envelopeVersion,
            cryptoSuite: ArchiveFormat.cryptoSuite,
            schemaVersion: writtenSchemaVersion,
            algorithmVersion: payload.algorithmVersion,
            iterations: iterations,
            salt: salt,
            keyCheck: keyCheck
        )
        let authenticatedHeader = try header.serialized()

        let sealed = try seal(document, key: key, authenticating: authenticatedHeader)
        guard sealed.nonce != keyCheck.nonce else { throw ArchiveEncodingError.nonceCollision }

        return ArchiveEnvelope(header: header, authenticatedHeader: authenticatedHeader, payload: sealed).serialized
    }

    private func seal(_ plaintext: Data, key: SymmetricKey, authenticating associated: Data?) throws -> EncryptedPayload {
        do {
            return try encryption.seal(plaintext, using: key, authenticating: associated)
        } catch EncryptionError.nonceGenerationFailed {
            throw ArchiveEncodingError.randomGenerationFailed
        } catch {
            throw ArchiveEncodingError.encryptionFailed
        }
    }

    // MARK: - Decode

    /// Decrypts and validates an export file. Touches nothing local.
    ///
    /// - Throws: a `StabilyzError` from the import taxonomy, each with its
    ///   plain-language copy already defined (docs/15 §15.1):
    ///   `.archiveImport(.notAStabilyzArchive)`,
    ///   `.schemaCompatibility(.unsupportedEnvelope)`,
    ///   `.archiveImport(.wrongPassphrase)`,
    ///   `.archiveImport(.corruptedArchive)`,
    ///   `.schemaCompatibility(.futureSchema)`.
    func decode(archiveData: Data, passphrase: [UInt8]) async throws -> DecodedArchivePayload {
        let corrupted = StabilyzError.archiveImport(.corruptedArchive)

        // 1. The envelope, iteration ceiling included — before any derivation.
        let envelope = try ArchiveEnvelope.parse(archiveData)
        let header = envelope.header

        // 2. The key.
        let key: SymmetricKey
        do {
            var keyBytes = try keyDerivation.deriveKey(
                passphrase: passphrase,
                salt: header.salt,
                iterations: header.iterations,
                keyByteCount: KeyDerivationPolicy.keyByteCount
            )
            key = try AESGCMEncryptionService.key(consuming: &keyBytes)
        } catch KeyDerivationError.emptyPassphrase {
            // No export is ever written with one, so it cannot be right.
            throw StabilyzError.archiveImport(.wrongPassphrase)
        } catch {
            throw corrupted
        }

        // 3. The key-check: the passphrase, proven before the payload.
        //    A key-check that fails to open reads as a wrong passphrase — and
        //    so does a tampered salt, iteration count or key-check, which are
        //    indistinguishable from one by construction.
        let check: Data
        do {
            check = try encryption.open(header.keyCheck, using: key, authenticating: nil)
        } catch EncryptionError.authenticationFailed {
            throw StabilyzError.archiveImport(.wrongPassphrase)
        } catch {
            throw corrupted
        }
        guard check == ArchiveFormat.keyCheckPlaintext else { throw corrupted }

        // 4. The payload. The passphrase is known good, so any failure here is
        //    a damaged or edited file — header bytes included.
        var plaintext: Data
        do {
            plaintext = try encryption.open(envelope.payload, using: key, authenticating: envelope.authenticatedHeader)
        } catch {
            throw corrupted
        }
        defer { SecureBytes.zeroize(&plaintext) }

        // 5. Versions — only now, after decryption [PRD]. The header's schema
        //    version is authenticated, so it can be trusted.
        let written = header.schemaVersion
        guard written >= 1 else { throw corrupted }
        guard written <= ArchiveFormat.schemaVersion else {
            throw StabilyzError.schemaCompatibility(.futureSchema(version: written))
        }
        var migrated = try migrations.migrate(plaintext, from: written, to: ArchiveFormat.schemaVersion)
        defer { SecureBytes.zeroize(&migrated) }

        // 6. Integrity and completeness.
        guard let document = try? ArchiveJSON.decoder().decode(ArchiveDocument.self, from: migrated),
              document.schemaVersion == ArchiveFormat.schemaVersion,
              document.algorithmVersion == header.algorithmVersion,
              Self.sha256Hex(document.body) == document.bodySHA256,
              let body = try? ArchiveJSON.decoder().decode(ArchiveBody.self, from: document.body)
        else { throw corrupted }

        let payload: ArchivePayload
        do {
            payload = ArchivePayload(
                profile: try body.profile.domain(),
                baselines: try body.baselines.map { try $0.domain() },
                sessions: body.sessions.map { $0.domain() },
                appVersion: document.appVersion,
                algorithmVersion: document.algorithmVersion,
                exportedAt: document.exportedAt
            )
        } catch {
            throw corrupted
        }
        guard payload.inconsistency == nil else { throw corrupted }

        return DecodedArchivePayload(payload: payload, schemaVersion: written)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
