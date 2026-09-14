import Foundation
import Testing
@testable import Stabilyz

/// PBKDF2-HMAC-SHA256 and the system RNG (Task 10.1.1, docs/13 §13.2–13.3,
/// docs/19 crypto row).

private let kdf = CommonCryptoKeyDerivation()

private func hex(_ string: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        bytes.append(UInt8(string[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}

private func utf8(_ string: String) -> [UInt8] { Array(string.utf8) }

// MARK: - Known answers

/// Expected outputs computed independently with OpenSSL (Python `hashlib`),
/// not with the implementation under test. The last two are also RFC 7914
/// §11's published PBKDF2-HMAC-SHA256 vectors.
@Test func derivesTheIndependentlyComputedVectors() throws {
    let vectors: [(passphrase: [UInt8], salt: [UInt8], iterations: Int, key: String)] = [
        (utf8("password"), utf8("salt"), 1,
         "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"),
        (utf8("password"), utf8("salt"), 2,
         "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43"),
        (utf8("password"), utf8("salt"), 4096,
         "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a"),
        (utf8("passwordPASSWORDpassword"), utf8("saltSALTsaltSALTsaltSALTsaltSALTsalt"), 4096,
         "348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1c635518c7dac47e9"),
        (utf8("passwd"), utf8("salt"), 1,
         "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783"),
        (utf8("Password"), utf8("NaCl"), 80_000,
         "4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56a1d425a1225833549adb841b51c9b3176a272bdebba1d078478f62b397f33c8d")
    ]

    for vector in vectors {
        let expected = hex(vector.key)
        let derived = try kdf.deriveKey(
            passphrase: vector.passphrase,
            salt: vector.salt,
            iterations: vector.iterations,
            keyByteCount: expected.count
        )
        #expect(derived == expected, "iterations \(vector.iterations), \(expected.count)-byte key")
    }
}

@Test func aZeroByteInsideThePassphraseIsPassphraseNotATerminator() throws {
    // A wrapper that passed the passphrase as a C string would stop at the
    // zero byte and derive the key for "pass".
    let derived = try kdf.deriveKey(
        passphrase: [0x70, 0x61, 0x73, 0x73, 0x00, 0x77, 0x6f, 0x72, 0x64],
        salt: [0x73, 0x61, 0x00, 0x6c, 0x74],
        iterations: 4096,
        keyByteCount: 16
    )
    #expect(derived == hex("89b69d0516f829893c696226650a8687"))
}

// MARK: - Behaviour

@Test func theSameInputsAlwaysDeriveTheSameKey() throws {
    let salt = [UInt8](repeating: 7, count: KeyDerivationPolicy.saltByteCount)
    let first = try kdf.deriveKey(passphrase: utf8("correct horse"), salt: salt, iterations: 1_000, keyByteCount: 32)
    let second = try kdf.deriveKey(passphrase: utf8("correct horse"), salt: salt, iterations: 1_000, keyByteCount: 32)
    #expect(first == second)
}

@Test func aDifferentSaltOrCountDerivesADifferentKey() throws {
    let passphrase = utf8("correct horse")
    let saltA = [UInt8](repeating: 1, count: 16)
    let saltB = [UInt8](repeating: 2, count: 16)

    let base = try kdf.deriveKey(passphrase: passphrase, salt: saltA, iterations: 1_000, keyByteCount: 32)
    #expect(try kdf.deriveKey(passphrase: passphrase, salt: saltB, iterations: 1_000, keyByteCount: 32) != base)
    #expect(try kdf.deriveKey(passphrase: passphrase, salt: saltA, iterations: 1_001, keyByteCount: 32) != base)
}

@Test func theArchiveShapeYieldsAnAES256Key() throws {
    let key = try kdf.deriveKey(
        passphrase: utf8("a passphrase"),
        salt: try SystemRandomSource().bytes(count: KeyDerivationPolicy.saltByteCount),
        iterations: 1_000,
        keyByteCount: KeyDerivationPolicy.keyByteCount
    )
    #expect(key.count == 32)
}

@Test func invalidParametersAreRefusedRatherThanDerived() {
    let salt = [UInt8](repeating: 1, count: 16)

    #expect(throws: KeyDerivationError.emptyPassphrase) {
        _ = try kdf.deriveKey(passphrase: [], salt: salt, iterations: 1, keyByteCount: 32)
    }
    #expect(throws: KeyDerivationError.emptySalt) {
        _ = try kdf.deriveKey(passphrase: [1], salt: [], iterations: 1, keyByteCount: 32)
    }
    for iterations in [0, -1, Int(UInt32.max) + 1] {
        #expect(throws: KeyDerivationError.invalidIterationCount(iterations)) {
            _ = try kdf.deriveKey(passphrase: [1], salt: salt, iterations: iterations, keyByteCount: 32)
        }
    }
    #expect(throws: KeyDerivationError.invalidKeyLength(0)) {
        _ = try kdf.deriveKey(passphrase: [1], salt: salt, iterations: 1, keyByteCount: 0)
    }
}

// MARK: - Calibration

@Test func calibrationNeverReturnsFewerThanTheFloor() {
    for target in [0, -1, 0.0001, .nan, .infinity, KeyDerivationPolicy.targetDuration] {
        #expect(kdf.calibratedIterationCount(targetDuration: target) >= KeyDerivationPolicy.minimumIterations,
                "target \(target)")
    }
}

@Test func unusableTargetsFallBackToTheFloorExactly() {
    for target in [0, -1, .nan, .infinity] {
        #expect(kdf.calibratedIterationCount(targetDuration: target) == KeyDerivationPolicy.minimumIterations)
    }
}

@Test func aLongerTargetNeverCalibratesToFewerIterations() {
    let short = kdf.calibratedIterationCount(targetDuration: 0.05)
    let long = kdf.calibratedIterationCount(targetDuration: 0.5)
    #expect(long >= short)
}

@Test func thePolicyMatchesTheDocument() {
    // docs/13 §13.1–13.2.
    #expect(KeyDerivationPolicy.saltByteCount == 16)
    #expect(KeyDerivationPolicy.keyByteCount == 32)
    #expect((0.2...0.5).contains(KeyDerivationPolicy.targetDuration))
    #expect(KeyDerivationPolicy.minimumIterations == 300_000)
}

// MARK: - Passphrase bytes

@Test func anAccentTypedEitherWayDerivesTheSameKey() throws {
    let composed = "caf\u{E9} au lait"
    let decomposed = "cafe\u{301} au lait"
    #expect(Array(composed.utf8) != Array(decomposed.utf8), "the fixture no longer exercises normalization")

    #expect(PassphraseEncoding.bytes(from: composed) == PassphraseEncoding.bytes(from: decomposed))

    let salt = [UInt8](repeating: 3, count: 16)
    let a = try kdf.deriveKey(passphrase: PassphraseEncoding.bytes(from: composed), salt: salt, iterations: 1_000, keyByteCount: 32)
    let b = try kdf.deriveKey(passphrase: PassphraseEncoding.bytes(from: decomposed), salt: salt, iterations: 1_000, keyByteCount: 32)
    #expect(a == b)
}

@Test func zeroizingClearsEveryByte() {
    var secret: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x01]
    SecureBytes.zeroize(&secret)
    #expect(secret == [0, 0, 0, 0, 0])

    var empty: [UInt8] = []
    SecureBytes.zeroize(&empty)
    #expect(empty.isEmpty)
}

// MARK: - System RNG

@Test func theSystemRNGReturnsTheSizesTheArchiveNeeds() throws {
    let source = SystemRandomSource()
    #expect(try source.bytes(count: KeyDerivationPolicy.saltByteCount).count == 16)
    #expect(try source.bytes(count: 12).count == 12)
    #expect(try source.bytes(count: 0).isEmpty)
}

@Test func twoSaltsAreNeverTheSame() throws {
    // Per-export uniqueness [PRD]. A collision of two 128-bit draws would be a
    // 1-in-2^128 event; a repeat here means the source is not random.
    let source = SystemRandomSource()
    let salts = try (0..<32).map { _ in try source.bytes(count: 16) }
    #expect(Set(salts.map { Data($0) }).count == salts.count)
    #expect(salts.allSatisfy { $0 != [UInt8](repeating: 0, count: 16) })
}

@Test func aNegativeCountIsRefused() {
    #expect(throws: StabilyzError.crypto(.randomGenerationFailed)) {
        _ = try SystemRandomSource().bytes(count: -1)
    }
}

// MARK: - Edge whitespace (decided 2026-09-15)

@Test func edgeWhitespaceIsNotPartOfTheKeyButInnerSpacesAre() throws {
    // Export and restore both trim, so a keyboard's trailing space can never
    // lock someone out of their own backup.
    #expect(PassphraseEncoding.bytes(from: "\n correct horse \t") == Array("correct horse".utf8))
    #expect(PassphraseEncoding.bytes(from: "correct  horse") == Array("correct  horse".utf8))

    let salt = [UInt8](repeating: 5, count: 16)
    let typed = try kdf.deriveKey(passphrase: PassphraseEncoding.bytes(from: "correct horse "), salt: salt, iterations: 1_000, keyByteCount: 32)
    let clean = try kdf.deriveKey(passphrase: PassphraseEncoding.bytes(from: "correct horse"), salt: salt, iterations: 1_000, keyByteCount: 32)
    #expect(typed == clean)
}
