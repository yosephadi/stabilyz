import Foundation

/// What happened to the baseline when a session was committed.
enum BaselineCommitOutcome: Sendable, Equatable {
    /// Fewer than five valid sessions in this mode so far.
    case notReady(validCount: Int)
    /// This commit established the mode's baseline.
    case established(Baseline)
    /// A baseline already existed. Session 6 onward never touches it
    /// [PRD §6 — frozen, no recalibration].
    case alreadyEstablished
    /// Five valid sessions exist but a baseline could not be built from them.
    ///
    /// The session is still committed — the user's walk is valid data — and the
    /// count stands at five, pending. Calibration is **not** restarted and no
    /// substitute baseline is invented (docs/decisions.md entry 17).
    case refused(reason: BaselineCalculationService.CalculationError, validCount: Int)
}

/// The result of committing one processed session.
struct SessionCommitResult: Sendable, Equatable {
    let session: GaitSession
    /// Recounted from the store after the write, never accumulated.
    let validSessionCount: Int
    let baselineOutcome: BaselineCommitOutcome
    let state: BaselineState
}

/// Commits a processed session and, on the fifth valid one, its baseline
/// (docs/09 §9.3, §9.4).
///
/// **Compute first, then write.** The pure `BaselineCalculationService` runs
/// before anything is persisted, so a set of sessions that cannot produce a
/// baseline is discovered while the store is still untouched.
struct SessionCommitService: Sendable {
    private let sessions: GaitSessionRepository
    private let baselines: BaselineRepository
    private let writer: StoreWriter
    private let reader: StoreReader
    private let stateStore: BaselineStateStore
    private let logService: LogService
    private let configuration: AlgorithmConfiguration
    private let clock: Clock

    init(
        sessions: GaitSessionRepository,
        baselines: BaselineRepository,
        writer: StoreWriter,
        reader: StoreReader,
        stateStore: BaselineStateStore,
        logService: LogService,
        clock: Clock,
        configuration: AlgorithmConfiguration = .v1
    ) {
        self.sessions = sessions
        self.baselines = baselines
        self.writer = writer
        self.reader = reader
        self.stateStore = stateStore
        self.logService = logService
        self.clock = clock
        self.configuration = configuration
    }

    /// Commits a session, establishing the mode's baseline if this is the fifth
    /// valid one.
    @discardableResult
    func commit(_ session: GaitSession) async throws -> SessionCommitResult {
        let mode = session.mode

        // Invalid sessions are persisted for diagnostics but never advance the
        // count and never contribute to a baseline [PRD §6, §7].
        guard session.isValid else {
            try await writer.save(session)
            return try await result(for: session, outcome: nil, mode: mode)
        }

        // Frozen: once a baseline exists, later sessions never touch it
        // [PRD §6]. Checked before any calculation, so session 6 onward costs
        // nothing extra.
        if try await baselines.baseline(mode: mode) != nil {
            try await writer.save(session)
            return try await result(for: session, outcome: .alreadyEstablished, mode: mode)
        }

        let alreadyStored = try await reader.earliestValidSessions(
            mode: mode,
            limit: Baseline.requiredValidSessionCount
        )
        let candidates = (alreadyStored + [session])
            .sorted { $0.startedAt < $1.startedAt }

        guard candidates.count >= Baseline.requiredValidSessionCount else {
            try await writer.save(session)
            return try await result(for: session, outcome: nil, mode: mode)
        }

        // Compute before writing anything.
        let first = Array(candidates.prefix(Baseline.requiredValidSessionCount))
        do {
            let baseline = try BaselineCalculationService.calculate(
                from: first,
                mode: mode,
                establishedAt: clock.now,
                configuration: configuration
            )
            // Both or neither.
            try await writer.commit(session, establishing: baseline)
            logService.log(.info, .baseline, "baseline established: mode=\(mode.rawValue)")
            return try await result(for: session, outcome: .established(baseline), mode: mode)
        } catch let error as BaselineCalculationService.CalculationError {
            // The walk is valid data and is kept. No substitute baseline, no
            // restart of calibration (docs/decisions.md entry 17).
            try await writer.save(session)
            logService.log(.warning, .baseline, "baseline refused: mode=\(mode.rawValue) reason=\(error)")
            let count = try await sessions.validSessionCount(mode: mode)
            return try await result(
                for: session,
                outcome: .refused(reason: error, validCount: count),
                mode: mode
            )
        }
    }

    /// Rebuilds every mode's state from the store.
    ///
    /// For the post-restore invalidation in docs/11 §11.4 (EPIC 10).
    func rebuildState() async throws {
        try await stateStore.rebuild()
    }

    private func result(
        for session: GaitSession,
        outcome: BaselineCommitOutcome?,
        mode: TestMode
    ) async throws -> SessionCommitResult {
        // Recount from the store rather than incrementing anything: a
        // rolled-back write must not leave the count describing data that was
        // never persisted (docs/09 §9.4).
        let count = try await sessions.validSessionCount(mode: mode)
        let state = try await stateStore.refresh(mode)

        return SessionCommitResult(
            session: session,
            validSessionCount: count,
            baselineOutcome: outcome ?? .notReady(validCount: count),
            state: state
        )
    }
}
