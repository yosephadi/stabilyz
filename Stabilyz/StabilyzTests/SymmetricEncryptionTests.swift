import CryptoKit
import Foundation
import Testing
@testable import Stabilyz

/// AES-256-GCM (Task 10.1.2, docs/13 §13.2 step 4, docs/19 crypto row).

// MARK: - Doubles

/// Hands back the same bytes every time, and remembers what was asked for.
/// Tests only: a repeating nonce source is exactly what production must never
/// have.
private final class FixedRandomSource: RandomSource, @unchecked Sendable {
    let bytes: [UInt8]
    let requests = Locked<[Int]>([])

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    func bytes(count: Int) throws -> [UInt8] {
        requests.withLock { $0.append(count) }
        return bytes
    }
}

private struct FailingRandomSource: RandomSource {
    func bytes(count: Int) throws -> [UInt8] {
        throw StabilyzError.crypto(.randomGenerationFailed)
    }
}

// MARK: - Helpers

private func hex(_ string: String) -> Data {
    var data = Data()
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        data.append(UInt8(string[index..<next], radix: 16)!)
        index = next
    }
    return data
}

private func flippingBit(_ data: Data, at offset: Int) -> Data {
    var copy = data
    copy[copy.startIndex + offset] ^= 0x01
    return copy
}

private let service = AESGCMEncryptionService()
private let key = SymmetricKey(size: .bits256)
private let plaintext = Data("profile, sessions, baselines".utf8)
private let context = Data("STBLYZ header v1".utf8)

// MARK: - Known answers

/// McGrew & Viega's GCM specification, test cases 13–16 (the AES-256 cases).
/// Expected values were computed independently with OpenSSL through
/// pyca/cryptography, not with CryptoKit, and match the published ones.
@Test func matchesTheGCMSpecificationVectors() throws {
    let key0 = SymmetricKey(data: hex(String(repeating: "00", count: 32)))
    let nonce0 = hex(String(repeating: "00", count: 12))
    let keyF = SymmetricKey(data: hex("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308"))
    let nonceF = hex("cafebabefacedbaddecaf888")
    let p15 = hex("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255")
    let c15 = hex("522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662898015ad")

    let cases: [(name: String, key: SymmetricKey, nonce: Data, plaintext: Data, aad: Data?, ciphertext: Data, tag: Data)] = [
        ("13", key0, nonce0, Data(), nil, Data(), hex("530f8afbc74536b9a963b4f1c4cb738b")),
        ("14", key0, nonce0, Data(count: 16), nil, hex("cea7403d4d606b6e074ec5d3baf39d18"), hex("d0d1c8a799996bf0265b98b5d48ab919")),
        ("15", keyF, nonceF, p15, nil, c15, hex("b094dac5d93471bdec1a502270e3cc6c")),
        ("16", keyF, nonceF, p15.prefix(60), hex("feedfacedeadbeeffeedfacedeadbeefabaddad2"),
         c15.prefix(60), hex("76fc6ece0f4e1768cddf8853bb2d551b"))
    ]

    for vector in cases {
        let pinned = AESGCMEncryptionService(randomSource: FixedRandomSource(Array(vector.nonce)))
        let sealed = try pinned.seal(vector.plaintext, using: vector.key, authenticating: vector.aad)

        #expect(sealed.nonce == vector.nonce, "test case \(vector.name)")
        #expect(sealed.ciphertext == vector.ciphertext, "test case \(vector.name)")
        #expect(sealed.tag == vector.tag, "test case \(vector.name)")
        #expect(try pinned.open(sealed, using: vector.key, authenticating: vector.aad) == vector.plaintext,
                "test case \(vector.name)")
    }
}

// MARK: - Round trips

@Test func aRoundTripWithAssociatedDataReturnsThePlaintext() throws {
    let sealed = try service.seal(plaintext, using: key, authenticating: context)
    #expect(sealed.ciphertext != plaintext)
    #expect(try service.open(sealed, using: key, authenticating: context) == plaintext)
}

@Test func aRoundTripWithoutAssociatedDataReturnsThePlaintext() throws {
    let sealed = try service.seal(plaintext, using: key, authenticating: nil)
    #expect(try service.open(sealed, using: key, authenticating: nil) == plaintext)
}

@Test func emptyAndLargePlaintextsRoundTrip() throws {
    let empty = try service.seal(Data(), using: key, authenticating: context)
    #expect(empty.ciphertext.isEmpty)
    #expect(try service.open(empty, using: key, authenticating: context) == Data())

    let large = Data((0..<1_000_000).map { UInt8($0 % 251) })
    let sealed = try service.seal(large, using: key, authenticating: context)
    #expect(sealed.ciphertext.count == large.count)
    #expect(try service.open(sealed, using: key, authenticating: context) == large)
}

@Test func theCombinedLayoutRoundTrips() throws {
    let sealed = try service.seal(plaintext, using: key, authenticating: context)
    let combined = sealed.combined

    #expect(combined.count == 12 + plaintext.count + 16)
    #expect(combined.prefix(12) == sealed.nonce)
    #expect(combined.suffix(16) == sealed.tag)

    let parsed = try EncryptedPayload(combined: combined)
    #expect(parsed == sealed)
    #expect(try service.open(parsed, using: key, authenticating: context) == plaintext)
}

// MARK: - Tampering is refused

@Test func aFlippedBitAnywhereInTheCiphertextFailsAuthentication() throws {
    let sealed = try service.seal(plaintext, using: key, authenticating: context)

    for offset in [0, sealed.ciphertext.count / 2, sealed.ciphertext.count - 1] {
        let tampered = EncryptedPayload(
            nonce: sealed.nonce,
            ciphertext: flippingBit(sealed.ciphertext, at: offset),
            tag: sealed.tag
        )
        #expect(throws: EncryptionError.authenticationFailed) {
            _ = try service.open(tampered, using: key, authenticating: context)
        }
    }
}

@Test func aTamperedTagFailsAuthentication() throws {
    let sealed = try service.seal(plaintext, using: key, authenticating: context)

    for offset in [0, 15] {
        let tampered = EncryptedPayload(nonce: sealed.nonce, ciphertext: sealed.ciphertext, tag: flippingBit(sealed.tag, at: offset))
        #expect(throws: EncryptionError.authenticationFailed) {
            _ = try service.open(tampered, using: key, authenticating: context)
        }
    }
}

@Test func aTamperedNonceFailsAuthentication() throws {
    let sealed = try service.seal(plaintext, using: key, authenticating: context)
    let tampered = EncryptedPayload(nonce: flippingBit(sealed.nonce, at: 0), ciphertext: sealed.ciphertext, tag: sealed.tag)

    #expect(throws: EncryptionError.authenticationFailed) {
        _ = try service.open(tampered, using: key, authenticating: context)
    }
}

@Test func associatedDataThatDoesNotMatchFailsAuthentication() throws {
    let withContext = try service.seal(plaintext, using: key, authenticating: context)

    // Different associated data.
    #expect(throws: EncryptionError.authenticationFailed) {
        _ = try service.open(withContext, using: key, authenticating: Data("STBLYZ header v2".utf8))
    }
    // Sealed with it, opened without.
    #expect(throws: EncryptionError.authenticationFailed) {
        _ = try service.open(withContext, using: key, authenticating: nil)
    }
    // Sealed without, opened with.
    let withoutContext = try service.seal(plaintext, using: key, authenticating: nil)
    #expect(throws: EncryptionError.authenticationFailed) {
        _ = try service.open(withoutContext, using: key, authenticating: context)
    }
}

@Test func theWrongKeyFailsAuthentication() throws {
    let sealed = try service.seal(plaintext, using: key, authenticating: context)

    #expect(throws: EncryptionError.authenticationFailed) {
        _ = try service.open(sealed, using: SymmetricKey(size: .bits256), authenticating: context)
    }
}

@Test func emptyAssociatedDataIsTheSameAsNone() throws {
    // A GCM property, pinned so the archive layer cannot rely on telling the
    // two apart.
    let sealed = try service.seal(plaintext, using: key, authenticating: Data())
    #expect(try service.open(sealed, using: key, authenticating: nil) == plaintext)
}

// MARK: - Nonces

@Test func everySealDrawsAFreshNonce() throws {
    let sealed = try (0..<64).map { _ in try service.seal(plaintext, using: key, authenticating: context) }

    #expect(sealed.allSatisfy { $0.nonce.count == 12 })
    #expect(Set(sealed.map(\.nonce)).count == sealed.count)
    // The same plaintext under the same key never produces the same ciphertext.
    #expect(Set(sealed.map(\.ciphertext)).count == sealed.count)
}

@Test func theNonceComesFromTheInjectedRandomSource() throws {
    let nonce: [UInt8] = Array(0..<12)
    let source = FixedRandomSource(nonce)
    let sealed = try AESGCMEncryptionService(randomSource: source).seal(plaintext, using: key, authenticating: nil)

    #expect(sealed.nonce == Data(nonce))
    #expect(source.requests.withLock { $0 } == [12])
}

@Test func aRandomSourceThatFailsSealsNothing() {
    #expect(throws: EncryptionError.nonceGenerationFailed) {
        _ = try AESGCMEncryptionService(randomSource: FailingRandomSource()).seal(plaintext, using: key, authenticating: nil)
    }
}

@Test func aNonceOfTheWrongLengthIsRefused() throws {
    // CryptoKit itself would accept the 13-byte one.
    for length in [11, 13] {
        #expect(throws: EncryptionError.invalidNonce) {
            _ = try AESGCMEncryptionService(randomSource: FixedRandomSource(Array(repeating: 7, count: length)))
                .seal(plaintext, using: key, authenticating: nil)
        }
    }

    let sealed = try service.seal(plaintext, using: key, authenticating: nil)
    for nonce in [sealed.nonce.prefix(11), sealed.nonce + Data([0])] {
        #expect(throws: EncryptionError.invalidNonce) {
            _ = try service.open(EncryptedPayload(nonce: Data(nonce), ciphertext: sealed.ciphertext, tag: sealed.tag),
                                 using: key, authenticating: nil)
        }
    }
}

// MARK: - Malformed input

@Test func onlyAES256KeysAreAccepted() throws {
    // CryptoKit would seal with both.
    for size in [SymmetricKeySize.bits128, .bits192] {
        let shortKey = SymmetricKey(size: size)
        #expect(throws: EncryptionError.invalidKeyLength(bitCount: size.bitCount)) {
            _ = try service.seal(plaintext, using: shortKey, authenticating: nil)
        }
    }

    let sealed = try service.seal(plaintext, using: key, authenticating: nil)
    #expect(throws: EncryptionError.invalidKeyLength(bitCount: 128)) {
        _ = try service.open(sealed, using: SymmetricKey(size: .bits128), authenticating: nil)
    }
}

@Test func aTagOfTheWrongLengthIsACorruptedPayload() throws {
    let sealed = try service.seal(plaintext, using: key, authenticating: nil)

    for tag in [sealed.tag.prefix(15), sealed.tag + Data([0])] {
        #expect(throws: EncryptionError.corruptedPayload) {
            _ = try service.open(EncryptedPayload(nonce: sealed.nonce, ciphertext: sealed.ciphertext, tag: Data(tag)),
                                 using: key, authenticating: nil)
        }
    }
}

@Test func combinedDataTooShortForANonceAndTagIsACorruptedPayload() {
    for count in [0, 12, 27] {
        #expect(throws: EncryptionError.corruptedPayload) {
            _ = try EncryptedPayload(combined: Data(count: count))
        }
    }
}

// MARK: - Keys and memory

@Test func derivedKeyBytesAreWipedOnceTheyBecomeAKey() throws {
    var bytes: [UInt8] = Array(1...32)
    let made = try AESGCMEncryptionService.key(consuming: &bytes)

    #expect(made.bitCount == 256)
    #expect(bytes == [UInt8](repeating: 0, count: 32))
}

@Test func unusableKeyBytesAreWipedToo() {
    var bytes: [UInt8] = Array(1...31)
    #expect(throws: EncryptionError.invalidKeyLength(bitCount: 248)) {
        _ = try AESGCMEncryptionService.key(consuming: &bytes)
    }
    #expect(bytes == [UInt8](repeating: 0, count: 31))
}

@Test func zeroizingDataClearsEveryByte() {
    var secret = Data([0xDE, 0xAD, 0xBE, 0xEF])
    SecureBytes.zeroize(&secret)
    #expect(secret == Data(count: 4))

    var empty = Data()
    SecureBytes.zeroize(&empty)
    #expect(empty.isEmpty)
}

@Test func thePolicyMatchesTheFormatAndTheDerivedKey() {
    #expect(EncryptionPolicy.nonceByteCount == 12)
    #expect(EncryptionPolicy.tagByteCount == 16)
    // The KDF's output is this cipher's key.
    #expect(EncryptionPolicy.keyByteCount == KeyDerivationPolicy.keyByteCount)
}

// MARK: - With the key derivation

@Test func aPassphraseDerivedKeySealsAndOnlyThatPassphraseOpens() throws {
    let kdf = CommonCryptoKeyDerivation()
    let salt = try SystemRandomSource().bytes(count: KeyDerivationPolicy.saltByteCount)

    func key(for passphrase: String) throws -> SymmetricKey {
        var bytes = try kdf.deriveKey(
            passphrase: PassphraseEncoding.bytes(from: passphrase),
            salt: salt,
            iterations: 1_000,
            keyByteCount: KeyDerivationPolicy.keyByteCount
        )
        return try AESGCMEncryptionService.key(consuming: &bytes)
    }

    let sealed = try service.seal(plaintext, using: try key(for: "correct horse"), authenticating: context)
    #expect(try service.open(sealed, using: try key(for: "correct horse"), authenticating: context) == plaintext)
    #expect(throws: EncryptionError.authenticationFailed) {
        _ = try service.open(sealed, using: try key(for: "wrong horse"), authenticating: context)
    }
}
