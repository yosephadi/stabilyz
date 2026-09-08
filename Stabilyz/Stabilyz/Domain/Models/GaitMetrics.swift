/// Per-session metrics (docs/05 §5.1). Mode-tagged via the owning session.
///
/// Produced by the pipeline's metric-calculation stage (docs/08 stage 6) and
/// persisted as a JSON blob (docs/05 §5.2).
///
/// The composite score is built from **independent** signals: the regularity
/// metrics, step-time variability and the trunk-motion proxy are separate
/// inputs, and gait consistency is never the sole basis of a score [PRD §7].
nonisolated struct GaitMetrics: Sendable, Equatable, Codable {
    // Baseline-standardizable metrics
    /// Ad1.
    let stepRegularity: Double
    /// Ad2.
    let strideRegularity: Double
    /// Steps per minute.
    let cadenceMean: Double
    /// Step-time coefficient of variation.
    let stepTimeCV: Double
    /// Mediolateral trunk-motion proxy.
    ///
    /// [OPEN] The exact formulation — RMS vs variance, per-axis vs combined —
    /// is unresolved (docs/05 §5.1, docs/08 §8.2). Both axes are stored
    /// separately so either choice remains available without a schema change.
    let trunkMotionML: Double
    /// Vertical trunk-motion proxy. Same [OPEN] as `trunkMotionML`.
    let trunkMotionVT: Double
    /// Sound-vs-prosthetic step-time asymmetry.
    ///
    /// Nil whenever the side is not reliably identifiable. **Never fabricated
    /// for bilateral users** [PRD §7, OQ-1] — nil is the correct value, not zero.
    let stepTimeAsymmetry: Double?

    // Context / provenance — not standardized against a baseline
    /// From CMPedometer [REC].
    let steps: Int?
    /// Meters, from CMPedometer [REC].
    let distance: Double?
    /// Analysis provenance [REC].
    let validStrideCount: Int
    /// Analysis provenance [REC].
    let windowCount: Int

    init(
        stepRegularity: Double,
        strideRegularity: Double,
        cadenceMean: Double,
        stepTimeCV: Double,
        trunkMotionML: Double,
        trunkMotionVT: Double,
        stepTimeAsymmetry: Double? = nil,
        steps: Int? = nil,
        distance: Double? = nil,
        validStrideCount: Int,
        windowCount: Int
    ) {
        self.stepRegularity = stepRegularity
        self.strideRegularity = strideRegularity
        self.cadenceMean = cadenceMean
        self.stepTimeCV = stepTimeCV
        self.trunkMotionML = trunkMotionML
        self.trunkMotionVT = trunkMotionVT
        self.stepTimeAsymmetry = stepTimeAsymmetry
        self.steps = steps
        self.distance = distance
        self.validStrideCount = validStrideCount
        self.windowCount = windowCount
    }

    /// The raw value for a registry metric, or nil when this session does not
    /// carry it (only `stepTimeAsymmetry` is ever absent).
    func value(for metric: MetricID) -> Double? {
        switch metric {
        case .stepRegularity: stepRegularity
        case .strideRegularity: strideRegularity
        case .cadenceMean: cadenceMean
        case .stepTimeCV: stepTimeCV
        case .trunkMotionML: trunkMotionML
        case .trunkMotionVT: trunkMotionVT
        case .stepTimeAsymmetry: stepTimeAsymmetry
        }
    }

    /// Metrics actually present on this session, in registry order.
    var availableMetrics: [MetricID] {
        MetricID.allCases.filter { value(for: $0) != nil }
    }
}
