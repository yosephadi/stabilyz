/// Versioned session thresholds (docs/05 §5.1, docs/07 §7.5).
///
/// Held as a versioned value rather than as properties on `TestMode` so the
/// thresholds can be tuned without a schema change and without touching call
/// sites [REC]. `SessionPolicy` is passed in; nothing reads a global.
nonisolated struct SessionPolicy: Sendable, Equatable {
    /// Bumped whenever a threshold changes, so a stored session can be read
    /// back against the policy it was judged under.
    let version: Int

    private let quickTestMinimumValidWalking: Duration
    private let fullTestMinimumValidWalking: Duration

    init(version: Int, quickTestMinimumValidWalking: Duration, fullTestMinimumValidWalking: Duration) {
        self.version = version
        self.quickTestMinimumValidWalking = quickTestMinimumValidWalking
        self.fullTestMinimumValidWalking = fullTestMinimumValidWalking
    }

    /// Valid walking data a session must accumulate to be scoreable
    /// [PRD OQ-3: ~90 seconds for Quick Test, ~4 minutes for Full Test].
    ///
    /// Pauses, setup time and other non-walking segments do not count toward
    /// this, even when the advertised length elapsed on the clock. Anything
    /// below the threshold routes to the noisy/insufficient-data path and is
    /// never scored [PRD §5].
    func minimumValidWalkingDuration(for mode: TestMode) -> Duration {
        switch mode {
        case .quickTest: quickTestMinimumValidWalking
        case .fullTest: fullTestMinimumValidWalking
        }
    }

    /// The v1 thresholds.
    ///
    /// [PRD OQ-3] frames these explicitly as **v1 product-quality thresholds,
    /// not research-validated clinical minima** — the literature supports the
    /// 2-/6-minute test lengths, not these floors. They are provisional and are
    /// to be tuned against real-world session data (docs/22 Phase 12).
    static let v1 = SessionPolicy(
        version: 1,
        quickTestMinimumValidWalking: .seconds(90),
        fullTestMinimumValidWalking: .seconds(240)
    )
}
