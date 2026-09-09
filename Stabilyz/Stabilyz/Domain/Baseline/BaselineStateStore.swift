import Foundation

/// A mode's calibration state changed.
struct BaselineStateChange: Sendable, Equatable {
    let mode: TestMode
    let state: BaselineState
}

/// The single read model for `BaselineState` (docs/09 §9.4).
///
/// Score screen, audio selector, Home and the Clinician Summary all consume this
/// one derivation [PRD §5, §7] — two screens computing "X of 5" separately is
/// how they end up disagreeing.
///
/// Every value here is **derived** from persisted sessions and baselines, never
/// accumulated. A failed or rolled-back commit therefore cannot corrupt the
/// count: the next refresh simply recounts what is actually stored
/// [REC — docs/09 §9.4].
actor BaselineStateStore {
    private let sessions: GaitSessionRepository
    private let baselines: BaselineRepository

    private var cached: [TestMode: BaselineState] = [:]
    private nonisolated let continuation: AsyncStream<BaselineStateChange>.Continuation

    /// Broadcast of state changes. Buffers the newest per subscriber: a stale
    /// "3 of 5" is worthless once "4 of 5" is available.
    nonisolated let changes: AsyncStream<BaselineStateChange>

    init(sessions: GaitSessionRepository, baselines: BaselineRepository) {
        self.sessions = sessions
        self.baselines = baselines

        let (stream, continuation) = AsyncStream<BaselineStateChange>.makeStream(
            bufferingPolicy: .bufferingNewest(TestMode.allCases.count)
        )
        changes = stream
        self.continuation = continuation
    }

    /// The last known state, without touching the store. Nil before the first
    /// refresh for that mode.
    func current(_ mode: TestMode) -> BaselineState? { cached[mode] }

    /// Recomputes one mode's state from the store and broadcasts it.
    @discardableResult
    func refresh(_ mode: TestMode) async throws -> BaselineState {
        let state = try BaselineStateMachine.state(
            for: mode,
            validSessionCount: try await sessions.validSessionCount(mode: mode),
            baseline: try await baselines.baseline(mode: mode)
        )

        cached[mode] = state
        continuation.yield(BaselineStateChange(mode: mode, state: state))
        return state
    }

    /// Recomputes every mode.
    ///
    /// This is the wholesale invalidation a restore needs (docs/11 §11.4): after
    /// the store is replaced, every cached state describes data that no longer
    /// exists, so it is thrown away rather than patched.
    func rebuild() async throws {
        cached.removeAll()
        for mode in TestMode.allCases {
            try await refresh(mode)
        }
    }
}
