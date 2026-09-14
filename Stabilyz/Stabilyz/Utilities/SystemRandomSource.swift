import Foundation
import Security

/// Production `RandomSource`: the system CSPRNG via `SecRandomCopyBytes`
/// (docs/13 §13.2) — salts and nonces for the export archive.
///
/// No fallback of any kind. If the system generator fails, the operation that
/// needed randomness fails with it: a salt or nonce from anything weaker is the
/// exact substitution the PRD's no-custom-cryptography rule forbids.
struct SystemRandomSource: RandomSource {
    init() {}

    func bytes(count: Int) throws -> [UInt8] {
        // A negative count is a caller bug; refuse rather than trap in a
        // release build on the export path.
        guard count >= 0 else { throw StabilyzError.crypto(.randomGenerationFailed) }
        guard count > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: count)
        let status = buffer.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else {
            throw StabilyzError.crypto(.randomGenerationFailed)
        }
        return buffer
    }
}
