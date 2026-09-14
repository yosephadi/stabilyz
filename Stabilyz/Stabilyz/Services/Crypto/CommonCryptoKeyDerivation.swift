import CommonCrypto
import Foundation

/// The parameters the export archive derives its key with (docs/13 §13.1,
/// §13.2).
enum KeyDerivationPolicy {
    /// [PRD] A unique 16-byte random salt per export.
    static let saltByteCount = 16

    /// AES-256 (docs/13 §13.2 step 4).
    static let keyByteCount = 32

    /// [REC] docs/13 §13.2 calibrates to ~200–500 ms; this is the midpoint.
    ///
    /// Long enough to make each offline guess against a stolen file expensive,
    /// short enough that export and restore do not feel stuck to a user who
    /// has already waited through the passphrase screens.
    static let targetDuration: TimeInterval = 0.3

    /// The fewest iterations a calibration may ever return.
    ///
    /// **PROVISIONAL engineering choice** (docs/21 §21.2: "KDF iteration count
    /// — calibrate 200–500 ms"). docs/13 §13.2's ~300k starting point doubles
    /// as a floor, so a slow device or a failed calibration can make derivation
    /// *slower* but never *weaker*. The count actually used is stored in the
    /// archive header, so raising this later leaves old exports decryptable.
    static let minimumIterations = 300_000

    /// Passphrase length the calibration measures with. PBKDF2's per-iteration
    /// cost is independent of passphrase length below the HMAC block size, so
    /// any typical length gives the same answer.
    static let calibrationPassphraseByteCount = 32
}

/// Why a derivation was refused.
///
/// Every parameter case is a caller bug: the export flow always has a
/// non-empty passphrase and a 16-byte salt, and the import flow validates the
/// header before it gets here (docs/13 §13.4). They are mapped to user-facing
/// errors by the flow that knows which one it is — an export failure is not an
/// import failure (docs/15 §15.1).
enum KeyDerivationError: Error, Equatable {
    case emptyPassphrase
    case emptySalt
    /// PBKDF2 takes 1 ... `UInt32.max` rounds.
    case invalidIterationCount(Int)
    case invalidKeyLength(Int)
    /// CommonCrypto refused the derivation.
    case derivationFailed(status: Int32)
}

/// Production `KeyDerivation`: PBKDF2-HMAC-SHA256 via CommonCrypto
/// `CCKeyDerivationPBKDF` (docs/13 §13.2, ADR in docs/24).
///
/// A thin wrapper by design. The primitive, the PRF and the calibration are
/// all CommonCrypto's; this type only validates parameters and moves bytes.
/// No custom cryptographic primitives anywhere [PRD].
///
/// **Memory (docs/13 §13.3).** The passphrase is read in place, never copied,
/// and the derived key is returned as a fresh buffer the caller owns. Both
/// should be passed to `SecureBytes.zeroize` once the key has been used.
///
/// Derivation is deliberately slow (≈ `KeyDerivationPolicy.targetDuration`);
/// callers run it off the main actor (docs/14 §14.2).
struct CommonCryptoKeyDerivation: KeyDerivation {
    init() {}

    func deriveKey(
        passphrase: [UInt8],
        salt: [UInt8],
        iterations: Int,
        keyByteCount: Int
    ) throws -> [UInt8] {
        guard !passphrase.isEmpty else { throw KeyDerivationError.emptyPassphrase }
        guard !salt.isEmpty else { throw KeyDerivationError.emptySalt }
        guard (1...Int(UInt32.max)).contains(iterations) else {
            throw KeyDerivationError.invalidIterationCount(iterations)
        }
        guard keyByteCount > 0 else { throw KeyDerivationError.invalidKeyLength(keyByteCount) }

        var derived = [UInt8](repeating: 0, count: keyByteCount)
        let status = passphrase.withUnsafeBytes { passphraseBytes in
            salt.withUnsafeBufferPointer { saltBytes in
                derived.withUnsafeMutableBufferPointer { derivedBytes in
                    // The passphrase goes in with its length, so an embedded
                    // zero byte is passphrase, not a C string terminator.
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passphraseBytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                        passphraseBytes.count,
                        saltBytes.baseAddress,
                        saltBytes.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedBytes.baseAddress,
                        derivedBytes.count
                    )
                }
            }
        }

        guard status == Int32(kCCSuccess) else {
            SecureBytes.zeroize(&derived)
            throw KeyDerivationError.derivationFailed(status: status)
        }
        return derived
    }

    /// CommonCrypto's own calibration (`CCCalibratePBKDF`) for this device,
    /// never below `KeyDerivationPolicy.minimumIterations`.
    ///
    /// Measured with the archive's real shape — SHA-256 PRF, 16-byte salt,
    /// 32-byte key — so the time it aims for is the time export will take.
    func calibratedIterationCount(targetDuration: TimeInterval) -> Int {
        let floor = KeyDerivationPolicy.minimumIterations
        guard targetDuration.isFinite, targetDuration > 0 else { return floor }

        let milliseconds = (targetDuration * 1_000).rounded()
        guard milliseconds >= 1, milliseconds < Double(UInt32.max) else { return floor }

        let rounds = CCCalibratePBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            KeyDerivationPolicy.calibrationPassphraseByteCount,
            KeyDerivationPolicy.saltByteCount,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            KeyDerivationPolicy.keyByteCount,
            UInt32(milliseconds)
        )
        // CommonCrypto reports failure as -1, which arrives as UInt32.max.
        guard rounds != UInt32.max else { return floor }
        return max(Int(rounds), floor)
    }
}

/// How a passphrase becomes bytes, for export and restore alike
/// (docs/13 §13.2 step 2).
enum PassphraseEncoding {
    /// UTF-8 of `PassphrasePolicy.canonical`: edge whitespace trimmed, then NFC.
    ///
    /// An accented letter can be typed as one code point or as a letter plus a
    /// combining mark, depending on the keyboard. Swift compares the two as
    /// equal strings, but their UTF-8 differs — and so would the key. A restore
    /// on a new phone must not fail because of how an accent was entered, or
    /// because the keyboard added a space (trimmed both ways, decided
    /// 2026-09-15).
    static func bytes(from passphrase: String) -> [UInt8] {
        Array(PassphrasePolicy.canonical(passphrase).utf8)
    }
}

/// Clearing secrets from memory (docs/13 §13.3).
enum SecureBytes {
    /// Overwrites every byte with zero via `memset_s`, which the compiler is
    /// not permitted to optimize away the way it may drop a plain write to a
    /// buffer about to be freed.
    ///
    /// Clears this array's storage only. A copy made earlier — or a `String`
    /// the bytes came from, which cannot be zeroed at all — is outside its
    /// reach; docs/13 §13.3 accepts and documents that residual risk.
    static func zeroize(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            _ = memset_s(base, raw.count, 0, raw.count)
        }
    }

    /// The same, for `Data` — the serialized payload before sealing and the
    /// plaintext `open` returns (Task 10.1.2). Same limits: this buffer only.
    static func zeroize(_ data: inout Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            _ = memset_s(base, raw.count, 0, raw.count)
        }
    }
}
