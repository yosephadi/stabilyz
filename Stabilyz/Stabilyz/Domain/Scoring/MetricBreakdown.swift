import Foundation

/// A user-facing signal on the Score screen (docs/04 §4.9).
///
/// One signal can rest on more than one metric: gait consistency covers both
/// autocorrelation outputs, and the trunk proxy covers both axes. How they are
/// *presented* — one number or two — is EPIC 8's call, so the breakdown carries
/// every component rather than collapsing them here.
///
/// Raw values are stable keys. The labels are provisional and EPIC 8 owns the
/// final copy.
enum SignalID: String, Sendable, CaseIterable, Codable {
    /// Step regularity and stride regularity together.
    case gaitConsistency
    case stepTimeVariability
    case trunkMotion
    case cadence
    case stepTimeAsymmetry

    /// The metrics behind this signal, in display order.
    var metrics: [MetricID] {
        switch self {
        case .gaitConsistency: [.stepRegularity, .strideRegularity]
        case .stepTimeVariability: [.stepTimeCV]
        case .trunkMotion: [.trunkMotionML, .trunkMotionVT]
        case .cadence: [.cadenceMean]
        case .stepTimeAsymmetry: [.stepTimeAsymmetry]
        }
    }

    /// Provisional wording. **EPIC 8 finalises this copy.**
    ///
    /// "Gait consistency" is not provisional: [PRD OQ-1] fixes it, and calling
    /// the autocorrelation output "symmetry" or "asymmetry" would overclaim what
    /// it measures. That term belongs only to the unilateral step-time
    /// comparison.
    var provisionalLabel: String {
        switch self {
        case .gaitConsistency: "Gait consistency"
        case .stepTimeVariability: "Step-time variability"
        case .trunkMotion: "Trunk motion"
        case .cadence: "Cadence"
        case .stepTimeAsymmetry: "Step-time asymmetry"
        }
    }
}

/// Whether a metric could be compared, and if not, why.
///
/// The vocabulary is 6.2.1's, carried forward unchanged so the Score screen and
/// the clinician summary describe absence the same way the pipeline did.
enum MetricAvailability: String, Sendable, Equatable, Codable {
    /// Measured and compared against a baseline stat.
    case standardized
    /// Measured, but the baseline has no stat for it.
    case rawOnly
    /// The baseline has a stat, but this session did not measure it.
    case unmeasured
}

/// One metric inside a signal.
struct MetricBreakdownComponent: Sendable, Equatable, Codable {
    let metricID: MetricID
    let availability: MetricAvailability
    /// What this session measured. Nil when unmeasured.
    let rawValue: Double?
    /// The user's own normal. Nil when the baseline has no stat.
    let baselineMean: Double?
    /// The floored spread the comparison used (docs/decisions.md entry 16).
    let baselineSD: Double?
    /// Oriented so positive is better.
    ///
    /// **Nil for cadence and asymmetry** — neither has a decided direction
    /// (entry 3), so neither may be rendered as better or worse.
    let directionAdjustedZ: Double?
}

/// A signal's entry in the Score screen's tap-to-expand (docs/05 §5.1).
struct MetricBreakdown: Sendable, Equatable, Codable {
    let signal: SignalID
    let components: [MetricBreakdownComponent]
    /// The side the profile identifies as affected, for the asymmetry entry
    /// only. **Context, not attribution** (docs/decisions.md entry 13); EPIC 8
    /// renders asymmetry as a signed, side-labelled value.
    let asymmetrySide: AmputationSide?

    /// Whether this signal may be shown as better or worse at all.
    var carriesDirection: Bool {
        components.contains { $0.directionAdjustedZ != nil }
    }

    /// Whether anything about this signal can be shown.
    var isEmpty: Bool { components.isEmpty }
}

/// Builds the Score screen's breakdown from a standardized session.
enum MetricBreakdownBuilder {
    /// - Returns: one entry per signal that has something to show. A signal
    ///   whose metrics were neither measured nor baselined is omitted rather
    ///   than shown empty.
    static func breakdown(
        from standardization: SessionStandardization,
        metrics: GaitMetrics
    ) -> [MetricBreakdown] {
        SignalID.allCases.compactMap { signal in
            let components = signal.metrics.compactMap { metric in
                component(for: metric, standardization: standardization, metrics: metrics)
            }
            guard !components.isEmpty else { return nil }

            return MetricBreakdown(
                signal: signal,
                components: components,
                asymmetrySide: signal == .stepTimeAsymmetry ? metrics.asymmetryAffectedSide : nil
            )
        }
    }

    private static func component(
        for metric: MetricID,
        standardization: SessionStandardization,
        metrics: GaitMetrics
    ) -> MetricBreakdownComponent? {
        if let standardized = standardization.standardization(for: metric) {
            return MetricBreakdownComponent(
                metricID: metric,
                availability: .standardized,
                rawValue: standardized.rawValue,
                baselineMean: standardized.baselineMean,
                baselineSD: standardized.baselineSD,
                directionAdjustedZ: standardized.directionAdjustedZ
            )
        }
        if let raw = standardization.rawOnly.first(where: { $0.metricID == metric }) {
            return MetricBreakdownComponent(
                metricID: metric,
                availability: .rawOnly,
                rawValue: raw.rawValue,
                baselineMean: nil,
                baselineSD: nil,
                directionAdjustedZ: nil
            )
        }
        if standardization.unmeasured.contains(metric) {
            return MetricBreakdownComponent(
                metricID: metric,
                availability: .unmeasured,
                rawValue: nil,
                baselineMean: nil,
                baselineSD: nil,
                directionAdjustedZ: nil
            )
        }
        // Absent on both sides: nothing to show.
        return nil
    }
}
