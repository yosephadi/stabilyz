import Foundation

/// Whether a Stop from the watch should end the walk (Task 12.3.2).
///
/// The phone is authoritative [PRD §8 decision 2]: a request ends the walk
/// only if it names the session that is recording now, and only once. Anything
/// else — another session, a request before Go, a duplicate, a request that
/// arrives after the walk already stopped — is dropped.
enum WatchStopFilter {
    static func accepts(
        _ request: WatchStopRequest,
        currentSession: UUID?,
        isRunning: Bool,
        alreadyStopped: Bool
    ) -> Bool {
        request.sessionID == currentSession && isRunning && !alreadyStopped
    }
}
