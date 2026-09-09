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

/// Seals and opens the export archive envelope (docs/13 §13.1, §13.2, §13.4).
///
/// The production implementation is AES-256-GCM via CryptoKit with a random
/// 12-byte nonce and a unique 16-byte salt per export. Conformers serialize
/// crypto work off the main actor (docs/14 §14.2).
///
/// `open` performs decryption ONLY. Schema/version/integrity validation and any
/// local data mutation happen after it returns, in the fixed order required by
/// docs/13 §13.4 — nothing local is touched before validation completes.
protocol SecureArchiveCoding: Sendable {
    /// Returns the complete archive: plaintext header + ciphertext. No plaintext
    /// temp file is ever written (docs/13 §13.2 step 5).
    func seal(payload: Data, passphrase: [UInt8]) async throws -> Data

    /// Returns the decrypted payload bytes for the caller to validate.
    func open(archive: Data, passphrase: [UInt8]) async throws -> Data
}
