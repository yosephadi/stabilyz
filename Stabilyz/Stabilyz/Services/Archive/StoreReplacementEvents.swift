import Foundation

/// What a successful restore put in the store.
struct RestoreReceipt: Sendable, Equatable {
    let schemaVersion: Int
    let sessionCount: Int
    let baselineModes: [TestMode]
}

/// The store was replaced wholesale.
///
/// docs/11 §11.4's "full state reset event": everything a long-lived view
/// model has read describes data that no longer exists.
struct StoreReplacement: Sendable, Equatable {
    let receipt: RestoreReceipt
}

/// The post-restore broadcast (docs/11 §11.4–11.5, Task 10.3.4).
///
/// Explicit rather than implied, because the bug it prevents is silent: a
/// History list or setup screen still showing the pre-restore store after the
/// replace would violate the atomic-restore guarantee in spirit even though
/// the store itself is correct [PRD §7].
///
/// Every subscriber gets its own stream, buffering only the newest event — a
/// subscriber that was busy needs to know a replace happened, not how many.
final class StoreReplacementEvents: Sendable {
    private let continuations = Locked<[UUID: AsyncStream<StoreReplacement>.Continuation]>([:])

    init() {}

    func subscribe() -> AsyncStream<StoreReplacement> {
        let (stream, continuation) = AsyncStream<StoreReplacement>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.continuations.withLock { $0[id] = nil }
        }
        return stream
    }

    func publish(_ replacement: StoreReplacement) {
        let subscribers = continuations.withLock { Array($0.values) }
        for subscriber in subscribers {
            subscriber.yield(replacement)
        }
    }

    var subscriberCount: Int {
        continuations.withLock { $0.count }
    }
}
