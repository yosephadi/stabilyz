import Foundation

/// Cryptographic randomness (salts, nonces), abstracted so crypto tests are
/// deterministic [REC — docs/12 §12.2].
///
/// The production implementation is `SecRandomCopyBytes` (docs/13 §13.2).
nonisolated protocol RandomSource: Sendable {
    func bytes(count: Int) throws -> [UInt8]
}
