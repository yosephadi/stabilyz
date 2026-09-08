import Foundation

/// Log subsystem categories (docs/20-observability-logging-diagnostics.md).
nonisolated enum LogCategory: String, Sendable, CaseIterable {
    case app
    case session
    case motion
    case processing
    case baseline
    case audio
    case backup
    case persistence
}

/// Severity, mapped onto `os.Logger` levels by the production implementation.
nonisolated enum LogLevel: String, Sendable, CaseIterable {
    case debug
    case info
    case warning
    case error
}

/// A signpost interval opened by `LogService.beginInterval`, to be passed back
/// to `endInterval`. Opaque: callers hold it and return it, nothing more.
nonisolated struct SignpostInterval: Sendable, Hashable {
    let name: StaticString
    let category: LogCategory
    let id: UInt64

    static func == (lhs: SignpostInterval, rhs: SignpostInterval) -> Bool {
        lhs.id == rhs.id && lhs.category == rhs.category
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(category)
    }
}

/// Structured logging plus `OSSignposter` intervals for pipeline stages
/// (docs/20).
///
/// **Never pass to this service:** passphrases, keys, salts, nonces, raw sensor
/// samples, metric values, or profile fields. Metric *values* are health data —
/// log counts and statuses only (docs/20, docs/15 §15.2). The signature takes a
/// plain `String` precisely so every call site is an explicit, auditable
/// decision about what is safe to record.
nonisolated protocol LogService: Sendable {
    func log(_ level: LogLevel, _ category: LogCategory, _ message: String)

    /// Opens a signpost interval for a pipeline stage (docs/20).
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval

    /// Closes an interval previously returned by `beginInterval`. Closing an
    /// unknown or already-closed interval is ignored.
    func endInterval(_ interval: SignpostInterval)
}

extension LogService {
    /// Scoped convenience: opens an interval, runs `operation`, and closes the
    /// interval even if `operation` throws.
    func measure<T>(
        _ name: StaticString,
        category: LogCategory,
        operation: () async throws -> T
    ) async rethrows -> T {
        let interval = beginInterval(name, category: category)
        defer { endInterval(interval) }
        return try await operation()
    }
}
