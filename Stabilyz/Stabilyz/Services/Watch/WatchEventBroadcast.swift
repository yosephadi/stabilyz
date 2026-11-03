import Foundation

/// Fan-out of one event source to any number of `AsyncStream` subscribers.
///
/// The same shape as `StoreReplacementEvents`, generalised for the watch
/// service's two streams. With `replaysLatest`, a new subscriber first receives
/// the most recent value — right for reachability, where a listener needs the
/// current state, and wrong for stop requests, where a stale Stop must never
/// reach a listener that arrived after it.
final class WatchEventBroadcast<Value: Sendable>: Sendable {
    private struct State {
        var latest: Value?
        var subscribers: [UUID: AsyncStream<Value>.Continuation] = [:]
        var isFinished = false
    }

    private let replaysLatest: Bool
    private let state: Locked<State>

    /// - Parameter initial: replayed to subscribers until the first publish.
    ///   Passing one turns replay on.
    init(initial: Value? = nil, replaysLatest: Bool) {
        self.replaysLatest = replaysLatest
        self.state = Locked(State(latest: replaysLatest ? initial : nil))
    }

    func subscribe() -> AsyncStream<Value> {
        let (stream, continuation) = AsyncStream<Value>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        let (latest, finished) = state.withLock { state -> (Value?, Bool) in
            if !state.isFinished { state.subscribers[id] = continuation }
            return (state.latest, state.isFinished)
        }
        if let latest { continuation.yield(latest) }
        if finished {
            continuation.finish()
        } else {
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { $0.subscribers[id] = nil }
            }
        }
        return stream
    }

    func publish(_ value: Value) {
        let subscribers = state.withLock { state -> [AsyncStream<Value>.Continuation] in
            guard !state.isFinished else { return [] }
            if replaysLatest { state.latest = value }
            return Array(state.subscribers.values)
        }
        for subscriber in subscribers {
            subscriber.yield(value)
        }
    }

    /// Ends every stream, current and future.
    func finish() {
        let subscribers = state.withLock { state -> [AsyncStream<Value>.Continuation] in
            state.isFinished = true
            defer { state.subscribers.removeAll() }
            return Array(state.subscribers.values)
        }
        for subscriber in subscribers {
            subscriber.finish()
        }
    }

    var subscriberCount: Int {
        state.withLock { $0.subscribers.count }
    }
}
