import Foundation
import UniformTypeIdentifiers

/// The export file's fixed constants (docs/13 §13.1, §13.6).
enum ArchiveFormat {
    /// The first bytes of every export. A file without them is not a Stabilyz
    /// export at all (docs/13 §13.4 step 2).
    static let magic: [UInt8] = Array("STBLYZ".utf8)

    /// The crypto structure: header layout, suite, key-check. Independent of
    /// the payload's `schemaVersion` (docs/13 §13.6).
    static let envelopeVersion = 1

    /// PBKDF2-HMAC-SHA256 key derivation, then AES-256-GCM.
    static let cryptoSuite = 1

    /// The payload schema this build writes and reads natively. Older ones are
    /// migrated forward (`ArchiveMigrations`); newer ones are refused
    /// [PRD §6].
    static let schemaVersion = 1

    /// The most PBKDF2 iterations a header may ask for.
    ///
    /// Checked while parsing, before any key derivation, so a damaged or
    /// hostile header cannot pin a thread for minutes. Export must stay under it
    /// too — a device that calibrates higher clamps, or its own restore would
    /// refuse the file.
    static let maximumIterations = 5_000_000

    /// The iteration count an export is written with: this device's
    /// calibration, never below the KDF floor and never above the ceiling.
    ///
    /// The ceiling matters most on the fastest phones. A calibration above it
    /// would write a file that this very app's restore refuses to open.
    static func exportIterations(calibrated: Int) -> Int {
        min(max(calibrated, KeyDerivationPolicy.minimumIterations), maximumIterations)
    }

    static let maximumSaltByteCount = 64
    static let maximumAlgorithmVersionByteCount = 64

    /// The key-check value's plaintext (docs/13 §13.4 [REC]).
    ///
    /// Sealed under the derived key on its own nonce. Opening it proves the
    /// passphrase before the payload is touched, which is what lets a wrong
    /// passphrase be told apart from a damaged file.
    static let keyCheckPlaintext = Data("STBLYZ-KEY-CHECK".utf8)

    /// `.stabilyz` (docs/13 §13.1 [REC], decided 2026-09-15).
    static let fileExtension = "stabilyz"

    /// Under the app's own bundle prefix, `com.adi.Stabilyz`.
    static let typeIdentifier = "com.adi.stabilyz.backup"

    /// The export's type, for the share sheet and document picker (Tasks
    /// 10.2.2, 10.3.2).
    ///
    /// **Needs an Exported Type Identifier declaration in the app target's
    /// Info** (identifier above, extension `stabilyz`, conforming to
    /// `public.data`) before iOS associates the extension with it. That lives in
    /// the project's build settings, which this code cannot change.
    static var contentType: UTType {
        UTType(exportedAs: typeIdentifier, conformingTo: .data)
    }
}
