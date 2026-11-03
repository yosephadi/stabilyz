import Foundation

/// The contract's version. Bump it for any change a peer on the previous
/// version could misread: a renamed case, a renamed field, a new required
/// field, a changed raw value.
nonisolated enum WatchSyncVersion {
    static let current = 1
}

/// A message plus the version it was written in.
nonisolated struct WatchSyncEnvelope<Message: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    let version: Int
    let message: Message
}

/// Keys under which encoded envelopes travel in WatchConnectivity
/// dictionaries.
nonisolated enum WatchSyncKeys {
    /// A live message (`sendMessage`), either direction.
    static let message = "stabilyz.watchSync.message"

    /// The application context's latest session-state message: countdown
    /// started, started, stopped or cancelled.
    static let sessionState = "stabilyz.watchSync.sessionState"

    /// The application context's latest Start & Stop Haptics change, when one
    /// happened after the countdown started.
    static let haptics = "stabilyz.watchSync.haptics"
}

/// Encodes and decodes the contract (docs/21 §21.2).
///
/// **An unknown version is dropped, never guessed at.** Decoding reads the
/// version first and stops there unless it is exactly `WatchSyncVersion.current`;
/// a peer on another version is treated as sending nothing.
///
/// Decoding never throws: anything that is not a well-formed envelope of the
/// expected direction comes back `nil`, because there is nothing a receiver
/// could do with the error except drop the message anyway.
nonisolated enum WatchSyncCoder {
    static func encode(_ message: PhoneToWatchMessage) throws -> Data {
        try encode(message, version: WatchSyncVersion.current)
    }

    static func encode(_ message: WatchToPhoneMessage) throws -> Data {
        try encode(message, version: WatchSyncVersion.current)
    }

    static func decodePhoneToWatch(_ data: Data) -> PhoneToWatchMessage? {
        decode(PhoneToWatchMessage.self, from: data)
    }

    static func decodeWatchToPhone(_ data: Data) -> WatchToPhoneMessage? {
        decode(WatchToPhoneMessage.self, from: data)
    }

    /// Encodes under an explicit version. Internal so tests can write the
    /// envelopes a peer on another version would send.
    static func encode<Message: Codable & Sendable & Equatable>(
        _ message: Message,
        version: Int
    ) throws -> Data {
        try encoder.encode(WatchSyncEnvelope(version: version, message: message))
    }

    private struct VersionProbe: Decodable {
        let version: Int
    }

    private static func decode<Message: Codable & Sendable & Equatable>(
        _ type: Message.Type,
        from data: Data
    ) -> Message? {
        let decoder = makeDecoder()
        guard let probe = try? decoder.decode(VersionProbe.self, from: data),
              probe.version == WatchSyncVersion.current else {
            return nil
        }
        return try? decoder.decode(WatchSyncEnvelope<Message>.self, from: data).message
    }

    /// Seconds since 1970 as a JSON number. JSON writes the shortest decimal
    /// that reads back as the same `Double`, so a date round-trips exactly.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
