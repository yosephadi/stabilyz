import Foundation

/// Password-based key derivation
/// (docs/13-data-export-encryption-restore-architecture.md §13.2).
///
/// The production implementation is PBKDF2-HMAC-SHA256 via CommonCrypto
/// `CCKeyDerivationPBKDF` — CryptoKit does not provide PBKDF2. No custom
/// cryptographic primitives anywhere [PRD].
///
/// The passphrase crosses this boundary as bytes, not a `String`, so it can be
/// zeroed after derivation (docs/13 §13.3).
protocol KeyDerivation: Sendable {
    func deriveKey(passphrase: [UInt8], salt: [UInt8], iterations: Int, keyByteCount: Int) throws -> [UInt8]

    /// Iteration count calibrated on-device to the target derivation time and
    /// stored in the archive header so old exports stay decryptable (docs/13 §13.2).
    func calibratedIterationCount(targetDuration: TimeInterval) -> Int
}

/// Writes and reads the export file (docs/13 §13.1–13.4).
///
/// The production implementation is `SecureArchiveCoder` (Task 10.1.3):
/// PBKDF2 key derivation with a fresh 16-byte salt, a key-check value, and an
/// AES-256-GCM-sealed JSON payload behind a self-describing header.
/// Conformers do their crypto work off the main actor (docs/14 §14.2).
///
/// `decode` decrypts and validates ONLY. It returns domain values and touches
/// no local data; replacing the store is the restore flow's, after it returns,
/// in the fixed order docs/13 §13.4 requires.
protocol SecureArchiveCoding: Sendable {
    /// Returns the complete export file: plaintext header + ciphertext. No
    /// plaintext is ever written anywhere (docs/13 §13.2 step 5).
    func encode(_ payload: ArchivePayload, passphrase: [UInt8], iterations: Int) async throws -> Data

    /// Decrypts, validates and migrates an export file.
    func decode(archiveData: Data, passphrase: [UInt8]) async throws -> DecodedArchivePayload
}
