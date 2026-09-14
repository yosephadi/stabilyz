import CryptoKit
import Foundation

/// AES-256-GCM's fixed sizes, as the export archive uses them (docs/13 §13.1,
/// §13.2 step 4).
enum EncryptionPolicy {
    /// [PRD] A random 12-byte nonce per seal.
    static let nonceByteCount = 12
    /// GCM's full 128-bit authentication tag.
    static let tagByteCount = 16
    /// AES-256. Equal to `KeyDerivationPolicy.keyByteCount` by construction —
    /// the derived key is this key — and a test holds the two together.
    static let keyByteCount = 32
}

/// One sealed message: the nonce it was sealed under, the ciphertext, and the
/// tag that authenticates both the ciphertext and any associated data.
///
/// Carried as three parts because the archive stores them in different places:
/// the nonce in the plaintext header, the tag appended to the ciphertext
/// (docs/13 §13.1). Nothing here is validated on construction — a payload read
/// back from a damaged file is still a payload, and `open` is where it gets a
/// typed answer.
struct EncryptedPayload: Sendable, Equatable {
    let nonce: Data
    let ciphertext: Data
    let tag: Data

    init(nonce: Data, ciphertext: Data, tag: Data) {
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }

    /// `nonce ‖ ciphertext ‖ tag` — CryptoKit's combined layout.
    var combined: Data { nonce + ciphertext + tag }

    /// Splits CryptoKit's combined layout.
    ///
    /// - Throws: `EncryptionError.corruptedPayload` when the data is too short
    ///   to hold a nonce and a tag at all.
    init(combined: Data) throws {
        let overhead = EncryptionPolicy.nonceByteCount + EncryptionPolicy.tagByteCount
        guard combined.count >= overhead else { throw EncryptionError.corruptedPayload }

        let start = combined.startIndex
        let ciphertextStart = start + EncryptionPolicy.nonceByteCount
        let tagStart = combined.endIndex - EncryptionPolicy.tagByteCount
        self.nonce = Data(combined[start..<ciphertextStart])
        self.ciphertext = Data(combined[ciphertextStart..<tagStart])
        self.tag = Data(combined[tagStart...])
    }
}

/// Why a seal or open did not complete.
///
/// Typed so the archive layer (Task 10.1.3) can tell a damaged file from a
/// failed check without inspecting CryptoKit errors, and map each to the
/// user-facing error its flow calls for (docs/13 §13.4, docs/15 §15.1).
enum EncryptionError: Error, Equatable {
    /// The key is not AES-256. CryptoKit would accept 128 and 192 bits; the
    /// archive never uses them.
    case invalidKeyLength(bitCount: Int)
    /// The nonce is not exactly 12 bytes. CryptoKit accepts longer nonces; the
    /// archive format fixes the length.
    case invalidNonce
    /// The random source could not supply a nonce. Nothing was sealed.
    case nonceGenerationFailed
    /// The payload cannot be a sealed message at all — a tag of the wrong
    /// length, or combined data too short to hold a nonce and a tag.
    case corruptedPayload
    /// The tag did not verify. A tampered ciphertext, tag or nonce, the wrong
    /// key, or the wrong associated data all land here, and GCM deliberately
    /// cannot say which. No plaintext is released.
    case authenticationFailed
    /// CryptoKit refused to seal.
    case encryptionFailed
}

/// Authenticated symmetric encryption (docs/13 §13.2 step 4, Task 10.1.2).
///
/// Encryption and decryption only. The archive envelope — header, KDF
/// parameters, key-check value, payload serialization — is
/// `SecureArchiveCoding`'s, built on top of this in Task 10.1.3.
protocol SymmetricEncryptionService: Sendable {
    /// Seals `plaintext` under a fresh random nonce.
    ///
    /// - Parameter additionalData: authenticated but not encrypted. It must be
    ///   supplied again, byte for byte, to open. GCM treats empty associated
    ///   data exactly as none.
    func seal(
        _ plaintext: Data,
        using key: SymmetricKey,
        authenticating additionalData: Data?
    ) throws -> EncryptedPayload

    /// Verifies the tag and, only if it verifies, returns the plaintext.
    func open(
        _ payload: EncryptedPayload,
        using key: SymmetricKey,
        authenticating additionalData: Data?
    ) throws -> Data
}
