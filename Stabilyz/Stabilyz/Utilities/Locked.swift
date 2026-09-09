import Foundation

/// A minimal lock-guarded value.
///
/// `Mutex` from the Synchronization module would be the natural choice, but it
/// is iOS 18+ and this app targets iOS 17 [PRD]. `NSLock` is the iOS 17
/// equivalent for the uncontended, short-critical-section use here.
///
/// `@unchecked Sendable` is carried deliberately: the stored value is only ever
/// reachable inside `withLock`, so the lock is what makes it safe.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
