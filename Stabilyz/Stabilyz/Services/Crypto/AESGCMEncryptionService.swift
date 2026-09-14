import CryptoKit
import Foundation

/// Production `SymmetricEncryptionService`: AES-256-GCM via CryptoKit
/// (docs/13 §13.2 step 4, ADR in docs/24).
///
/// A thin wrapper by design. The cipher, the tag check and the constant-time
/// comparison are all CryptoKit's; this type fixes the parameters the archive
/// requires, takes its nonce from the injected `RandomSource`, and turns
/// CryptoKit's errors into `EncryptionError`. No custom cryptographic
/// primitives anywhere [PRD].
///
/// **Where it is stricter than CryptoKit.** CryptoKit seals with 128- and
/// 192-bit keys and accepts nonces longer than 12 bytes. The archive format
/// fixes both, so both are refused here rather than producing an archive no
/// other reader of the format expects.
///
/// **Memory (docs/13 §13.3).** Plaintext is read in place and never copied;
/// the only plaintext this type produces is the buffer `open` returns, which
/// the caller owns and should pass to `SecureBytes.zeroize` once used. Key
/// bytes live inside `SymmetricKey`, which CryptoKit keeps in its own storage;
/// `key(consuming:)` wipes the derived bytes a key was made from.
struct AESGCMEncryptionService: SymmetricEncryptionService {
    private let randomSource: RandomSource

    /// - Parameter randomSource: where nonces come from. The system CSPRNG in
    ///   production; injected so tests can pin a nonce (docs/12 §12.2). Never
    ///   give a production caller a source that can repeat — a repeated nonce
    ///   under one key breaks GCM's confidentiality and authenticity both.
    init(randomSource: RandomSource = SystemRandomSource()) {
        self.randomSource = randomSource
    }

    func seal(
        _ plaintext: Data,
        using key: SymmetricKey,
        authenticating additionalData: Data?
    ) throws -> EncryptedPayload {
        try Self.requireAES256(key)

        let nonceBytes: [UInt8]
        do {
            nonceBytes = try randomSource.bytes(count: EncryptionPolicy.nonceByteCount)
        } catch {
            throw EncryptionError.nonceGenerationFailed
        }
        let nonce = try Self.nonce(from: Data(nonceBytes))

        let box: AES.GCM.SealedBox
        do {
            if let additionalData {
                box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: additionalData)
            } else {
                box = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
            }
        } catch {
            throw EncryptionError.encryptionFailed
        }

        return EncryptedPayload(nonce: Data(nonceBytes), ciphertext: box.ciphertext, tag: box.tag)
    }

    func open(
        _ payload: EncryptedPayload,
        using key: SymmetricKey,
        authenticating additionalData: Data?
    ) throws -> Data {
        try Self.requireAES256(key)
        let nonce = try Self.nonce(from: payload.nonce)
        guard payload.tag.count == EncryptionPolicy.tagByteCount else {
            throw EncryptionError.corruptedPayload
        }

        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: payload.ciphertext, tag: payload.tag)
        } catch {
            throw EncryptionError.corruptedPayload
        }

        // `AES.GCM.open` verifies the tag before it returns anything, so a
        // failed check releases no plaintext, partial or otherwise.
        do {
            if let additionalData {
                return try AES.GCM.open(box, using: key, authenticating: additionalData)
            }
            return try AES.GCM.open(box, using: key)
        } catch CryptoKitError.authenticationFailure {
            throw EncryptionError.authenticationFailed
        } catch {
            throw EncryptionError.corruptedPayload
        }
    }

    /// A CryptoKit key from derived key bytes, wiping the bytes whether or not
    /// they were usable.
    ///
    /// The bridge from `KeyDerivation` (which returns `[UInt8]`) to this
    /// service: once the key exists the raw bytes are no longer needed, and
    /// leaving them in an array until it happens to be freed is the exposure
    /// docs/13 §13.3 asks to bound.
    static func key(consuming bytes: inout [UInt8]) throws -> SymmetricKey {
        defer { SecureBytes.zeroize(&bytes) }
        guard bytes.count == EncryptionPolicy.keyByteCount else {
            throw EncryptionError.invalidKeyLength(bitCount: bytes.count * 8)
        }
        return SymmetricKey(data: bytes)
    }

    private static func requireAES256(_ key: SymmetricKey) throws {
        guard key.bitCount == EncryptionPolicy.keyByteCount * 8 else {
            throw EncryptionError.invalidKeyLength(bitCount: key.bitCount)
        }
    }

    private static func nonce(from data: Data) throws -> AES.GCM.Nonce {
        guard data.count == EncryptionPolicy.nonceByteCount else { throw EncryptionError.invalidNonce }
        do {
            return try AES.GCM.Nonce(data: data)
        } catch {
            throw EncryptionError.invalidNonce
        }
    }
}
