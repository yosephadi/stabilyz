import Foundation
import os

/// Production `LogService`: one `os.Logger` and one `OSSignposter` per category
/// (docs/20-observability-logging-diagnostics.md).
///
/// No analytics, no network, no file sink — the PRD contains no analytics
/// requirement and none is added.
final class OSLogService: LogService {
    private let loggers: [LogCategory: Logger]
    private let signposters: [LogCategory: OSSignposter]

    /// `OSSignpostIntervalState` has to be handed back to `endInterval`, so open
    /// intervals are parked here between the two calls.
    private let openIntervals = Locked<[UInt64: OSSignpostIntervalState]>([:])
    private let nextIntervalID = Locked<UInt64>(1)

    init(subsystem: String = Bundle.main.bundleIdentifier ?? "Stabilyz") {
        var loggers: [LogCategory: Logger] = [:]
        var signposters: [LogCategory: OSSignposter] = [:]
        for category in LogCategory.allCases {
            let logger = Logger(subsystem: subsystem, category: category.rawValue)
            loggers[category] = logger
            signposters[category] = OSSignposter(logger: logger)
        }
        self.loggers = loggers
        self.signposters = signposters
    }

    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        guard let logger = loggers[category] else { return }
        // Messages are composed at the call site and are never sensitive
        // (docs/20), so `public` privacy keeps them readable in Console.
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
    }

    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        let id = nextIntervalID.withLock { value -> UInt64 in
            defer { value &+= 1 }
            return value
        }
        let interval = SignpostInterval(name: name, category: category, id: id)

        guard let signposter = signposters[category] else { return interval }
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        openIntervals.withLock { $0[id] = state }
        return interval
    }

    func endInterval(_ interval: SignpostInterval) {
        let state = openIntervals.withLock { $0.removeValue(forKey: interval.id) }
        guard let state, let signposter = signposters[interval.category] else { return }
        signposter.endInterval(interval.name, state)
    }
}
